import Foundation
@testable import PrepareMeServer
import XCTest

/// prepareme-service's command line is checked whole before anything runs (FINDINGS F-087: `pair --help` ran `pair`
/// on the real service folder). The checks run on made-up arguments; the one test that runs the command passes a
/// temporary `--support` every time, never the owner's folder.
final class ServiceCommandLineTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    var real: String { home.path + "/Library/Application Support/PrepareMe" }

    func check(_ arguments: [String], session: Bool = false) -> ServiceCommandLine.Verdict {
        ServiceCommandLine.check(arguments, session: session, home: home)
    }

    func refused(_ arguments: [String], session: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        guard case .refused = check(arguments, session: session) else {
            return XCTFail("\(arguments) wasn't refused", file: file, line: line)
        }
    }

    func testHelpOptionsAreRefusedOnEveryCommand() {
        for command in ["init", "pair", "phones", "unpair", "serve", "swap", "count-alerts", "library", "bend-once"] {
            refused([command, "--help"])
            refused([command, "-h"])
        }
        refused(["--help"])
        refused(["-h", "pair"])
    }

    func testHelpCommandIsHelp() {
        XCTAssertEqual(check(["help"]), .help)
        XCTAssertEqual(check(["help"], session: true), .help)
        refused(["help", "pair"])
    }

    func testUnknownOptionsAreRefused() {
        refused(["pair", "--txt"])
        refused(["swap", "--damage"])
        refused(["pair", "--agent"])  // only the library runs as the app's agent
        refused(["pair", "--loopback"])
        refused(["init", "--port", "8799"])
        refused(["phones", "--folder", "/tmp/x"])
        refused(["unpair", "phone 1", "--force"])
    }

    func testTheOwnersAndTheAppsCommandsRun() {
        XCTAssertEqual(check(["init"]), .run)
        XCTAssertEqual(check(["pair"]), .run)
        XCTAssertEqual(check(["pair", "--port", "8744"]), .run)
        XCTAssertEqual(check(["pair", "--port", "8744", "--read-only"]), .run)
        XCTAssertEqual(check(["pair", "--text", "--read-only", "--support", "/tmp/s", "--port", "8799"]), .run)
        XCTAssertEqual(check(["phones"]), .run)
        XCTAssertEqual(check(["unpair", "phone 1"]), .run)
        XCTAssertEqual(check(["serve"]), .run)
        XCTAssertEqual(check(["serve", "--loopback", "--port", "8799", "--size-mb", "1"]), .run)
        XCTAssertEqual(check(["swap"]), .run)
        XCTAssertEqual(check(["swap", "--damaged"]), .run)
        XCTAssertEqual(check(["count-alerts", "/tmp/alerts.json"]), .run)
        XCTAssertEqual(check(["library", "--agent"]), .run)  // the app's launch agent (com.bigmike382.prepareme.service)
        XCTAssertEqual(check(["--support", "/tmp/s", "library", "--loopback"]), .run)  // options may come first
        XCTAssertEqual(check(["bend-once", "guides.zim"]), .run)
    }

    func testMissingCommandsAndWordsAreLeftToTheCommandsOwnLines() {
        refused([])
        refused(["--support", "/tmp/s"])
        refused(["pairs"])
        XCTAssertEqual(check(["unpair"]), .run)  // main.swift's "unpair takes a label" answers it
        refused(["pair", "phone 1"])
        refused(["unpair", "phone 1", "phone 2"])
    }

    func testOptionValuesMustBeThere() {
        refused(["pair", "--support"])  // with no folder it would fall back to the real one
        refused(["pair", "--support", "--text"])
        refused(["pair", "--port"])
        refused(["--support", "/tmp/a", "--support", "/tmp/b", "pair"])
        refused(["pair", "--text", "--text"])
    }

    func testASessionMustNameItsOwnFolders() {
        for command in [["init"], ["pair"], ["phones"], ["unpair", "phone 1"], ["serve"], ["swap"],
                        ["bend-once", "guides.zim"], ["library", "--loopback"]] {
            refused(command, session: true)
            XCTAssertEqual(check(command), .run, "\(command) outside a session")
        }
        XCTAssertEqual(check(["pair", "--text", "--support", "/tmp/s"], session: true), .run)
        XCTAssertEqual(check(["count-alerts", "/tmp/alerts.json"], session: true), .run)  // it reads only its file
        // The library reads the delivery and inventory folders too: a session names both.
        refused(["library", "--support", "/tmp/s", "--loopback"], session: true)
        refused(["library", "--support", "/tmp/s", "--folder", "/tmp/d", "--loopback"], session: true)
        XCTAssertEqual(check(["library", "--loopback", "--port", "8799", "--support", "/tmp/s", "--folder", "/tmp/d",
                              "--inventory", "/tmp/i", "--pairing", "/tmp/p"], session: true), .run)
    }

    func testASessionCantNameTheRealFolders() {
        refused(["pair", "--support", real + "/service"], session: true)
        refused(["pair", "--support", real.lowercased() + "/service"], session: true)  // the disk ignores case
        refused(["pair", "--support", real + "/service/../service"], session: true)
        refused(["pair", "--support", real], session: true)
        refused(["serve", "--support", "/tmp/s", "--jobs", real + "/jobs"], session: true)
        refused(["library", "--support", "/tmp/s", "--folder", real + "/delivery", "--inventory", "/tmp/i"],
                session: true)
        refused(["library", "--support", "/tmp/s", "--folder", "/tmp/d", "--inventory", real + "/inventory"],
                session: true)
        refused(["library", "--support", "/tmp/s", "--folder", "/tmp/d", "--inventory", "/tmp/i",
                 "--pairing", real + "/pairing"], session: true)
        // A check build's made-up home has the same shape under a scratch folder, and is fine.
        let check = "/tmp/s/Library/Application Support/PrepareMe"
        XCTAssertEqual(self.check(["library", "--support", check + "/service", "--folder", check + "/delivery",
                                   "--inventory", check + "/inventory"], session: true), .run)
        XCTAssertEqual(self.check(["pair", "--support", real + "x/service"], session: true), .run)  // not inside it
    }

    func testRefusalsAreFixedWords() {
        guard case .refused(let line) = check(["pair", "--help"]) else { return XCTFail("not refused") }
        XCTAssertTrue(line.contains("nothing was done"), line)
        XCTAssertTrue(ServiceCommandLine.usage.hasPrefix("usage: prepareme-service "))
    }

    // MARK: the command itself, on a temporary --support

    /// The built command, beside this test bundle in .build.
    var command: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("prepareme-service")
    }

    func run(_ arguments: [String]) throws -> (status: Int32, error: String) {
        let process = Process()
        process.executableURL = command
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func contents(_ folder: URL) -> [String] {
        let all = FileManager.default.enumerator(atPath: folder.path)?.allObjects as? [String] ?? []
        return all.sorted()
    }

    func testTheCommandRefusesBeforeWritingAnything() throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: command.path), "build prepareme-service first")
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-cli-test-\(UUID())")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        try Identity.make(in: support)  // so a `pair` that ran would add a phone here
        let before = contents(support)
        for arguments in [["pair", "--help"], ["pair", "-h"], ["pair", "--txt"], ["swap", "--damage", "--size-mb", "0"],
                          ["unpair", "phone 1", "--force"], ["bend-once", "guides.zim", "--help"]] {
            let (status, error) = try run(arguments + ["--support", support.path])
            XCTAssertEqual(status, 2, "\(arguments)")
            XCTAssertTrue(error.contains("usage: prepareme-service"), "\(arguments): \(error)")
            XCTAssertEqual(contents(support), before, "\(arguments) wrote in its folder")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("tokens.json").path))
    }

    // MARK: Unlisted plan, phase 3

    /// `library --home-network`, the test service a spare device reaches (decision 8): its own port, every folder named
    /// and each a scratch folder, never with --loopback; refused that way for the owner's Terminal too.
    func testTheHomeNetworkTestServiceTakesOnlyScratchFoldersAndItsOwnPort() {
        let folders = ["--support", "/tmp/t/s", "--folder", "/tmp/t/d", "--inventory", "/tmp/t/i", "--pairing",
                       "/tmp/t/p", "--documents", "/private/tmp/t/e"]
        let line = ["library", "--home-network", "--port", "8799"] + folders
        XCTAssertEqual(check(line), .run)
        XCTAssertEqual(check(line, session: true), .run)
        for session in [false, true] {
            refused(line + ["--loopback"], session: session)
            refused(["library", "--home-network"] + folders, session: session)  // no port
            refused(["library", "--home-network", "--port", "8744"] + folders, session: session)
            refused(["library", "--home-network", "--port", "8743"] + folders, session: session)
            refused(Array(line.dropLast(2)), session: session)  // no --documents
            var real = line
            real[real.firstIndex(of: "/tmp/t/d")!] = home.path + "/Library/Application Support/PrepareMe/delivery"
            refused(real, session: session)
            var homes = line
            homes[homes.firstIndex(of: "/tmp/t/i")!] = "/Users/someone/scratch"
            refused(homes, session: session)
            var bare = line
            bare[bare.firstIndex(of: "/tmp/t/p")!] = "/tmp"
            refused(bare, session: session)
        }
        refused(["serve", "--home-network", "--port", "8799"] + folders)  // the library's alone
    }

    /// A test service is one started with its own --support; the family's Mac's (no --support) never is.
    func testOnlyAServiceWithItsOwnSupportFolderIsATestService() {
        XCTAssertFalse(ServiceCommandLine.isTestService(support: nil, home: home))
        XCTAssertFalse(ServiceCommandLine.isTestService(
            support: home.appendingPathComponent("Library/Application Support/PrepareMe/service"), home: home))
        XCTAssertTrue(ServiceCommandLine.isTestService(support: URL(fileURLWithPath: "/tmp/t/s"), home: home))
    }
}
