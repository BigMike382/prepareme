import Foundation
import PrepareMeShared

/// What the service sends back for one request.
public enum Reply {
    case bytes(status: Int, headers: [(String, String)], body: Data)
    /// `bend`: the one byte of the file, by its offset in the file, that is sent changed (BendOnce), or nil.
    case file(status: Int, headers: [(String, String)], handle: FileHandle, offset: UInt64, length: UInt64,
              bend: UInt64?)

    public var status: Int {
        switch self {
        case let .bytes(status, _, _), let .file(status, _, _, _, _, _): status
        }
    }
}

/// The service's three endpoints (plan section 9), behind a phone's token:
/// - `GET /manifest.json`, the served folder's manifest;
/// - `GET /files/<name>`, one file in the served folder, whole or one byte range (206), with an ETag so a phone's
///   cut-off download resumes only against the same file (If-Range);
/// - `POST /counts`, a phone's alert counts (CountsReport's shape only), saved under the phone's label; to the
///   library service, its feed counts instead (FeedCountsReport's shape only, plan phase 5), when it has a store.
/// No token, a token no phone holds, or anything else gets a status and nothing more. The folder is only read.
///
/// The library service (plan phase 4, `manifestOnly`) serves a file only when the folder's manifest, read at that
/// request, names it: the packer's local folder may hold a retired volume's file or a half-made temporary one, and
/// neither is a phone's business (phase 2's deferred minor). `bend` is the owner's damaged-copy test switch.
public struct Router: Sendable {
    public let folder: URL
    public let tokens: TokenStore
    public let counts: CountsStore
    public let manifestOnly: Bool
    /// The barcode keys the library service hands to an adult's device (Unlisted plan, phase 4): the Mac app's own,
    /// read once at start; nil (an empty answer) when it has none. Never logged: the log has addresses and statuses.
    public let lookupKeys: LookupKeys?
    public let bend: BendOnce?
    public let feedCounts: FeedCountsStore?
    /// Plan phase 7, slice 5: the inventory folder (Application Support › PrepareMe › inventory), when this service
    /// serves the inventory: `GET /inventory.json` to every paired phone (the app's phone-inventory.json, which never
    /// holds a Private row), and `POST /inventory/edits` from a phone that isn't read-only, saved whole into its inbox
    /// for the app to apply (PhoneInbox). The reply's X-PrepareMe-Edits header says whether this phone may edit.
    /// Players plan, stage 2: from the same folder, `GET /players.json` to every paired device, a child's too (the
    /// Mac app's copy of the player list, `PlayerList.phoneFileName`), served only within `PlayerList`'s limits.
    public let inventory: URL?
    /// Concept-doc plan, phase B: backup-key.json, the public half of the Mac app's backup-signing key, which the app
    /// leaves in the pairing folder. The served list carries it as `backup_key` (nil when the file is missing or
    /// damaged), so a paired phone learns it over this pinned channel only; a key the delivery list carried is dropped.
    public let backupKey: URL?
    /// Concept-doc plan, phase M: the pairing folder, where each phone's room report is kept (`POST /storage`,
    /// PhoneStorage) and the owner's Always or Never per file per phone is read (PhoneChoices) for the list that phone
    /// is served, with its `drop` (a file set to Never for it, or un-ticked For the family; it is answered 404 for a
    /// file set to Never). Nil: neither.
    public let pairing: URL?
    /// Essential Documents, phase 3 (docs/documents.md, "The phones"): the Mac's encrypted store, read only, and its
    /// inbox, for adults' phones the owner has given the key (a gift in the pairing folder, DocumentHandoff). Nil, or
    /// no pairing folder: none of it.
    public let documents: URL?
    /// Unlisted plan, phase 3: whether PrepareMe Dev may be served (a test service, started with its own `--support`).
    /// The family's Mac's service never may: a request saying it is the Dev copy (DevCopy) gets 403 and
    /// `X-PrepareMe-Refused: dev` before its token is looked at, so it is never counted as a visit.
    public let servesDev: Bool

    public init(folder: URL, tokens: TokenStore, counts: CountsStore, manifestOnly: Bool = false,
                bend: BendOnce? = nil, feedCounts: FeedCountsStore? = nil, inventory: URL? = nil,
                backupKey: URL? = nil, pairing: URL? = nil, documents: URL? = nil, servesDev: Bool = false,
                lookupKeys: LookupKeys? = nil) {
        self.lookupKeys = lookupKeys
        self.servesDev = servesDev
        self.documents = documents
        self.backupKey = backupKey
        self.pairing = pairing
        self.inventory = inventory
        self.feedCounts = feedCounts
        self.folder = folder
        self.tokens = tokens
        self.counts = counts
        self.manifestOnly = manifestOnly
        self.bend = bend
    }

    /// The reply, and the phone's label for the log (nil for a request no phone's token came with).
    public func reply(to request: HTTPRequest, now: Date) -> (Reply, String?) {
        if !servesDev, request.headers[DevCopy.header.lowercased()] == DevCopy.value {
            return (.bytes(status: 403, headers: [(DevCopy.refusedHeader, DevCopy.value), ("Content-Length", "0")],
                           body: Data()), nil)
        }
        guard let paired = phone(request) else { return (Self.empty(401), nil) }
        try? tokens.visited(paired)  // its first visit: the Mac stops listing it as waiting (Task 13.2; F42)
        let label = paired.label
        if request.path.hasPrefix(HTTP.documentsPrefix) {
            return (documentsReply(request, from: paired, now: now), label)
        }
        switch (request.method, request.path) {
        case ("GET", "/manifest.json"):
            return (manifest(for: paired), label)
        case ("POST", HTTP.storagePath) where manifestOnly && pairing != nil:
            guard let report = try? PhoneStorage.read(request.body) else { return (Self.empty(400), label) }
            return (keep(report, from: paired, now: now), label)
        case ("POST", "/counts") where manifestOnly:
            guard let feedCounts else { return (Self.empty(404), label) }
            guard let report = try? FeedCountsReport.read(request.body) else { return (Self.empty(400), label) }
            do {
                try feedCounts.add(report, from: label, now: now)
                return (Self.empty(204), label)
            } catch {
                return (Self.empty(500), label)
            }
        case ("POST", "/counts"):
            guard let report = try? CountsReport.read(request.body) else { return (Self.empty(400), label) }
            do {
                try counts.add(report, from: label, now: now)
                return (Self.empty(204), label)
            } catch {
                return (Self.empty(500), label)
            }
        case ("GET", "/inventory.json") where inventory != nil:
            return (phoneInventory(editor: paired.readOnly != true), label)
        case ("GET", "/players.json") where inventory != nil:
            return (players(), label)
        case ("POST", HTTP.editsPath) where inventory != nil:
            // a child's phone sends them too since 2026-11-12 (it adds pins and removes its own): stamped here as a
            // child's, over whatever it sent, so the Mac's rules refuse everything else (PhoneRules.childRefusal)
            guard var edits = PhoneEdits.read(request.body) else { return (Self.empty(400), label) }
            edits.child = paired.readOnly == true ? true : nil
            return (save(edits, from: label, now: now), label)
        case ("GET", LookupKeys.path) where manifestOnly:
            guard paired.readOnly != true else { return (Self.empty(403), label) }  // a child's device never looks one up
            let body = (lookupKeys ?? LookupKeys()).encoded()
            return (.bytes(status: 200, headers: [("Content-Type", "application/json"), ("Cache-Control", "no-store"),
                                                  ("Content-Length", String(body.count))], body: body), label)
        case (_, LookupKeys.path) where manifestOnly:
            return (Self.empty(405), label)
        case (_, "/manifest.json"), (_, "/counts"), (_, "/inventory.json"), (_, HTTP.editsPath), (_, HTTP.storagePath),
             (_, "/players.json"):
            let inventoryPath = request.path.hasPrefix("/inventory") || request.path == "/players.json"
            return (Self.empty(inventory == nil && inventoryPath ? 404 : 405), label)
        default:
            break
        }
        guard request.path.hasPrefix("/files/") else { return (Self.empty(404), label) }
        guard request.method == "GET" else { return (Self.empty(405), label) }
        return (file(String(request.path.dropFirst("/files/".count)), request, for: paired), label)
    }

    // MARK: Essential Documents (phase 3)

    /// `/documents/…`, for an adult's phone only (a child's gets 403, as its edits do):
    /// - `POST key-request`: the phone's lock's public half (DocumentHandoff.Request), kept for the owner to approve;
    /// - `GET key`: the Mac's gift, once the owner has given this phone Essential Documents (404 until then).
    /// With the gift:
    /// - `GET list.json`, and `GET files/<name>` for the index and each file it names (ranges, as the library's);
    /// - `POST changes`: the phone's encrypted outbox, whole, into the inbox for the Mac app to apply;
    /// - `GET upload/<name>` (how much of an added file has come) and `POST upload/<name>/<offset>` (its next piece);
    /// - `POST status`: its standing, counts only (DocumentsPhoneReport).
    func documentsReply(_ request: HTTPRequest, from phone: TokenStore.Phone, now: Date) -> Reply {
        guard let documents, let pairing else { return Self.empty(404) }
        guard phone.readOnly != true else { return Self.empty(403) }  // a child's phone never gets documents
        let path = String(request.path.dropFirst(HTTP.documentsPrefix.count))
        switch (request.method, path) {
        case ("POST", "key-request"):
            guard let ask = try? DocumentHandoff.Request.read(request.body) else { return Self.empty(400) }
            return keepRequest(ask, from: phone, now: now, in: pairing)
        case ("GET", "key"):
            guard let gift = gift(for: phone), let body = try? DocumentHandoff.encoded(DocumentHandoff.Served(gift))
            else { return Self.empty(404) }
            return .bytes(status: 200, headers: [("Content-Type", "application/json"), ("Cache-Control", "no-store"),
                                                 ("Content-Length", String(body.count))], body: body)
        case (_, "key-request"), (_, "key"):
            return Self.empty(405)
        default:
            break
        }
        guard gift(for: phone) != nil else { return Self.empty(403) }  // the owner hasn't given it Essential Documents
        let inbox = documents.appendingPathComponent(DocumentInbox.folderName)
        switch (request.method, path) {
        case ("GET", DocumentList.fileName):
            guard let list = servedList(), let body = try? DocumentList.encoded(list) else { return Self.empty(404) }
            return .bytes(status: 200, headers: [("Content-Type", "application/json"), ("Cache-Control", "no-store"),
                                                 ("Content-Length", String(body.count))], body: body)
        case ("POST", "changes"):
            guard !request.body.isEmpty, request.body.count <= DocumentOutbox.maxBytes else { return Self.empty(400) }
            let phoneWord = phone.label.replacingOccurrences(of: " ", with: "")
            let name = "\(DocumentInbox.changesPrefix)\(Self.stamp(now))-\(phoneWord)-\(UUID().uuidString.lowercased()).pmdoc"
            guard Self.inboxHasRoom(inbox, adding: request.body.count) else { return Self.empty(503) }
            return Self.write(request.body, to: inbox.appendingPathComponent(name)) ? Self.empty(202) : Self.empty(500)
        case ("POST", "status"):
            guard let report = try? DocumentsPhoneReport.read(request.body) else { return Self.empty(400) }
            return keepStatus(report, from: phone, now: now, in: pairing)
        case (_, DocumentList.fileName), (_, "changes"), (_, "status"):
            return Self.empty(405)
        default:
            break
        }
        if path.hasPrefix("files/") {
            guard request.method == "GET" else { return Self.empty(405) }
            let name = String(path.dropFirst("files/".count))
            guard let list = servedList(), list.entry(named: name) != nil else { return Self.empty(404) }
            let url = name == DocumentList.indexName ? documents.appendingPathComponent(name)
                : documents.appendingPathComponent("files").appendingPathComponent(name)
            return serve(url, name: name, request)
        }
        if path.hasPrefix("upload/") {
            let parts = path.dropFirst("upload/".count).split(separator: "/", omittingEmptySubsequences: false)
            guard let name = parts.first.map(String.init), DocumentList.isFileName(name), parts.count <= 2 else {
                return Self.empty(404)
            }
            let url = inbox.appendingPathComponent(name)
            let have = DocumentList.size(of: url) ?? 0
            switch (request.method, parts.count) {
            case ("GET", 1):
                return .bytes(status: 204, headers: [(HTTP.haveHeader, String(have)), ("Content-Length", "0")],
                              body: Data())
            case ("POST", 2):
                guard let offset = Int64(parts[1]), offset >= 0, !request.body.isEmpty else { return Self.empty(400) }
                guard offset == have else {  // a piece out of order: the phone goes on from what has come
                    return .bytes(status: 409, headers: [(HTTP.haveHeader, String(have)), ("Content-Length", "0")],
                                  body: Data())
                }
                guard Self.inboxHasRoom(inbox, adding: request.body.count) else { return Self.empty(503) }
                guard Self.append(request.body, to: url) else { return Self.empty(500) }
                return .bytes(status: 204, headers: [(HTTP.haveHeader, String(have + Int64(request.body.count))),
                                                     ("Content-Length", "0")], body: Data())
            default:
                return Self.empty(405)
            }
        }
        return Self.empty(404)
    }

    func gift(for phone: TokenStore.Phone) -> DocumentHandoff.Gift? {
        guard let pairing else { return nil }
        let all = DocumentHandoff.readGifts(try? Data(contentsOf: pairing.appendingPathComponent(DocumentHandoff.giftsName)))
        return DocumentHandoff.gift(all, label: phone.label, paired: phone.added)
    }

    /// The Mac app's list of its store, read and checked at this request; nil when there is none or it is damaged.
    func servedList() -> DocumentList? {
        guard let documents else { return nil }
        let url = documents.appendingPathComponent(DocumentList.fileName)
        guard Self.isRegularFile(url), let data = try? Data(contentsOf: url) else { return nil }
        return try? DocumentList.read(data)
    }

    func keepRequest(_ ask: DocumentHandoff.Request, from phone: TokenStore.Phone, now: Date, in pairing: URL) -> Reply {
        let url = pairing.appendingPathComponent(DocumentHandoff.requestsName)
        var all = DocumentHandoff.readRequests(try? Data(contentsOf: url))
        if let known = all[phone.label], known.key == ask.key, known.paired == phone.added {
            return Self.empty(204)  // asked before with the same lock: nothing to write
        }
        all[phone.label] = DocumentHandoff.Request(key: ask.key, paired: phone.added,
                                                   at: ISO8601DateFormatter().string(from: now))
        guard let data = try? DocumentHandoff.encoded(all), (try? DurableFile.write(data, to: url)) != nil else {
            return Self.empty(500)
        }
        return Self.empty(204)
    }

    func keepStatus(_ report: DocumentsPhoneReport, from phone: TokenStore.Phone, now: Date, in pairing: URL) -> Reply {
        let url = pairing.appendingPathComponent(DocumentHandoff.statusName)
        var all = DocumentsPhoneReport.readAll(try? Data(contentsOf: url))
        var report = report
        report.at = ISO8601DateFormatter().string(from: now)
        report.paired = phone.added
        all[phone.label] = report
        guard let data = try? DocumentHandoff.encoded(all), (try? DurableFile.write(data, to: url)) != nil else {
            return Self.empty(500)
        }
        return Self.empty(204)
    }

    static func stamp(_ now: Date) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.string(from: now).replacingOccurrences(of: ":", with: "-")
    }

    /// The documents inbox's limits: past either a post is answered 503 and the phone keeps what it has.
    static func inboxHasRoom(_ inbox: URL, adding count: Int) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []
        let bytes = names.reduce(Int64(0)) { $0 + (DocumentList.size(of: inbox.appendingPathComponent($1)) ?? 0) }
        return names.count < DocumentInbox.maxFiles && bytes + Int64(count) <= DocumentInbox.maxBytes
    }

    static func write(_ body: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try DurableFile.write(body, to: url)
            return true
        } catch {
            return false
        }
    }

    /// A piece added at the end of an upload, forced to the disk before the reply says it came.
    static func append(_ body: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                     attributes: [.posixPermissions: 0o600]) else { return false }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: body)
            try handle.synchronize()
            return true
        } catch {
            return false
        }
    }

    /// The paired phone whose token came with the request; nil for none
    func phone(_ request: HTTPRequest) -> TokenStore.Phone? {
        guard let value = request.headers["authorization"], value.hasPrefix("Bearer ") else { return nil }
        return tokens.phone(for: String(value.dropFirst("Bearer ".count)))
    }

    func phoneInventory(editor: Bool) -> Reply {
        guard let url = inventory?.appendingPathComponent(PhoneInventory.fileName), Self.isRegularFile(url),
              let data = try? Data(contentsOf: url) else { return Self.empty(404) }
        return .bytes(status: 200, headers: [("Content-Type", "application/json"), ("Cache-Control", "no-store"),
                                             ("X-PrepareMe-Edits", editor ? "yes" : "no"),
                                             ("Content-Length", String(data.count))], body: data)
    }

    /// The player list's copy as the Mac app wrote it: 404 before it has written one; 500, and nothing sent, for a
    /// copy over `PlayerList.fileLimit` or outside any of its limits.
    func players() -> Reply {
        guard let url = inventory?.appendingPathComponent(PlayerList.phoneFileName), Self.isRegularFile(url) else {
            return Self.empty(404)
        }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
              size <= PlayerList.fileLimit, let data = try? Data(contentsOf: url), PlayerList.read(data) != nil else {
            return Self.empty(500)
        }
        return .bytes(status: 200, headers: [("Content-Type", "application/json"), ("Cache-Control", "no-store"),
                                             ("Content-Length", String(data.count))], body: data)
    }

    /// The edits, whole, as `<time>-<phone>-<id>.json` in the inbox (DurableFile: a temporary name, then the swap), so
    /// the app reads them in the order they came; 202, or 500 when they couldn't be saved.
    /// The inbox's limits (slice 5 review): past either, a post is answered 503 and the phone keeps its edits, so a
    /// Mac app that is quit or stuck never lets the inbox fill the disk.
    static let inboxMaxFiles = 500
    static let inboxMaxBytes = 50 << 20

    func save(_ edits: PhoneEdits, from label: String, now: Date) -> Reply {
        guard let inventory, let body = try? JSONEncoder().encode(edits) else { return Self.empty(500) }
        let waiting = inventory.appendingPathComponent(PhoneInbox.inboxName)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: waiting.path)) ?? []
        let bytes = names.reduce(0) { total, name in
            total + ((try? FileManager.default.attributesOfItem(atPath: waiting.appendingPathComponent(name).path)[.size]
                      as? Int) ?? 0)
        }
        guard names.count < Self.inboxMaxFiles, bytes + body.count <= Self.inboxMaxBytes else { return Self.empty(503) }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let time = format.string(from: now).replacingOccurrences(of: ":", with: "-")
        let phone = label.replacingOccurrences(of: " ", with: "")
        let name = "\(time)-\(phone)-\(UUID().uuidString.lowercased()).json"
        let inbox = inventory.appendingPathComponent(PhoneInbox.inboxName)
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try DurableFile.write(body, to: inbox.appendingPathComponent(name))
            return Self.empty(202)
        } catch {
            return Self.empty(500)
        }
    }

    /// A phone's room report kept whole by its label in the pairing folder, with the time it came and when that phone was
    /// paired (a reused label never shows a removed phone's report); 204, or 500 when it couldn't be saved
    func keep(_ report: PhoneStorage, from phone: TokenStore.Phone, now: Date) -> Reply {
        guard let pairing else { return Self.empty(404) }
        let file = pairing.appendingPathComponent(PhoneStorage.fileName)
        var all = PhoneStorage.readAll(try? Data(contentsOf: file))
        var report = report
        report.at = ISO8601DateFormatter().string(from: now)
        report.paired = phone.added
        all[phone.label] = report
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(all), (try? DurableFile.write(data, to: file)) != nil else {
            return Self.empty(500)
        }
        // after the save, so a report answered 500 and sent again isn't recorded twice; a record that can't be written
        // never fails the report (opening self-check, Task 2.1)
        if let opening = report.opening {
            try? OpeningHistory.append(opening, phone: phone.label, at: now, in: pairing)
        }
        return Self.empty(204)
    }

    func manifest(for phone: TokenStore.Phone? = nil) -> Reply {
        let url = folder.appendingPathComponent("manifest.json")
        guard Self.isRegularFile(url), var data = try? Data(contentsOf: url) else { return Self.empty(404) }
        if manifestOnly {  // plan phase 8: a download the Mac keeps for itself is never named to a phone
            guard var manifest = try? Manifest.read(data) else { return Self.empty(404) }
            let withdrawn = pairing.map {
                PhoneChoices.withdrawn(try? Data(contentsOf: $0.appendingPathComponent(PhoneChoices.withdrawnName)),
                                       in: manifest)
            } ?? []
            let listedNames = manifest.files.map(\.name)
            manifest.files = manifest.files.filter(\.forPhones)
            manifest.backupKey = backupKey.flatMap { BackupSignature.readPublicKeyFile(try? Data(contentsOf: $0)) }
            manifest.choices = nil  // phase M: only this phone's, from the Mac app's file, never the delivery list's
            manifest.drop = nil  // phase 3: likewise
            var drop = withdrawn
            if let pairing, let phone {
                let all = PhoneChoices.readAll(try? Data(contentsOf: pairing.appendingPathComponent(PhoneChoices.fileName)))
                // family downloads plan, phase 3: a file the Mac set to Never for this device isn't in its list at all
                let hidden = PhoneChoices.hidden(all, for: phone.label, paired: phone.added, in: manifest)
                manifest.files.removeAll { hidden.contains($0.name) }
                drop.formUnion(hidden)
                manifest.choices = PhoneChoices.choices(all, for: phone.label, paired: phone.added,
                                                        child: phone.readOnly == true, in: manifest)
            }
            manifest.drop = drop.isEmpty ? nil : drop.sorted()
            manifest.format = FileFormat.current  // audit P2h: the format this service's build writes
            manifest.shelf = pairing.flatMap {
                LibraryShelf.read(try? Data(contentsOf: $0.appendingPathComponent(LibraryShelf.fileName)))
            }
            // a file this phone isn't sent (Mac only, never ticked; hidden; dropped) keeps its placement and description
            // on the Mac, so the phone never learns its name
            let unsent = drop.union(listedNames).subtracting(manifest.files.map(\.name))
            if var shelf = manifest.shelf, !unsent.isEmpty {
                let gone = Set(unsent.map { LibraryShelf.key(fileName: $0) })
                    .subtracting(manifest.files.map { LibraryShelf.key(fileName: $0.name) })
                shelf.placed = shelf.placed.filter { !gone.contains($0.key) }
                shelf.descriptions = shelf.descriptions.filter { !gone.contains($0.key) }
                manifest.shelf = shelf
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let filtered = try? encoder.encode(manifest) else { return Self.empty(404) }
            data = filtered
        }
        return .bytes(status: 200, headers: [("Content-Type", "application/json"), ("Cache-Control", "no-store"),
                                             ("Content-Length", String(data.count))], body: data)
    }

    func file(_ name: String, _ request: HTTPRequest, for phone: TokenStore.Phone? = nil) -> Reply {
        guard FileName.isPlain(name), name != "manifest.json" else { return Self.empty(404) }
        if manifestOnly && !listed(name, for: phone) { return Self.empty(404) }
        return serve(folder.appendingPathComponent(name), name: name, request)
    }

    /// One file, whole or one byte range, with its ETag (If-Range): the library's files and the documents' alike.
    func serve(_ url: URL, name: String, _ request: HTTPRequest) -> Reply {
        guard Self.isRegularFile(url), let handle = try? FileHandle(forReadingFrom: url) else {
            return Self.empty(404)
        }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            try? handle.close()
            return Self.empty(404)
        }
        let size = Int64(info.st_size)
        let tag = "\"\(info.st_ino)-\(size)-\(info.st_mtimespec.tv_sec)\(info.st_mtimespec.tv_nsec)\""
        var headers: [(String, String)] = [("Content-Type", "application/octet-stream"), ("Accept-Ranges", "bytes"),
                                           ("ETag", tag)]
        var range = ByteRange.parse(request.headers["range"], size: size)
        if let condition = request.headers["if-range"], condition != tag {
            range = .whole  // the file changed since the phone's first part: the whole new file
        }
        switch range {
        case .whole:
            headers.append(("Content-Length", String(size)))
            return .file(status: 200, headers: headers, handle: handle, offset: 0, length: UInt64(size),
                         bend: bend?.take(name: name, size: size, first: 0, last: size - 1))
        case let .part(start, end):
            headers.append(("Content-Range", "bytes \(start)-\(end)/\(size)"))
            headers.append(("Content-Length", String(end - start + 1)))
            return .file(status: 206, headers: headers, handle: handle, offset: UInt64(start),
                         length: UInt64(end - start + 1), bend: bend?.take(name: name, size: size, first: start,
                                                                           last: end))
        case .unsatisfiable:
            try? handle.close()
            return .bytes(status: 416, headers: [("Content-Range", "bytes */\(size)"), ("Content-Length", "0")],
                          body: Data())
        }
    }

    /// Whether the folder's manifest names `name` for the phones, and the Mac hasn't set it to Never for `phone`
    /// (family downloads plan, phase 3); a manifest that is missing or can't be read names nothing.
    func listed(_ name: String, for phone: TokenStore.Phone? = nil) -> Bool {
        let url = folder.appendingPathComponent("manifest.json")
        guard Self.isRegularFile(url), let data = try? Data(contentsOf: url),
              let manifest = try? Manifest.read(data) else { return false }
        guard manifest.files.contains(where: { $0.name == name && $0.forPhones }) else { return false }
        guard let pairing, let phone else { return true }
        let all = PhoneChoices.readAll(try? Data(contentsOf: pairing.appendingPathComponent(PhoneChoices.fileName)))
        return !PhoneChoices.hidden(all, for: phone.label, paired: phone.added, in: manifest).contains(name)
    }

    /// A plain file, not a link or a folder: a link put in the folder can't reach outside it.
    static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    public static func empty(_ status: Int) -> Reply {
        .bytes(status: status, headers: [("Content-Length", "0")], body: Data())
    }
}

/// The owner's damaged-copy test (plan phase 4, check "a one-byte-damaged copy on the Mac's side is refused"):
/// `prepareme-service bend-once NAME` leaves a note naming one served file, and the next reply that carries that file's
/// middle byte sends it changed; the note is used up by that reply. The file on disk is never written, so the next
/// download is the true file again. The note is a file beside the service's identity, read at every file request.
public struct BendOnce: Sendable {
    public static let name = "bend-once"
    public let url: URL
    private static let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public func request(_ file: String) throws {
        guard FileName.isPlain(file) else { throw Manifest.Problem.badName(file) }
        try DurableFile.write(Data(file.utf8), to: url)
    }

    /// The middle byte's offset when the note names `name` and the reply sends bytes `first` to `last` of it (the
    /// note is then removed); nil otherwise.
    func take(name: String, size: Int64, first: Int64, last: Int64) -> UInt64? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard size > 0, let data = try? Data(contentsOf: url), String(decoding: data, as: UTF8.self) == name else {
            return nil
        }
        let middle = size / 2
        guard (first...last).contains(middle) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return UInt64(middle)
    }
}
