import Foundation
import Testing
@testable import PrepareMeShared

/// The printed turn lists as the Mac's marks panel reads them (hand-off improvements plan, phase 3), from the lists
/// job's own file (Fixtures/turn-lists.json, pinned by readiness/tests/test_turns.py): made-up marks on made-up roads.
struct TurnListsTests {
    static let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    let newYork = TimeZone(identifier: "America/New_York")!
    // the sample's marks, as test_turns.py made them (WEST and EAST there)
    static let west = [-77.0070, 38.8912], east = [-76.9925, 38.8905]
    let start = MapMark(id: 5, kind: .start, name: "Made-up start", points: [Self.west])
    let rally = MapMark(id: 1, kind: .rally, name: "Made-up rally", points: [Self.east])
    let far = MapMark(id: 3, kind: .rally, name: "Made-up far one", points: [Self.east])

    @Test func eachMarkGetsItsLineInFixedWords() throws {
        let lists = try #require(TurnLists.read(in: Self.sample))
        #expect(lists.line(for: rally, start: start, timeZone: newYork)
                == "Turns made Oct 7, 2:07 PM: 0.8 mi by car, 0.8 mi on foot.")
        #expect(lists.line(for: far, start: start, timeZone: newYork)
                == "Turns made Oct 7, 2:07 PM: 0.8 mi by car. None on foot, "
                + "farther than the router goes for this way of travel.")
        let since = MapMark(id: 9, kind: .rally, name: "Placed since", points: [Self.east])
        #expect(lists.line(for: since, start: start) == TurnLists.notYet, "a mark placed since the last run")
        #expect(lists.start == 5)
    }

    /// Section 38's fault (2026-10-31): a new route showed a rally point's turns. A new mark takes the id of the newest
    /// one deleted, so a list shows only under the mark it was made for, as it was then.
    @Test func aListShowsOnlyUnderTheMarkItWasMadeFor() throws {
        let lists = try #require(TurnLists.read(in: Self.sample))
        let route = MapMark(id: 1, kind: .route, name: "Test wrong", points: [Self.west, Self.east])
        #expect(lists.line(for: route, start: start) == TurnLists.notYet, "a new route on a deleted rally point's id")
        #expect(!lists.namesHome(route, start: start, words: ["Made-up Street"]))
        var moved = rally
        moved.points = [[-76.99, 38.89]]
        #expect(lists.line(for: moved, start: start) == TurnLists.notYet, "a rally point moved since")
        var startMoved = start
        startMoved.points = [[-77.0, 38.89]]
        #expect(lists.line(for: rally, start: startMoved) == TurnLists.notYet, "the Start moved since")
        #expect(lists.line(for: rally, start: nil) == TurnLists.notYet, "the Start deleted since")
        let drawn = MapMark(id: 2, kind: .route, name: "Made-up route", points: [Self.west, Self.east])
        #expect(lists.line(for: drawn, start: nil, timeZone: newYork).hasPrefix("Turns made"),
                "a route's own lists never wait on the Start")
        var older = lists
        older.marks = nil
        #expect(older.line(for: rally, start: start) == TurnLists.notYet, "a file from before: the next run makes it")
    }

    @Test func reasonsAndNoneAtAll() {
        let left = TurnLists(madeAt: "2026-10-30T22:52:00Z", dataDate: nil, start: nil, lists: [],
                             leftOut: [.init(mark: 1, travel: "car", why: "no printed directions start"),
                                       .init(mark: 1, travel: "foot", why: "no printed directions start"),
                                       .init(mark: 2, travel: "car", why: "a"), .init(mark: 2, travel: "foot", why: "b")],
                             whyNone: nil, marks: [.init(mark: 1, kind: "rally", points: [[1, 2]]),
                                                   .init(mark: 2, kind: "route", points: [[1, 2], [3, 4]])])
        let one = MapMark(id: 1, kind: .rally, name: "One", points: [[1, 2]])
        let two = MapMark(id: 2, kind: .route, name: "Two", points: [[1, 2], [3, 4]])
        #expect(left.line(for: one, start: nil) == "No turn lists: no printed directions start.")
        #expect(left.line(for: two, start: nil) == "No turn lists by car, a; on foot, b.")
        let none = TurnLists(madeAt: "", dataDate: nil, start: nil, lists: [], leftOut: [], whyNone: "no routing data")
        #expect(none.line(for: one, start: nil) == "No turn lists: no routing data.")
    }

    @Test func aListThatNamesHomeIsFoundByTheOwnersWords() throws {
        let lists = try #require(TurnLists.read(in: Self.sample))
        #expect(lists.namesHome(rally, start: start, words: ["Made-up Street"]))
        #expect(!lists.namesHome(rally, start: start, words: ["Elm Street"]))
        let since = MapMark(id: 9, kind: .rally, name: "Placed since", points: [Self.east])
        #expect(!lists.namesHome(since, start: start, words: ["Made-up Street"]))
    }
}
