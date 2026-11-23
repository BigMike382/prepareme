import Foundation
import MeaningNearest
import Testing

// News's grouping (docs/news.md): prepareme-meaning nearest's search, on made-up unit vectors. No model folder needed.
struct NearestTests {
    /// A unit row of 384 numbers with the given leading values (the rest 0), normalized.
    static func row(_ lead: [Float]) -> [Float] {
        var values = lead + [Float](repeating: 0, count: Nearest.dimensions - lead.count)
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        values = values.map { $0 / norm }
        return values
    }

    static let candidates = [row([1, 0, 0]), row([0.8, 0.6, 0]), row([0, 1, 0]), row([0.6, 0, 0.8])].flatMap { $0 }

    @Test func givesTheKnownOrderAndLikenesses() {
        let found = Nearest.search(queries: Self.row([1, 0, 0]), candidates: Self.candidates, k: 5, floor: -1)
        #expect(found.count == 1)
        #expect(found[0].map(\.0) == [0, 1, 3, 2])
        let expected: [Float] = [1, 0.8, 0.6, 0]
        for (got, want) in zip(found[0].map(\.1), expected) {
            #expect(abs(got - want) < 0.000_01)
        }
    }

    @Test func honorsKAndFloor() {
        let queries = Self.row([1, 0, 0]) + Self.row([0, 1, 0])
        let found = Nearest.search(queries: queries, candidates: Self.candidates, k: 2, floor: 0.7)
        #expect(found[0].map(\.0) == [0, 1])
        #expect(found[1].map(\.0) == [2])  // 0.6 for candidate 1 is under the floor
    }

    @Test func searchesPastOneBlock() {
        var many = [Float]()
        for _ in 0..<(Nearest.block + 3) { many += Self.row([0, 1, 0]) }
        many += Self.row([1, 0, 0])
        let found = Nearest.search(queries: Self.row([1, 0, 0]), candidates: many, k: 1, floor: 0.9)
        #expect(found[0].map(\.0) == [Nearest.block + 3])
    }

    @Test func refusesAShortFile() {
        #expect(throws: Nearest.Problem.notWholeRows) { try Nearest.rows(Data(count: 4 * 383)) }
        let whole = Self.row([1, 0, 0]).withUnsafeBufferPointer { Data(buffer: $0) }
        #expect((try? Nearest.rows(whole))?.count == Nearest.dimensions)
    }
}
