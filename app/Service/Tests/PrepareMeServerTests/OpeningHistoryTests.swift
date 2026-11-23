import Foundation
@testable import PrepareMeServer
import PrepareMeShared
import Testing

/// The opening self-check, phase 2 (docs/plans/2026-11-14-opening-self-check.md, Task 2.1): the Mac keeps one line per
/// room report whose tally has openings, beside `phones-storage.json`. Made-up reports in a fresh temporary folder.
struct OpeningHistoryTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-openings-\(UUID())")
    var pairing: URL { root.appendingPathComponent("pairing") }
    var history: URL { pairing.appendingPathComponent(OpeningHistory.fileName) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func report(openings: Int, failed: [String: Int] = [:]) -> OpeningCheck.Report {
        let last = OpeningCheck.Result(build: "250", lines: [.init(kind: "daily", state: .failed, ms: 120)],
                                       stopped: false)
        return OpeningCheck.Report(last: last, tally: .init(openings: openings, failed: failed, slowestMs: 120))
    }

    /// A paired phone's room report through the router, as the phone sends it; the router's answer
    func send(_ opening: OpeningCheck.Report?) throws -> Int {
        try FileManager.default.createDirectory(at: pairing, withIntermediateDirectories: true)
        let tokens = TokenStore(url: root.appendingPathComponent("tokens.json"))
        let token = try tokens.add(now: now).token
        let router = Router(folder: root, tokens: tokens, counts: CountsStore(url: root.appendingPathComponent("c.json")),
                            manifestOnly: true, pairing: pairing)
        let body = try JSONEncoder().encode(PhoneStorage(free: 1, capacity: 2, held: [], waiting: [], cantUpdate: [],
                                                         build: "250", opening: opening))
        let request = HTTPRequest(method: "POST", path: "/storage", headers: ["authorization": "Bearer " + token],
                                  body: body)
        return router.reply(to: request, now: now).0.status
    }

    func lines() throws -> [[String: Any]] {
        try String(contentsOf: history, encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    @Test func aReportsTallyIsAppendedOnce() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try send(Self.report(openings: 3, failed: ["daily": 2])) == 204)
        let rows = try lines()
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.keys.sorted() == ["at", "build", "crashes", "failed", "hangs", "late", "openings", "phone",
                                      "slowest_ms", "stopped"])
        #expect(row["phone"] as? String == "phone 1")
        #expect(row["build"] as? String == "250")
        #expect(row["openings"] as? Int == 3)
        #expect(row["failed"] as? [String: Int] == ["daily": 2])
        #expect(row["slowest_ms"] as? Int == 120)
        #expect(row["crashes"] is NSNull)
        #expect(row["at"] as? String == ISO8601DateFormatter().string(from: now))
        let text = try String(contentsOf: history, encoding: .utf8)
        #expect(text.hasPrefix(#"{"at":"#), "sorted keys")
        #expect(text.hasSuffix("\n"))
    }

    @Test func anEmptyTallyAddsNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try send(Self.report(openings: 0)) == 204)
        #expect(try send(nil) == 204)
        #expect(!FileManager.default.fileExists(atPath: history.path))
    }

    @Test func aCrashOnlyTallyIsStillRecorded() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try send(OpeningCheck.diagnosed(nil, build: "250", crashes: 2, hangs: 1)) == 204)
        let row = try #require(try lines().first)
        #expect(row["openings"] as? Int == 0)
        #expect(row["crashes"] as? Int == 2)
        #expect(row["hangs"] as? Int == 1)
        #expect(row["build"] as? String == "250")
        #expect(try send(OpeningCheck.diagnosed(nil, build: "250", crashes: 0, hangs: 0)) == 204)
        #expect(try lines().count == 1, "a report with no crash, hang or opening adds nothing")
    }

    @Test func theFileKeepsItsLastFiveThousandLines() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: pairing, withIntermediateDirectories: true)
        let old = (0..<OpeningHistory.most).map { #"{"openings":\#($0)}"# }.joined(separator: "\n") + "\n"
        try Data(old.utf8).write(to: history)
        try OpeningHistory.append(Self.report(openings: 7), phone: "phone 2", at: now, in: pairing)
        let rows = try lines()
        #expect(rows.count == OpeningHistory.most)
        #expect(rows.first?["openings"] as? Int == 1, "the oldest line went")
        #expect(rows.last?["phone"] as? String == "phone 2")
        #expect(rows.last?["openings"] as? Int == 7)
    }

    @Test func aRecordThatCannotBeWrittenStillTakesTheReport() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)  // a folder in its place
        #expect(try send(Self.report(openings: 2)) == 204)
        let kept = PhoneStorage.readAll(try Data(contentsOf: pairing.appendingPathComponent(PhoneStorage.fileName)))
        #expect(kept["phone 1"]?.opening?.tally.openings == 2, "the room report itself was kept")
        #expect(throws: (any Error).self) {
            try OpeningHistory.append(Self.report(openings: 1), phone: "phone 1", at: now, in: pairing)
        }
    }
}
