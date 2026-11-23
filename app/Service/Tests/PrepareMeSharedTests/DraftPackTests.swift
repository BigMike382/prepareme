import Foundation
import PrepareMeShared
import Testing

/// Reading a draft pack (Our Home plan, Task 3.1), on a made-up home: a good pack reads to its page, and each refusal
/// keeps nothing (nothing written under the scratch home).
@Suite struct DraftPackTests {
    let home: URL, drafts: URL, folder: HouseholdPagesFolder
    let page = """
        ---
        title: SAMPLE Utility shut-offs
        kind: steps
        ---
        - step: SAMPLE Turn the handle [Fill in: left or right?].
          photo: shutoffs-1.jpg
        - step: SAMPLE Check the meter.
          photo: shutoffs-2.png
        - step: SAMPLE Done.

        """

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-draft-\(UUID())")
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-drafts-\(UUID())")
        folder = HouseholdPagesFolder(home: home)
        try FileManager.default.createDirectory(at: folder.daily, withIntermediateDirectories: true)
    }

    /// A pack named `name` in the drafts folder: page.md (`text`, or the made-up page), the two pictures, and `extra` files.
    func pack(_ name: String = "shutoffs", page text: String? = nil, pictures: [String] = ["shutoffs-1.jpg", "shutoffs-2.png"],
              extra: [String] = ["sources.md", "SAMPLE manual.pdf"], under base: URL? = nil) throws -> URL {
        let url = (base ?? drafts).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try (text ?? page).write(to: url.appendingPathComponent("page.md"), atomically: true, encoding: .utf8)
        for file in pictures + extra { try Data("SAMPLE".utf8).write(to: url.appendingPathComponent(file)) }
        return url
    }

    /// Nothing under the scratch home but the empty daily folder made in init.
    func nothingWritten() throws {
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.daily.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.backups.path))
        #expect(!FileManager.default.fileExists(atPath: folder.media.path))
    }

    func refused(_ url: URL, _ problem: HouseholdPagesFolder.DraftProblem) throws {
        #expect(throws: problem) { try HouseholdPagesFolder.readDraft(url, home: home) }
        try nothingWritten()
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.removeItem(at: drafts)
    }

    @Test func aGoodPackReadsToItsPage() throws {
        let read = try HouseholdPagesFolder.readDraft(try pack(), home: home)
        #expect(read.name == "shutoffs")
        #expect(read.page == (try HouseholdPage(markdown: page)))
        #expect(read.pictures.map(\.lastPathComponent) == ["shutoffs-1.jpg", "shutoffs-2.png"])
        #expect(read.ignored == ["SAMPLE manual.pdf", "sources.md"], "what isn't imported, for the sheet")
        try nothingWritten()
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.removeItem(at: drafts)
    }

    @Test func aPackNotNamedForAStarterIsANewPage() throws {
        let read = try HouseholdPagesFolder.readDraft(try pack("lighting the stove"), home: home)
        #expect(read.name.hasPrefix("house-") && read.name != "house-lighting-the-stove", "newName, never the folder's words")
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.removeItem(at: drafts)
    }

    @Test func noPage() throws {
        let url = try pack()
        try FileManager.default.removeItem(at: url.appendingPathComponent("page.md"))
        try refused(url, .noPage)
    }

    @Test func notInTheForm() throws {
        try refused(try pack(page: "---\ntitle: SAMPLE\n---\nSAMPLE\n"), .notThisForm("It needs a title and kind: steps."))
    }

    @Test func aNamedPictureMissing() throws {
        try refused(try pack(pictures: ["shutoffs-1.jpg"]), .pictureMissing("shutoffs-2.png"))
    }

    @Test func aNamedPictureThatIsAFolder() throws {
        let url = try pack(pictures: ["shutoffs-1.jpg"])
        try FileManager.default.createDirectory(at: url.appendingPathComponent("shutoffs-2.png"), withIntermediateDirectories: true)
        try refused(url, .pictureMissing("shutoffs-2.png"))
    }

    @Test func aPictureThePageDoesntName() throws {
        try refused(try pack(pictures: ["shutoffs-1.jpg", "shutoffs-2.png", "shutoffs-9.jpeg"]), .pictureNotNamed("shutoffs-9.jpeg"))
    }

    @Test func aSymbolicLinkAnywhere() throws {
        let url = try pack()
        try FileManager.default.createDirectory(at: url.appendingPathComponent("more"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("more/notes.md"),
                                                   withDestinationURL: url.appendingPathComponent("sources.md"))
        try refused(url, .symbolicLink)
    }

    @Test func aPictureThatIsALink() throws {
        let url = try pack(pictures: ["shutoffs-1.jpg"])
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("shutoffs-2.png"),
                                                   withDestinationURL: url.appendingPathComponent("shutoffs-1.jpg"))
        try refused(url, .symbolicLink)
    }

    @Test func thePackItselfALink() throws {
        let url = try pack()
        let link = drafts.appendingPathComponent("generator")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        try refused(link, .symbolicLink)
    }

    @Test func aFolderUnderHouseholdPrivate() throws {
        let base = folder.daily.deletingLastPathComponent().deletingLastPathComponent()  // Household Private
        let url = try pack(under: base.appendingPathComponent("Drafts"))
        #expect(throws: HouseholdPagesFolder.DraftProblem.inHouseholdPrivate) { try HouseholdPagesFolder.readDraft(url, home: home) }
        let shouted = URL(fileURLWithPath: url.path.replacingOccurrences(of: "Household Private", with: "HOUSEHOLD PRIVATE"))
        #expect(throws: HouseholdPagesFolder.DraftProblem.inHouseholdPrivate, "the Mac's disk ignores case") {
            try HouseholdPagesFolder.readDraft(shouted, home: home)
        }
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.removeItem(at: drafts)
    }

    @Test func aVideoLine() throws {
        try refused(try pack(page: page.replacingOccurrences(of: "- step: SAMPLE Done.", with: "- step: SAMPLE Done.\n  video: shutoffs-3.mp4")),
                    .video)
    }

    @Test func everyProblemHasItsWords() {
        let all: [HouseholdPagesFolder.DraftProblem] = [.noPage, .notThisForm("It has no steps."), .pictureMissing("a.jpg"),
                                                        .pictureNotNamed("b.jpg"), .symbolicLink, .inHouseholdPrivate, .video]
        #expect(Set(all.map(\.words)).count == all.count)
        #expect(all.allSatisfy { $0.words.hasSuffix("Nothing was imported.") })
        #expect(HouseholdPagesFolder.DraftProblem.notThisForm("It has no steps.").words.contains("It has no steps."))
    }
}
