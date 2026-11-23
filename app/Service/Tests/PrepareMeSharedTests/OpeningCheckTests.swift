import Foundation
import Testing
@testable import PrepareMeShared

/// The opening self-check (docs/plans/2026-11-14-opening-self-check.md, phase 1): the probes run together under a cap
/// and a limit, the words for Home Mac › This install and the Mac, the tally, and what the Mac will read.
struct OpeningCheckTests {
    typealias Line = OpeningCheck.Line

    static func lines(_ states: [OpeningCheck.State], ms: Int = 100) -> [Line] {
        zip(OpeningCheck.kinds, states).map { Line(kind: $0, state: $1, ms: ms) }
    }

    static let allOK = OpeningCheck.Result(
        build: "2026.1114.1701", lines: lines(Array(repeating: .ok, count: 7) + [.skipped]), stopped: false)

    static func probe(_ kind: String, after wait: Duration = .zero, _ state: OpeningCheck.State = .ok)
        -> OpeningCheck.Probe {
        OpeningCheck.Probe(kind: kind) {
            if wait > .zero { try? await Task.sleep(for: wait) }
            return state
        }
    }

    @Test func allPassedSaysSoWithTheTime() {
        var result = Self.allOK
        result.lines[2].ms = 400
        #expect(OpeningCheck.words(result) == "Opening check: all 7 passed (0.4 s)")
        #expect(result.failed.isEmpty)
        result.lines = Self.lines(Array(repeating: .ok, count: 7) + [.skipped], ms: 47)
        #expect(OpeningCheck.words(result) == "Opening check: all 7 passed (under 0.1 s)")
    }

    @Test func eachFailureIsNamedInOrder() {
        var result = Self.allOK
        result.lines[2].state = .failed
        result.lines[0].state = .failed
        #expect(result.failed == ["daily", "search"])
        #expect(OpeningCheck.words(result) == "Opening check: the daily library and search failed")
        result.lines[5].state = .failed
        #expect(OpeningCheck.words(result) == "Opening check: the daily library, search and free space failed")
        result.lines[5].state = .late
        #expect(OpeningCheck.words(result)
                == "Opening check: the daily library and search failed; free space took too long")
    }

    @Test func aStoppedOpeningSaysSo() {
        let result = OpeningCheck.Result(build: "250", lines: [], stopped: true)
        #expect(OpeningCheck.words(result)
                == "Opening check: the last one stopped before it finished, so none ran this time")
    }

    @Test func aProbeNotBackByTheCapIsLateThenFinishes() async {
        let whole = Whole()
        // The slow probe waits for the test to release it, not for a clock, so only the cap decides when it is late.
        // The cap is long so a busy machine still gets the quick probe back first.
        let (gate, release) = AsyncStream<Void>.makeStream()
        let held = OpeningCheck.Probe(kind: "search") {
            for await _ in gate { break }
            return .ok
        }
        let capped = await OpeningCheck.run([Self.probe("daily"), held], build: "250", cap: .seconds(2)) { whole.set($0) }
        #expect(capped.lines.map(\.state) == [.ok, .late])
        #expect(capped.lines[1].ms == 2000)
        release.yield()
        let finished = await whole.wait()
        #expect(finished.lines.map(\.state) == [.ok, .ok])
        #expect(finished.lines[1].ms >= 2000)
    }

    @Test func everyProbeBackBeforeTheCapReturnsAtOnce() async {
        let whole = Whole()
        let clock = ContinuousClock()
        let start = clock.now
        let capped = await OpeningCheck.run([Self.probe("daily"), Self.probe("files", .failed)], build: "250",
                                            cap: .seconds(5)) { whole.set($0) }
        #expect(clock.now - start < .seconds(2))
        #expect(capped.lines.map(\.state) == [.ok, .failed])
        #expect(await whole.wait() == capped)
    }

    @Test func aProbeOverTheLimitIsAbandonedAsLate() async {
        let whole = Whole()
        _ = await OpeningCheck.run([Self.probe("daily"), Self.probe("search", after: .seconds(30))], build: "250",
                                   cap: .milliseconds(20), limit: .milliseconds(200)) { whole.set($0) }
        let finished = await whole.wait()
        #expect(finished.lines.map(\.state) == [.ok, .late])
        #expect(finished.lines[1].ms == 200)
    }

    @Test func aThrowingProbeIsFailed() async {
        struct Broke: Error {}
        let whole = Whole()
        let capped = await OpeningCheck.run([OpeningCheck.Probe(kind: "inventory") { throw Broke() }], build: "250",
                                            cap: .seconds(1)) { whole.set($0) }
        #expect(capped.lines.map(\.state) == [.failed])
    }

    @Test func theTallyAddsUp() {
        var tally = OpeningCheck.Tally()
        var failing = Self.allOK
        failing.lines[0].state = .failed
        failing.lines[4].state = .late
        failing.lines[3].ms = 900
        tally.add(Self.allOK)
        tally.add(failing)
        tally.add(failing)
        tally.add(OpeningCheck.Result(build: "250", lines: [], stopped: true))
        #expect(tally == OpeningCheck.Tally(openings: 4, failed: ["daily": 2], late: ["documents": 2], stopped: 1,
                                            slowestMs: 900))
    }

    // MARK: Phase 4: Apple's crash and hang counts (counts only, decision 4a)

    @Test func crashAndHangCountsAddToTheTally() {
        var tally = OpeningCheck.Tally(openings: 2)
        #expect(tally.crashes == nil && tally.hangs == nil, "nil until a report comes")
        tally.add(crashes: 0, hangs: 0)
        #expect(tally.crashes == 0 && tally.hangs == 0, "a report with none is a number, not nil")
        tally.add(crashes: 2, hangs: 1)
        tally.add(crashes: 1, hangs: 0)
        #expect(tally == OpeningCheck.Tally(openings: 2, crashes: 3, hangs: 1))
        tally.add(crashes: -5, hangs: 999_999_999)  // never below zero, never past what the Mac takes
        #expect(tally.crashes == 3 && tally.hangs == 999_999)
        #expect(OpeningCheck.Report(last: Self.allOK, tally: tally).isPlain)
    }

    @Test func aCrashBeforeAnyCheckMakesAReportThatShowsNothing() {
        let made = OpeningCheck.diagnosed(nil, build: "250", crashes: 1, hangs: 2)
        #expect(made.tally == OpeningCheck.Tally(crashes: 1, hangs: 2))
        #expect(made.last.build == "250" && !made.last.ran, "no check ran, so This install shows no line")
        #expect(made.isPlain, "the Mac takes it")
        #expect(OpeningCheck.macLine(name: "phone 1", made) == nil)
        #expect(made.tally.hasCounts && !OpeningCheck.Tally().hasCounts)
        #expect(!OpeningCheck.Tally(crashes: 0, hangs: 0).hasCounts)
        let kept = OpeningCheck.Report(last: Self.allOK, tally: .init(openings: 3))
        let added = OpeningCheck.diagnosed(kept, build: "251", crashes: 0, hangs: 1)
        #expect(added.last == Self.allOK, "the last result stays as it was")
        #expect(added.tally == OpeningCheck.Tally(openings: 3, crashes: 0, hangs: 1))
    }

    @Test func onlyWhatCameSinceTheMacTookItIsLeft() {
        let sent = OpeningCheck.Tally(openings: 2, slowestMs: 300, crashes: 1, hangs: nil)
        #expect(sent.left(after: sent) == OpeningCheck.Tally(), "nothing came since: an empty tally")
        var now = sent
        now.add(crashes: 2, hangs: 0)  // Apple's report landed while the room report was on its way
        #expect(now.left(after: sent) == OpeningCheck.Tally(crashes: 2, hangs: 0), "the openings aren't sent twice")
        now.add(Self.allOK)  // an opening since: the whole tally goes again, as before phase 4
        #expect(now.left(after: sent) == nil)
    }

    @Test func isPlainRefusesAnUnknownKindANegativeCountAndAnOddBuild() {
        let plain = OpeningCheck.Report(last: Self.allOK, tally: .init(openings: 1, slowestMs: 100))
        #expect(plain.isPlain)
        var odd = [plain, plain, plain, plain, plain, plain, plain]
        odd[0].last.lines[0].kind = "a typed name"
        odd[1].tally.failed = ["Mike's guide": 1]
        odd[2].tally.openings = -1
        odd[3].last.build = "25<0"
        odd[4].last.lines[1].ms = 1_000_000
        odd[5].tally.crashes = -2
        odd[6].last.build = ""
        for report in odd { #expect(!report.isPlain) }
    }

    @Test func macLineIsNilWhenNothingFailed() {
        #expect(OpeningCheck.macLine(name: "phone 1", nil) == nil)
        let plain = OpeningCheck.Report(last: Self.allOK, tally: .init(openings: 1))
        #expect(OpeningCheck.macLine(name: "phone 1", plain) == nil)
        var failing = plain
        failing.last.lines[1].state = .failed
        #expect(OpeningCheck.macLine(name: "phone 1", failing)
                == "phone 1's opening check: a library file failed (build 2026.1114.1701). Its Downloads › This "
                + "install says the same.")
        failing.last = OpeningCheck.Result(build: "250", lines: [], stopped: true)
        #expect(OpeningCheck.macLine(name: "phone 1", failing)
                == "phone 1's opening check: the last one stopped before it finished, so none ran this time "
                + "(build 250). Its Downloads › This install says the same.")
    }

    // MARK: Task 1.3: the room report carries it

    @Test func theRoomReportCarriesTheOpeningCheck() throws {
        let opening = OpeningCheck.Report(last: Self.allOK, tally: .init(openings: 3, slowestMs: 400))
        let report = PhoneStorage(free: 1, capacity: 2, held: [], waiting: [], cantUpdate: [], build: "250",
                                  opening: opening)
        #expect(try PhoneStorage.read(JSONEncoder().encode(report)) == report)
        #expect(PhoneStorage.readAll(try JSONEncoder().encode(["phone 1": report]))["phone 1"]?.opening == opening)
    }

    @Test func anOpeningPartTheMacCannotReadIsDroppedAndTheRestKept() throws {
        let update = UpdateCheck.Result(from: "249", dropped: [], before: ["pins": 1], now: ["pins": 1])
        let good = PhoneStorage(free: 7, capacity: 9, held: ["a.zim"], waiting: [], cantUpdate: [], build: "250",
                                update: update,
                                opening: .init(last: Self.allOK, tally: .init(openings: 1)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let sent = String(decoding: try encoder.encode(good), as: UTF8.self)
        var without = good
        without.opening = nil
        let plain = String(decoding: try encoder.encode(without), as: UTF8.self)
        // a kind or state from a newer build, a negative count, an opening part of another shape
        let odd = [sent.replacingOccurrences(of: #""kind":"daily""#, with: #""kind":"a newer check""#),
                   sent.replacingOccurrences(of: #""state":"ok""#, with: #""state":"wobbly""#),
                   sent.replacingOccurrences(of: #""openings":1"#, with: #""openings":-1"#),
                   "{" + #""opening":{"something":"else"},"# + plain.dropFirst()]
        for report in odd {
            #expect(report != sent)
            let taken = try PhoneStorage.read(Data(report.utf8))
            #expect(taken.opening == nil)
            #expect(taken.free == 7 && taken.build == "250" && taken.update == update && taken.held == ["a.zim"])
        }
    }

    @Test func anOlderPhonesReportWithNoOpeningPartStillReads() throws {
        let older = #"{"free":5,"capacity":6,"held":[],"waiting":[],"cant_update":[],"build":"249"}"#
        let taken = try PhoneStorage.read(Data(older.utf8))
        #expect(taken.opening == nil && taken.free == 5 && taken.build == "249")
        // and what is still refused stays refused: a negative size
        #expect(throws: PhoneStorage.Problem.self) {
            try PhoneStorage.read(Data(#"{"free":-5,"capacity":6,"held":[],"waiting":[],"cant_update":[]}"#.utf8))
        }
    }
}

/// The whole result, handed over once every probe is back or abandoned
private final class Whole: @unchecked Sendable {
    private let lock = NSLock()
    private var result: OpeningCheck.Result?
    private var waiter: CheckedContinuation<OpeningCheck.Result, Never>?

    func set(_ found: OpeningCheck.Result) {
        lock.lock()
        defer { lock.unlock() }
        if let waiter { waiter.resume(returning: found) } else { result = found }
        waiter = nil
    }

    func wait() async -> OpeningCheck.Result {
        await withCheckedContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            if let result { continuation.resume(returning: result) } else { waiter = continuation }
        }
    }
}
