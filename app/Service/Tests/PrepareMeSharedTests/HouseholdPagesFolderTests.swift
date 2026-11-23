import Foundation
import PrepareMeShared
import XCTest

/// The Mac's Household pages folders (phase C), on a made-up home: the starters listed first, a hand-written page
/// never written over, photos and videos kept and set aside, a deleted page moved to Backups whole.
final class HouseholdPagesFolderTests: XCTestCase {
    var home: URL!
    var folder: HouseholdPagesFolder!

    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-house-\(UUID())")
        folder = HouseholdPagesFolder(home: home)
        try FileManager.default.createDirectory(at: folder.daily, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testTheFolders() {
        let base = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Household Private")
        XCTAssertEqual(folder.daily, base.appendingPathComponent("Library/daily", isDirectory: true))
        XCTAssertEqual(folder.media, base.appendingPathComponent("Library/media", isDirectory: true))
        XCTAssertEqual(folder.backups, base.appendingPathComponent("Backups/Household pages", isDirectory: true))
    }

    func testListingStartersFirstThenTheRest() throws {
        try "---\ntitle: SAMPLE\n---\nA made-up hand-written page.\n".write(
            to: folder.daily.appendingPathComponent("rally-points.md"), atomically: true, encoding: .utf8)
        try folder.save(HouseholdPage(title: "SAMPLE Lighting the stove", steps: [.init(words: "SAMPLE")]),
                        as: "house-lighting-the-stove")
        try folder.save(HouseholdPage.starter("generator")!, as: "generator")
        XCTAssertEqual(folder.list().map(\.name), ["shutoffs", "generator", "battery-backup", "evacuation",
                                                   "rally-points", "how-we-reach-each-other", "school-pickup",
                                                   "house-lighting-the-stove"])
        XCTAssertEqual(folder.list().map(\.kind),
                       [.starter, .page, .starter, .starter, .handWritten, .starter, .starter, .page],
                       "a hand-written page keeps its starter's place and is left alone")
        XCTAssertEqual(folder.list()[4].title, "Rally points")
        XCTAssertEqual(try folder.read("shutoffs").title, "Utility shut-offs", "a starter page not written yet")
        XCTAssertThrowsError(try folder.read("rally-points")) { XCTAssertEqual($0 as? HouseholdPagesFolder.Problem, .handWritten) }
        XCTAssertThrowsError(try folder.read("house-nothing"))
        XCTAssertEqual(folder.takenNames(), ["shutoffs", "generator", "battery-backup", "evacuation", "rally-points",
                                              "how-we-reach-each-other", "school-pickup", "house-lighting-the-stove"])
    }

    /// The librarian's guides share the daily folder and are never listed (owner, 2026-10-26).
    func testTheGuidesAreNotListed() throws {
        try FileManager.default.createDirectory(at: folder.daily, withIntermediateDirectories: true)
        try "---\ntitle: SAMPLE Burns\nlife_safety: true\napproved:\nsources:\n---\nSAMPLE body\n".write(
            to: folder.daily.appendingPathComponent("sample-burns.md"), atomically: true, encoding: .utf8)
        try "---\ntitle: SAMPLE Plan\n---\nA made-up hand-written page.\n".write(
            to: folder.daily.appendingPathComponent("house-plan.md"), atomically: true, encoding: .utf8)
        XCTAssertFalse(folder.list().contains { $0.name == "sample-burns" }, "a guide")
        XCTAssertEqual(folder.list().first { $0.name == "house-plan" }?.kind, .handWritten, "a household page by hand")
    }

    /// Start from the draft (owner, 2026-10-26): a starter's page, by hand or saved, goes to Backups and the draft opens.
    func testSettingAsideForTheStarter() throws {
        try FileManager.default.createDirectory(at: folder.daily, withIntermediateDirectories: true)
        try "---\ntitle: SAMPLE\n---\nA made-up hand-written page.\n".write(
            to: folder.daily.appendingPathComponent("evacuation.md"), atomically: true, encoding: .utf8)
        try folder.save(HouseholdPage(title: "SAMPLE", steps: [.init(words: "SAMPLE")]), as: "generator")
        XCTAssertEqual(folder.list().first { $0.name == "evacuation" }?.kind, .handWritten)
        try folder.setAsideForStarter("evacuation", stamp: "2026-10-26 1200")
        try folder.setAsideForStarter("generator", stamp: "2026-10-26 1200")
        XCTAssertEqual(folder.list().first { $0.name == "evacuation" }?.kind, .starter)
        XCTAssertEqual(try folder.read("generator"), HouseholdPage.starter("generator"))
        let aside = folder.backups.appendingPathComponent("2026-10-26 1200")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: aside.path)),
                       ["evacuation.md", "generator.md"], "nothing lost")
        XCTAssertThrowsError(try folder.setAsideForStarter("house-plan", stamp: "2026-10-26 1200"), "starters only")
    }

    /// A name in Today's "Not in the library yet" line opens its starter (owner, 2026-10-26).
    func testTodaysMissingNamesFindTheirStarters() {
        XCTAssertEqual(HouseholdPagesFolder.starter(forMissing: "Battery backup"), "battery-backup")
        XCTAssertEqual(HouseholdPagesFolder.starter(forMissing: "How we reach each other"), "how-we-reach-each-other")
        XCTAssertNil(HouseholdPagesFolder.starter(forMissing: "Stop bleeding"), "a guide's words")
    }

    func testAHandWrittenPageIsNeverWrittenOver() throws {
        let url = folder.daily.appendingPathComponent("shutoffs.md")
        try "---\ntitle: SAMPLE hand-written\n---\nSAMPLE.\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try folder.save(HouseholdPage.starter("shutoffs")!, as: "shutoffs")) {
            XCTAssertEqual($0 as? HouseholdPagesFolder.Problem, .handWritten)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "---\ntitle: SAMPLE hand-written\n---\nSAMPLE.\n")
    }

    /// A starter-named file that can't be read is never taken for missing and written over (the review).
    func testAnUnreadableFileIsLeftAlone() throws {
        let url = folder.daily.appendingPathComponent("generator.md")
        try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: url)
        XCTAssertThrowsError(try folder.read("generator")) { XCTAssertEqual($0 as? HouseholdPagesFolder.Problem, .handWritten) }
        XCTAssertThrowsError(try folder.save(HouseholdPage.starter("generator")!, as: "generator"))
        XCTAssertEqual(try Data(contentsOf: url), Data([0xFF, 0xFE, 0x00, 0xC3]))
        XCTAssertEqual(folder.list()[1].kind, .handWritten)
    }

    func testPhotosAndVideosAreKeptAndSetAside() throws {
        let photo = try folder.keepPhoto(Data("SAMPLE not a real photo".utf8), page: "generator")
        XCTAssertTrue(photo.hasPrefix("generator-") && photo.hasSuffix(".jpg"))
        let clip = home.appendingPathComponent("converted.mp4")
        try Data("SAMPLE not a real video".utf8).write(to: clip)
        let video = try folder.keepVideo(clip, page: "generator")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.media.appendingPathComponent(video).path))
        try folder.setAside(photo: photo, video: video, stamp: "2026-10-19 0930")
        let aside = folder.backups.appendingPathComponent("2026-10-19 0930")
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.appendingPathComponent(photo).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.appendingPathComponent(video).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.daily.appendingPathComponent(photo).path))
    }

    /// Only a plain file name in the packer's form is ever moved: a path reaching out of the folder is refused and
    /// nothing moves; a hand-edited page naming one isn't read, so Delete moves nothing (phase K finding 3).
    func testOnlyPlainNamesAreSetAside() throws {
        try FileManager.default.createDirectory(at: folder.media, withIntermediateDirectories: true)
        let clip = folder.media.appendingPathComponent("sample.mp4")
        try Data("SAMPLE".utf8).write(to: clip)
        let page = folder.daily.appendingPathComponent("house-sample.md")
        try "---\ntitle: SAMPLE\nkind: steps\n---\n- step: SAMPLE\n  photo: ../media/sample.mp4\n".write(
            to: page, atomically: true, encoding: .utf8)
        for (photo, video) in [("../media/sample.mp4", ""), ("", "../daily/house-sample.md"), ("..", ""),
                               ("", "."), ("sub/sample.jpg", "")] {
            XCTAssertThrowsError(try folder.setAside(photo: photo, video: video, stamp: "2026-10-20 0900"), photo + video) {
                XCTAssertEqual($0 as? HouseholdPagesFolder.Problem, .notAFileName)
            }
        }
        XCTAssertThrowsError(try folder.delete("house-sample", stamp: "2026-10-20 0901"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: clip.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: page.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.backups.path), "nothing moved")
        XCTAssertEqual(folder.list().first { $0.name == "house-sample" }?.kind, .handWritten)
    }

    func testDeletingMovesThePageAndItsFilesToBackups() throws {
        var page = HouseholdPage.starter("generator")!
        page.steps[0].photo = try folder.keepPhoto(Data("SAMPLE".utf8), page: "generator")
        try folder.save(page, as: "generator")
        try folder.delete("generator", stamp: "2026-10-19 0931")
        let aside = folder.backups.appendingPathComponent("2026-10-19 0931")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: aside.path)),
                       ["generator.md", page.steps[0].photo])
        XCTAssertEqual(folder.list()[1].kind, .starter, "the starter is offered again")
        XCTAssertEqual(HouseholdPagesFolder.stamp(Date(timeIntervalSince1970: 0)).count, 15)
    }
}
