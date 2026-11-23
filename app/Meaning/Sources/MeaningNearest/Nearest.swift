// News's grouping (docs/news.md, "Grouping"): each query row's best matches among the candidate rows, by likeness (the
// dot product of unit-length rows), with Apple's own math library. Kept apart from MeaningSearch so the apps, which
// use MeaningSearch, are unchanged by it; only prepareme-meaning's `nearest` command uses it.
import Accelerate
import Foundation

public enum Nearest {
    public static let dimensions = 384
    public static let block = 4096  // candidate rows multiplied at once

    public enum Problem: Error, Equatable {
        case notWholeRows  // a file's length isn't a whole number of rows of 384 numbers
    }

    /// Little-endian float32 rows from a file's bytes; `notWholeRows` unless its length is a multiple of 384 numbers.
    public static func rows(_ data: Data) throws -> [Float] {
        guard data.count % (4 * dimensions) == 0 else { throw Problem.notWholeRows }
        return data.withUnsafeBytes { raw in
            (0..<data.count / 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
    }

    /// For each query row, up to `k` (candidate index, likeness) pairs at or above `floor`, best first (ties: the lower
    /// index first).
    public static func search(queries: [Float], candidates: [Float], k: Int, floor: Float) -> [[(Int, Float)]] {
        let d = dimensions
        let q = queries.count / d, c = candidates.count / d
        var best = [[(Int, Float)]](repeating: [], count: q)
        guard q > 0, c > 0, k > 0 else { return best }
        var scores = [Float](repeating: 0, count: q * min(block, c))
        var start = 0
        while start < c {
            let n = min(block, c - start)
            queries.withUnsafeBufferPointer { qp in
                candidates.withUnsafeBufferPointer { cp in
                    scores.withUnsafeMutableBufferPointer { sp in
                        // scores (q × n) = queries (q × d) · candidates[start..<start+n]ᵀ (d × n)
                        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(q), Int32(n), Int32(d), 1,
                                    qp.baseAddress, Int32(d), cp.baseAddress! + start * d, Int32(d), 0,
                                    sp.baseAddress, Int32(n))
                    }
                }
            }
            for row in 0..<q {
                for col in 0..<n where scores[row * n + col] >= floor {
                    best[row].append((start + col, scores[row * n + col]))
                }
                if best[row].count > k {
                    best[row].sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
                    best[row].removeLast(best[row].count - k)
                }
            }
            start += n
        }
        return best.map { Array($0.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(k)) }
    }
}
