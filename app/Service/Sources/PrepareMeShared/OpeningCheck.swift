import Foundation

/// The opening self-check (owner, by click, 2026-11-14: docs/plans/2026-11-14-opening-self-check.md). At each fresh
/// opening a phone or iPad runs quick probes of its library, search, lists and documents together; it warns and never
/// locks. Only fixed kinds, states, counts, milliseconds and a build number are kept or sent to the Mac (in the room
/// report, `PhoneStorage.opening`), never a name, a search word or a title. The probes that touch the device are the
/// app's (`OpeningSelfCheck`); this is the logic, the words and the sent form.
public enum OpeningCheck {
    /// Every kind, in the order the words name them; `deep` (the slow fingerprint check) is skipped until phase 3
    public static let kinds = ["daily", "files", "search", "inventory", "documents", "room", "clock", "deep"]
    public static let cap: Duration = .seconds(1)  // decision 1a: phase 3's wait; nothing waits on it before then
    public static let limit: Duration = .seconds(10)  // a probe still running then is abandoned as late
    static let names = [
        "daily": "the daily library", "files": "a library file", "search": "search", "inventory": "the inventory copy",
        "documents": "Essential Documents", "room": "free space", "clock": "the date and time",
        "deep": "a library file's contents",
    ]
    static let most = 1_000_000  // counts and milliseconds sent stay under it

    public enum State: String, Codable, Sendable { case ok, failed, skipped, late }

    public struct Line: Codable, Equatable, Sendable {
        public var kind: String
        public var state: State
        public var ms: Int

        public init(kind: String, state: State, ms: Int) {
            self.kind = kind
            self.state = state
            self.ms = ms
        }
    }

    /// One opening's result. `stopped`: the opening before it began its checks and never finished them, so this one
    /// ran none (a check that crashes the app must never do it at every opening).
    public struct Result: Codable, Equatable, Sendable {
        public var build: String
        public var lines: [Line]
        public var stopped: Bool

        public init(build: String, lines: [Line], stopped: Bool) {
            self.build = build
            self.lines = lines
            self.stopped = stopped
        }

        public var failed: [String] { kinds(.failed) }
        var late: [String] { kinds(.late) }
        /// Whether there is anything to show: a check that ran, or a stop. A phone with nothing to check shows nothing.
        public var ran: Bool { stopped || lines.contains { $0.state != .skipped } }
        var slowestMs: Int { lines.map(\.ms).max() ?? 0 }
        /// A check failed or ran past the limit, or the last opening's checks stopped: shown in the caution color
        public var foundProblem: Bool { stopped || !failed.isEmpty || !late.isEmpty }

        private func kinds(_ state: State) -> [String] {
            OpeningCheck.kinds.filter { kind in lines.contains { $0.kind == kind && $0.state == state } }
        }
    }

    /// Since the last report the Mac took: counts only. `crashes` and `hangs` are Apple's (phase 4), nil until a
    /// diagnostic report comes.
    public struct Tally: Codable, Equatable, Sendable {
        public var openings: Int
        public var failed: [String: Int]
        public var late: [String: Int]
        public var stopped: Int
        public var slowestMs: Int
        public var crashes: Int?
        public var hangs: Int?

        public init(openings: Int = 0, failed: [String: Int] = [:], late: [String: Int] = [:], stopped: Int = 0,
                    slowestMs: Int = 0, crashes: Int? = nil, hangs: Int? = nil) {
            self.openings = openings
            self.failed = failed
            self.late = late
            self.stopped = stopped
            self.slowestMs = slowestMs
            self.crashes = crashes
            self.hangs = hangs
        }

        public mutating func add(_ result: Result) {
            openings += 1
            for kind in result.failed { failed[kind, default: 0] += 1 }
            for kind in result.late { late[kind, default: 0] += 1 }
            if result.stopped { stopped += 1 }
            slowestMs = max(slowestMs, result.slowestMs)
        }

        /// Phase 4: one delivery of Apple's diagnostic reports, as counts only (decision 4a). A delivery with none
        /// makes nil a 0; never below 0 or past what `isPlain` takes, so a crash loop can't get the part refused.
        public mutating func add(crashes found: Int, hangs stuck: Int) {
            crashes = min((crashes ?? 0) + max(found, 0), most - 1)
            hangs = min((hangs ?? 0) + max(stuck, 0), most - 1)
        }

        /// What stays on the device once the Mac took `sent`: Apple's counts that came since (a report often lands
        /// at launch, while the room report is on its way), or nil when an opening came since, and the whole tally
        /// goes again (counted twice at worst; the record is for trends)
        public func left(after sent: Tally) -> Tally? {
            var same = self
            same.crashes = sent.crashes
            same.hangs = sent.hangs
            guard same == sent else { return nil }
            func since(_ now: Int?, _ then: Int?) -> Int? { now == then ? nil : max((now ?? 0) - (then ?? 0), 0) }
            return Tally(crashes: since(crashes, sent.crashes), hangs: since(hangs, sent.hangs))
        }

        /// Anything worth a line in the Mac's record: an opening, a crash or a hang
        public var hasCounts: Bool { openings > 0 || (crashes ?? 0) > 0 || (hangs ?? 0) > 0 }
    }

    /// Phase 4: Apple's counts added to the report kept on the device. Before any check has run there is none, so one
    /// is made whose `last` ran nothing (nothing shows on This install or the Mac's lines) under this install's build.
    public static func diagnosed(_ report: Report?, build: String, crashes: Int, hangs: Int) -> Report {
        var report = report ?? Report(last: Result(build: build, lines: [], stopped: false), tally: Tally())
        report.tally.add(crashes: crashes, hangs: hangs)
        return report
    }

    /// What the room report carries: the last opening's result and the tally since the Mac last took one
    public struct Report: Codable, Equatable, Sendable {
        public var last: Result
        public var tally: Tally

        public init(last: Result, tally: Tally) {
            self.last = last
            self.tally = tally
        }

        /// What the Mac takes: only `kinds`, counts and milliseconds from 0 to under a million, and a build of 1 to 32
        /// digits and dots (the rule `PhoneStorage.read` uses for its own build)
        public var isPlain: Bool {
            let counts = last.lines.map(\.ms) + Array(tally.failed.values) + Array(tally.late.values)
                + [tally.openings, tally.stopped, tally.slowestMs, tally.crashes ?? 0, tally.hangs ?? 0]
            let named = last.lines.map(\.kind) + Array(tally.failed.keys) + Array(tally.late.keys)
            return (1...32).contains(last.build.count)
                && last.build.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
                && Set(named).isSubset(of: kinds) && counts.allSatisfy { (0..<most).contains($0) }
        }
    }

    public struct Probe: Sendable {
        public let kind: String
        public let run: @Sendable () async throws -> State

        public init(kind: String, run: @escaping @Sendable () async throws -> State) {
            self.kind = kind
            self.run = run
        }
    }

    private enum Event: Sendable { case done(Int, Line), cap, limit }

    /// Runs the probes together. Returns the result as it stood at `cap` (unfinished ones `late`), or at once when
    /// every probe is back sooner; `finished` gets the whole result once every probe is back or abandoned at `limit`.
    /// A probe that throws is `failed`. Nothing here waits on an abandoned probe: it runs on unheard.
    public static func run(_ probes: [Probe], build: String, cap: Duration, limit: Duration = limit,
                           finished: @escaping @Sendable (Result) -> Void) async -> Result {
        await withCheckedContinuation { (capped: CheckedContinuation<Result, Never>) in
            let (events, send) = AsyncStream.makeStream(of: Event.self)
            let clock = ContinuousClock()
            for (place, probe) in probes.enumerated() {
                Task.detached(priority: .utility) {
                    let start = clock.now
                    let state = (try? await probe.run()) ?? .failed
                    send.yield(.done(place, Line(kind: probe.kind, state: state, ms: ms(clock.now - start))))
                }
            }
            let timers = [(cap, Event.cap), (limit, Event.limit)].map { wait, event in
                Task {
                    try? await Task.sleep(for: wait)
                    send.yield(event)
                }
            }
            Task.detached(priority: .utility) {
                var lines = [Line?](repeating: nil, count: probes.count)
                func result(lateMs: Int) -> Result {
                    Result(build: build, lines: lines.enumerated().map { place, line in
                        line ?? Line(kind: probes[place].kind, state: .late, ms: lateMs)
                    }, stopped: false)
                }
                var answered = false
                func answer() {
                    if !answered { capped.resume(returning: result(lateMs: ms(cap))) }
                    answered = true
                }
                loop: for await event in events {
                    switch event {
                    case let .done(place, line):
                        lines[place] = line
                        if !lines.contains(nil) { break loop }
                    case .cap: answer()
                    case .limit: break loop
                    }
                }
                answer()
                for timer in timers { timer.cancel() }
                send.finish()
                finished(result(lateMs: ms(limit)))
            }
        }
    }

    static func ms(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }

    private static func listed(_ kinds: [String]) -> String {
        let named = kinds.map { names[$0] ?? $0 }
        return named.count < 2 ? named.joined() : named.dropLast().joined(separator: ", ") + " and " + named.last!
    }

    /// What the check found, in a few words: "all 7 passed (0.4 s)", or what failed or ran long
    public static func summary(_ result: Result) -> String {
        if result.stopped { return "the last one stopped before it finished, so none ran this time" }
        var parts: [String] = []
        if !result.failed.isEmpty { parts.append("\(listed(result.failed)) failed") }
        if !result.late.isEmpty { parts.append("\(listed(result.late)) took too long") }
        if !parts.isEmpty { return parts.joined(separator: "; ") }
        let passed = result.lines.filter { $0.state == .ok }.count
        let time = result.slowestMs < 100 ? "under 0.1" : String(format: "%.1f", Double(result.slowestMs) / 1000)
        return "all \(passed) passed (\(time) s)"
    }

    /// Home Mac › This install's line
    public static func words(_ result: Result) -> String { "Opening check: \(summary(result))" }

    /// The Mac's amber line for a device whose last opening found a problem; nil when nothing failed, ran long or
    /// stopped
    public static func macLine(name: String, _ report: Report?) -> String? {
        guard let last = report?.last, last.foundProblem else { return nil }
        return "\(name)'s opening check: \(summary(last)) (build \(last.build)). "
            + "Its Downloads › This install says the same."
    }
}
