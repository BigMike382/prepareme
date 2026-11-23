import Foundation

/// One checked download from Kiwix's library into the downloads folder (build plan phase 8; Downloads.swift).
///
/// - The Metalink first; then the file into `.<name>.part`, resumed from where it stopped (an HTTP Range request for
///   the rest; a mirror that answers with the whole file starts it again), trying each mirror in turn.
/// - Only Wi-Fi or a wired network: no cellular, no iPhone hotspot and no Low Data network (each counts as expensive
///   or constrained), so a big download never runs up a data plan (owner, 2026-10-14); it waits instead. A hotspot
///   that doesn't say it is one (an Android phone's, a phone on a cable) can't be told apart (phase 8 review, 8).
/// - The file is kept, under its own name, only once its size and SHA-256 are the Metalink's; a file that isn't is
///   deleted and the download refused. The record is written after the file is in place, so a file it names is whole.
/// - There must be room for the file and a margin first, said before anything is fetched.
public enum CatalogDownload {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case metalink(Metalink.Problem)
        case unreachable  // no mirror answered, or no Wi-Fi
        case answered(Int)
        case noRoom(needed: Int64, free: Int64)
        case damaged  // the size or SHA-256 isn't the Metalink's: deleted, nothing kept
        case alreadyKept
        case cancelled
        case roomUnknown
        case recordUnreadable
        case changedAtSource(host: String)  // an outside item that isn't the vetted file: deleted, nothing kept

        public var description: String {
            switch self {
            case .metalink: "Kiwix's description of this file couldn't be read, so nothing was downloaded."
            case .unreachable: "The download is waiting: no mirror answered, or this Mac isn't on Wi-Fi or a wired "
                + "network (it never downloads over a phone's hotspot or cellular)."
            case .answered(let code): "The mirror answered \(code), so nothing was kept."
            case .noRoom(let needed, let free): Self.noRoom(StorageWords.room(need: needed, free: free))
            case .damaged: "The download wasn't the file Kiwix describes (its size or SHA-256 didn't match), so it was "
                + "deleted and nothing was kept."
            case .alreadyKept: "This file is already downloaded."
            case .cancelled: "Stopped. It picks up where it left off next time."
            case .roomUnknown: "PrepareMe couldn't read how much room this Mac has, so nothing was downloaded."
            case .recordUnreadable: "The list of kept downloads couldn't be read, so nothing was changed. Nothing was "
                + "deleted; ask for help before downloading more."
            case .changedAtSource(let host): "The file at \(host) has changed since it was checked; it waits for a "
                + "session to check it again."
            }
        }

        static func noRoom(_ sizes: (need: String, free: String)) -> String {
            "There isn't room: it needs \(sizes.need) and this Mac has \(sizes.free) free."
        }
    }

    /// Room kept free beyond the file itself.
    public static let margin: Int64 = 2_000_000_000

    public static func partURL(_ name: String, in folder: URL) -> URL {
        folder.appendingPathComponent(".\(name).part")
    }

    /// Download the file a Metalink describes into `folder`, check it, keep it and record it; the record's new entry.
    /// `progress` gets the bytes so far and the total. `session` is for tests (a stub protocol); `freeSpace` too.
    @discardableResult
    public static func run(metalink source: URL, title: String, family: Bool, folder: URL,
                           session: URLSession = CatalogDownload.session(),
                           freeSpace: (URL) -> Int64? = CatalogDownload.freeSpace,
                           progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in })
        async throws -> DownloadsRecord.File {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let described: Metalink
        do {
            let (data, response) = try await session.data(from: source)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw Failure.answered((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            described = try Metalink.parse(data)
        } catch let problem as Metalink.Problem {
            throw Failure.metalink(problem)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Self.failure(error)
        }
        guard let record = try? DownloadsRecord.load(folder) else { throw Failure.recordUnreadable }
        guard !record.files.contains(where: { $0.name == described.name }) else { throw Failure.alreadyKept }
        try await keep(described, in: folder, session: session, freeSpace: freeSpace, progress: progress,
                       mismatch: .damaged)
        let entry = DownloadsRecord.File(name: described.name, title: title, size: described.size,
                                         sha256: described.sha256, source: source.absoluteString, family: family,
                                         keptAt: ISO8601DateFormatter().string(from: Date()))
        // the record changes on the main actor only, where the Mac app's For the family and Remove change it too
        try await MainActor.run {
            guard var record = try? DownloadsRecord.load(folder) else { throw Failure.recordUnreadable }
            record.files.removeAll { $0.name == entry.name }
            record.files.append(entry)
            try record.write(folder)
        }
        return entry
    }

    /// The file `described` names, fetched into `dir` (resumed from its part-file, each mirror in turn) after the room
    /// check, then kept under its own name only once its size and SHA-256 are `described`'s; the kept file. A file that
    /// isn't is deleted and `mismatch` thrown (`.damaged` for Kiwix's; an outside item's says its site changed it).
    @discardableResult
    static func keep(_ described: Metalink, in dir: URL, session: URLSession, freeSpace: (URL) -> Int64?,
                     progress: @escaping @Sendable (Int64, Int64) -> Void, mismatch: Failure) async throws -> URL {
        let part = partURL(described.name, in: dir)
        let have = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard let free = freeSpace(dir) else { throw Failure.roomUnknown }
        if free < described.size - have + margin {
            throw Failure.noRoom(needed: described.size - have + margin, free: free)
        }
        let outside = mismatch != .damaged
        var last: Failure = .unreachable
        for mirror in described.urls {
            do {
                try await fetch(mirror, into: part, size: described.size, session: session, progress: progress)
                last = .unreachable
                break
            } catch let failure as Failure where failure == .cancelled {
                throw failure
            } catch let failure as Failure where failure == .damaged {  // longer than the file: no mirror can mend it
                try? FileManager.default.removeItem(at: part)
                throw mismatch
            } catch let failure as Failure {
                // an outside item's one address announcing another length: not the vetted file, so nothing stays
                if outside, case .answered(let code) = failure, code == 200 || code == 206 {
                    try? FileManager.default.removeItem(at: part)
                    throw mismatch
                }
                last = failure
            } catch {
                last = Self.failure(error)
            }
        }
        let got = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard got == described.size else {
            if got > described.size { try? FileManager.default.removeItem(at: part) }  // can't be the file
            throw last
        }
        guard try FileCheck.verify(part, size: described.size, sha256: described.sha256) == .ok else {
            try? FileManager.default.removeItem(at: part)
            throw mismatch
        }
        let kept = dir.appendingPathComponent(described.name)
        try? FileManager.default.removeItem(at: kept)
        try FileManager.default.moveItem(at: part, to: kept)
        return kept
    }

    /// Download an Other Sites entry's PDF into `folder`'s `outside/` (library redesign, Task 5.2), checked against the
    /// list's size and SHA-256, and record it in `outside.json`; the record's new entry.
    @discardableResult
    public static func runOutside(_ entry: OutsideList.Entry, family: Bool, folder: URL,
                                  session: URLSession = CatalogDownload.session(),
                                  freeSpace: (URL) -> Int64? = CatalogDownload.freeSpace,
                                  progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in },
                                  loopback: Bool = false)
        async throws -> OutsideRecord.File {
        guard entry.isWhole(loopback: loopback), let url = URL(string: entry.url) else { throw Failure.changedAtSource(host: entry.host) }
        let dir = folder.appendingPathComponent(OutsideRecord.folderName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let record = try? OutsideRecord.load(folder) else { throw Failure.recordUnreadable }
        // kept only as the file the list vets now: a re-checked file under the same key replaces the old line
        guard !record.files.contains(where: { $0.key == entry.key && $0.sha256 == entry.sha256 }) else {
            throw Failure.alreadyKept
        }
        let described = Metalink(name: "\(entry.key).pdf", size: entry.size, sha256: entry.sha256, urls: [url])
        try await keep(described, in: dir, session: session, freeSpace: freeSpace, progress: progress,
                       mismatch: .changedAtSource(host: entry.host))
        let file = OutsideRecord.File(key: entry.key, title: entry.title, size: entry.size, sha256: entry.sha256,
                                      family: family, keptAt: ISO8601DateFormatter().string(from: Date()))
        try await MainActor.run {  // as run's record: changed on the main actor only
            guard var record = try? OutsideRecord.load(folder) else { throw Failure.recordUnreadable }
            record.files.removeAll { $0.key == file.key }
            record.files.append(file)
            try record.write(folder)
        }
        return file
    }

    /// Remove a kept outside item: its record entry first (so the packer stops packing it), then the PDF.
    @MainActor
    public static func removeOutside(_ key: String, from folder: URL) throws {
        guard var record = try? OutsideRecord.load(folder) else { throw Failure.recordUnreadable }
        record.files.removeAll { $0.key == key }
        try record.write(folder)
        let dir = folder.appendingPathComponent(OutsideRecord.folderName)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(key).pdf"))
        try? FileManager.default.removeItem(at: partURL("\(key).pdf", in: dir))
    }

    /// Remove a kept file by its name: an Other Sites item's (`outside-<key>.zim`) from outside.json, any other from
    /// downloads.json. An outside.json that can't be read throws and nothing changes (phase 5 review): it never falls
    /// to the Kiwix record's remove.
    @MainActor
    public static func removeKept(_ name: String, from folder: URL) throws {
        if let key = OutsideRecord.key(packedName: name) {
            guard let record = try? OutsideRecord.load(folder) else { throw Failure.recordUnreadable }
            if record.files.contains(where: { $0.key == key }) { return try removeOutside(key, from: folder) }
        }
        try remove(name, from: folder)
    }

    /// Remove a kept download: its record entry first (so the packer stops listing it), then the file. A record that
    /// can't be read throws and nothing changes.
    @MainActor
    public static func remove(_ name: String, from folder: URL) throws {
        guard var record = try? DownloadsRecord.load(folder) else { throw Failure.recordUnreadable }
        record.files.removeAll { $0.name == name }
        try record.write(folder)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        try? FileManager.default.removeItem(at: partURL(name, in: folder))
    }

    /// Wi-Fi or wired only: never cellular, never a hotspot or a Low Data network.
    public static func session() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = false
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }

    public static func freeSpace(_ folder: URL) -> Int64? {
        (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// The rest of the file from one mirror, appended to `part` (a Range request from its size; a 200 starts over).
    static func fetch(_ url: URL, into part: URL, size: Int64, session: URLSession,
                      progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        if !FileManager.default.fileExists(atPath: part.path) {
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        let handle = try FileHandle(forUpdating: part)
        defer { try? handle.close() }
        var have = Int64(try handle.seekToEnd())
        guard have < size else { return }
        var request = URLRequest(url: url)
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")  // a compressed length is never the size
        var written = false
        do {
            for try await event in Chunks.of(request, session: session) {
                switch event {
                case .response(let answer):
                    switch answer.statusCode {
                    case 206:
                        break
                    case 200:  // the whole file, whatever was asked: start again
                        have = 0
                    default:
                        throw Failure.answered(answer.statusCode)
                    }
                    // A mirror answering with something else (an error page sent as 200) is left before a byte is
                    // written.
                    let announced = answer.expectedContentLength
                    if announced >= 0, announced != size - have {
                        // a page (a hotel Wi-Fi's sign-in) or a compressed answer isn't the site's file: the partial
                        // download stays and nothing is blamed on the site
                        if anotherPage(answer) { throw Failure.unreachable }
                        throw Failure.answered(answer.statusCode)
                    }
                    if answer.statusCode == 200 { try handle.truncate(atOffset: 0) }
                case .data(let piece):
                    try handle.write(contentsOf: piece)  // at once, so a cut keeps every byte that came
                    have += Int64(piece.count)
                    written = true
                    progress(have, size)
                    if have > size { throw Failure.damaged }
                }
            }
        } catch {
            if written { try? handle.synchronize() }
            throw error
        }
        try handle.synchronize()
        if Task.isCancelled { throw Failure.cancelled }  // a cancelled request ends its stream without an error
    }

    /// An answer that is plainly not a file's bytes: compressed, or a text page.
    static func anotherPage(_ answer: HTTPURLResponse) -> Bool {
        let encoding = answer.value(forHTTPHeaderField: "Content-Encoding")?.lowercased() ?? "identity"
        let type = answer.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        return encoding != "identity" || type.hasPrefix("text/")
    }

    /// A request's answer and its bytes as they arrive (a data task's delegate), so each piece reaches the disk before
    /// the next; cancelling the loop cancels the request.
    enum Chunks {
        enum Event {
            case response(HTTPURLResponse)
            case data(Data)
        }

        static func of(_ request: URLRequest, session: URLSession) -> AsyncThrowingStream<Event, Error> {
            AsyncThrowingStream { continuation in
                let relay = Relay(continuation)
                let task = session.dataTask(with: request)
                task.delegate = relay
                continuation.onTermination = { _ in task.cancel() }
                task.resume()
            }
        }

        final class Relay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
            let continuation: AsyncThrowingStream<Event, Error>.Continuation

            init(_ continuation: AsyncThrowingStream<Event, Error>.Continuation) {
                self.continuation = continuation
            }

            func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
                guard let answer = response as? HTTPURLResponse else {
                    continuation.finish(throwing: Failure.unreachable)
                    return completionHandler(.cancel)
                }
                continuation.yield(.response(answer))
                completionHandler(.allow)
            }

            func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
                continuation.yield(.data(data))
            }

            func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                if let error { continuation.finish(throwing: error) } else { continuation.finish() }
            }
        }
    }

    static func failure(_ error: Error) -> Failure {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
        return .unreachable
    }
}
