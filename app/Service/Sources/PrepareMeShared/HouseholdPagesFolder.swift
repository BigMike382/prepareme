import Foundation

/// Where the Mac's Household pages keeps its pages (concept-doc plan, phase C): Household Private › Library › daily
/// (the pages and their photos, which the packer reads into the daily library), › Library › media (the steps' videos,
/// into the video library) and › Backups › Household pages (a deleted page, and any photo or video taken off a step, set
/// aside rather than gone for good). The sandbox opens exactly these three folders (PrepareMe-macOS.entitlements); the
/// check build has the same layout under its scratch home. A page the Mac didn't write (no `kind: steps`) is listed as
/// written by hand and never written over.
public struct HouseholdPagesFolder: Sendable {
    public let daily, media, backups: URL

    public init(home: URL) {
        let base = Self.householdPrivate(home: home)
        daily = base.appendingPathComponent("Library/daily", isDirectory: true)
        media = base.appendingPathComponent("Library/media", isDirectory: true)
        backups = base.appendingPathComponent("Backups/Household pages", isDirectory: true)
    }

    public enum Kind: Equatable, Sendable {
        case page, handWritten, starter  // a page the Mac wrote, one it didn't, a starter page not written yet
    }

    public struct Listed: Equatable, Identifiable, Hashable, Sendable {
        public let name, title: String
        public let kind: Kind
        public var blanksLeft = 0  // a page's, for the editor's list (Our Home plan, Task 2.5)
        public var walked = ""  // YYYY-MM-DD, or "" when never walked through
        public var id: String { name }
    }

    public enum Problem: Error, Equatable, Sendable {
        case handWritten  // the name holds a page the Mac didn't write
        case missing
        case notAFileName  // a step's photo or video named something other than a plain file name
    }

    // MARK: Listing and reading

    /// The pages: the starters first (written or not), in their order, then the rest by title. The librarian's guides
    /// share the folder and are never listed (owner, 2026-10-26: they showed as pages written by hand).
    public func list() -> [Listed] {
        var found: [String: Listed] = [:]
        for url in (try? FileManager.default.contentsOfDirectory(at: daily, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "md" && !url.lastPathComponent.hasPrefix(".") {
            let name = url.deletingPathExtension().lastPathComponent
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""  // unreadable: listed as by hand
            if Self.isGuide(text) && !HouseholdPage.starterNames.contains(name) { continue }
            if HouseholdPage.isSteps(text), let page = try? HouseholdPage(markdown: text) {
                found[name] = Listed(name: name, title: page.title, kind: .page, blanksLeft: page.blanksLeft, walked: page.walked)
            } else {
                found[name] = Listed(name: name, title: Self.readable(name), kind: .handWritten)
            }
        }
        let starters = HouseholdPage.starterNames.map { name in
            found[name] ?? Listed(name: name, title: HouseholdPage.starter(name)?.title ?? name, kind: .starter)
        }
        let rest = found.values.filter { !HouseholdPage.starterNames.contains($0.name) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return starters + rest
    }

    /// The page `name`: its file, or its starter page when it has none yet.
    public func read(_ name: String) throws -> HouseholdPage {
        let url = file(name)
        guard FileManager.default.fileExists(atPath: url.path) else {  // only a file truly absent is a starter
            if let starter = HouseholdPage.starter(name) { return starter }
            throw Problem.missing
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw Problem.handWritten }
        guard HouseholdPage.isSteps(text) else { throw Problem.handWritten }
        return try HouseholdPage(markdown: text)
    }

    public func takenNames() -> Set<String> { Set(list().map(\.name)) }

    /// A guide's file as the librarian writes it (librarian/condense.py's page_header): its header has a
    /// `life_safety:` line, which no household page has.
    static func isGuide(_ text: String) -> Bool {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex,
                                                                                           offsetBy: 4)..<text.endIndex)
        else { return false }
        return text[..<end.lowerBound].split(separator: "\n").contains { $0.hasPrefix("life_safety: ") }
    }

    func file(_ name: String) -> URL { daily.appendingPathComponent("\(name).md") }

    /// The starter page a name in Today's "Not in the library yet" line is, by the words Today gives it
    /// (readiness.model.readable_name: "Battery backup"); nil for any other name, a guide's among them.
    public static func starter(forMissing words: String) -> String? {
        HouseholdPage.starterNames.first { readable($0) == words }
    }

    /// "battery-backup" as "Battery backup".
    static func readable(_ name: String) -> String {
        let spaced = name.replacingOccurrences(of: "-", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    // MARK: Writing

    /// Saves `page` as `name`, whole (DurableFile); never over a page the Mac didn't write.
    public func save(_ page: HouseholdPage, as name: String) throws {
        let url = file(name)
        if FileManager.default.fileExists(atPath: url.path) {  // unreadable counts as by hand: never written over
            guard let text = try? String(contentsOf: url, encoding: .utf8), HouseholdPage.isSteps(text) else {
                throw Problem.handWritten
            }
        }
        try FileManager.default.createDirectory(at: daily, withIntermediateDirectories: true)
        try DurableFile.write(Data(page.markdown.utf8), to: url)
    }

    /// Keeps a checked photo (a JPEG) beside page `name`; its file's name.
    public func keepPhoto(_ jpeg: Data, page name: String) throws -> String {
        try FileManager.default.createDirectory(at: daily, withIntermediateDirectories: true)
        let file = HouseholdPage.mediaName(page: name, ext: "jpg")
        try DurableFile.write(jpeg, to: daily.appendingPathComponent(file))
        return file
    }

    /// Keeps a checked, converted video (an .mp4 at `converted`) for page `name` in the video library's folder; its
    /// file's name.
    public func keepVideo(_ converted: URL, page name: String) throws -> String {
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let file = HouseholdPage.mediaName(page: name, ext: "mp4")
        try DurableFile.write(try Data(contentsOf: converted), to: media.appendingPathComponent(file))
        return file
    }

    /// Sets a step's photo or video aside in Backups › Household pages (`stamp`'s folder) rather than deleting it. Only
    /// a plain file name in the packer's form is moved (HouseholdPage's patterns): anything else, a path among them, is
    /// refused before anything moves.
    public func setAside(photo: String = "", video: String = "", stamp: String) throws {
        guard photo.isEmpty || GuideTopics.matches(photo, HouseholdPage.photoPattern),
              video.isEmpty || GuideTopics.matches(video, HouseholdPage.videoPattern) else { throw Problem.notAFileName }
        if !photo.isEmpty { try move(daily.appendingPathComponent(photo), stamp: stamp) }
        if !video.isEmpty { try move(media.appendingPathComponent(video), stamp: stamp) }
    }

    /// Deletes page `name` (one the Mac wrote): the page, its photos and its videos go to Backups › Household pages.
    public func delete(_ name: String, stamp: String) throws {
        let page = try read(name)
        let url = file(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw Problem.missing }
        for step in page.steps { try setAside(photo: step.photo, video: step.video, stamp: stamp) }
        try move(url, stamp: stamp)
    }

    /// A starter-named page set aside for its draft (owner, 2026-10-26: "starter pages for everything"): a page written
    /// by hand, or one saved here, goes to Backups › Household pages (`stamp`'s folder; a saved page with its photos
    /// and videos, as Delete), so `read` gives the starter again. Only a starter's name.
    public func setAsideForStarter(_ name: String, stamp: String) throws {
        guard HouseholdPage.starter(name) != nil else { throw Problem.missing }
        if let text = try? String(contentsOf: file(name), encoding: .utf8), HouseholdPage.isSteps(text) {
            try delete(name, stamp: stamp)
        } else {
            try move(file(name), stamp: stamp)
        }
    }

    func move(_ url: URL, stamp: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let folder = backups.appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var target = folder.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(n) \(url.lastPathComponent)")
            n += 1
        }
        try FileManager.default.moveItem(at: url, to: target)
    }

    // MARK: Draft packs (Our Home plan, Task 3.1)

    /// A draft a session wrote (a folder holding page.md and its pictures), read and checked, nothing kept yet.
    public struct DraftPack: Equatable, Sendable {
        public let name: String  // the page's name: a starter's, or a new page's newName
        public let page: HouseholdPage
        public let pictures: [URL]  // every picture the page names, plain files beside page.md
        public let ignored: [String]  // what isn't imported (sources.md, a manual's PDF), for the import sheet
    }

    /// Why a draft is refused, in fixed words; nothing is imported.
    public enum DraftProblem: Error, Equatable, Sendable {
        case noPage, notThisForm(String), pictureMissing(String), pictureNotNamed(String), symbolicLink,
             inHouseholdPrivate, video

        public var words: String {
            let why = switch self {
            case .noPage: "The draft has no page.md."
            case .notThisForm(let form): "The draft's page.md isn't in Our Home's form: \(form)"
            case .pictureMissing(let file): "The page names a picture the draft doesn't hold: \(file)."
            case .pictureNotNamed(let file): "The draft holds a picture its page doesn't name: \(file)."
            case .symbolicLink: "The draft holds a symbolic link, which could point anywhere."
            case .inHouseholdPrivate: "The draft is inside Household Private. A draft comes from PrepareMe Drafts."
            case .video: "The draft's page names a video. A draft never brings one: add it here after importing."
            }
            return why + " Nothing was imported."
        }
    }

    /// Household Private under `home`, as `init` finds it.
    static func householdPrivate(home: URL) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Household Private", isDirectory: true)
    }

    /// Reads the draft pack `folder` (it writes nothing). Its name is the page's name when it is a starter's; any other
    /// gets newName. Refused: a symbolic link anywhere in it, the pack itself included; a folder in Household Private
    /// under `home`; no page.md; a page.md not in the form, or naming a video; a named picture that isn't a plain file
    /// beside it; a picture (a file matching photoPattern) the page doesn't name. Other files are ignored.
    public static func readDraft(_ folder: URL, home: URL) throws -> DraftPack {
        let files = FileManager.default
        let path = folder.standardizedFileURL.path
        guard (try? files.attributesOfItem(atPath: path)[.type] as? FileAttributeType) != .typeSymbolicLink
        else { throw DraftProblem.symbolicLink }
        let inside = { (url: URL) in url.path.lowercased() + "/" }  // the Mac's disk ignores case
        let privateFolder = householdPrivate(home: home)
        for (pack, base) in [(folder.standardizedFileURL, privateFolder.standardizedFileURL),
                             (folder.resolvingSymlinksInPath(), privateFolder.resolvingSymlinksInPath())]
        where inside(pack).hasPrefix(inside(base)) {
            throw DraftProblem.inHouseholdPrivate
        }
        for case let url as URL in files.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects ?? []
        where (try? files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
            throw DraftProblem.symbolicLink
        }
        guard let text = try? String(contentsOf: folder.appendingPathComponent("page.md"), encoding: .utf8)
        else { throw DraftProblem.noPage }
        let page: HouseholdPage
        do { page = try HouseholdPage(markdown: text) } catch HouseholdPage.Problem.notThisForm(let why) {
            throw DraftProblem.notThisForm(why)
        }
        guard page.steps.allSatisfy({ $0.video.isEmpty }) else { throw DraftProblem.video }
        let top = (try? files.contentsOfDirectory(atPath: path))?.sorted() ?? []
        let isFile = { (name: String) in
            (try? files.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.type] as? FileAttributeType)
                == .typeRegular
        }
        let pictures = top.filter { GuideTopics.matches($0, HouseholdPage.photoPattern) && isFile($0) }
        var named: [String] = []
        for step in page.steps where !step.photo.isEmpty && !named.contains(step.photo) { named.append(step.photo) }
        if let missing = named.first(where: { !pictures.contains($0) }) { throw DraftProblem.pictureMissing(missing) }
        if let extra = pictures.first(where: { !named.contains($0) }) { throw DraftProblem.pictureNotNamed(extra) }
        let name = folder.lastPathComponent
        return DraftPack(name: HouseholdPage.starterNames.contains(name) ? name
                             : HouseholdPage.newName(taken: HouseholdPagesFolder(home: home).takenNames()),
                         page: page, pictures: named.map { folder.appendingPathComponent($0) },
                         ignored: top.filter { $0 != "page.md" && !named.contains($0) && !$0.hasPrefix(".") })
    }

    /// A backup folder's name for now: "2026-10-19 0930".
    public static func stamp(_ date: Date = Date()) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HHmm"
        return format.string(from: date)
    }
}
