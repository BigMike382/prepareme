import Foundation
import PrepareMeShared
import Testing

/// Look 3's contour lines on native screens (plan Task 1.3): the same rings as the pages' `packer.contour.rings`.
struct ContourTests {
    @Test func nineRingsOfThirtySixPointsInsideTheBox() {
        let rings = Contour.rings()
        #expect(rings.count == 9)
        #expect(rings.allSatisfy { $0.count == 36 })
        #expect(rings.joined().allSatisfy { (0...Contour.width).contains($0.x) && (0...Contour.height).contains($0.y) })
        #expect(rings == Contour.rings(), "the same every time")
    }

    /// The numbers written in from Python's output: `rings()[0][0]` (345.156, 250.0) and `rings()[8][9]`
    /// (320.0, 450.145), so the pages' lines and the app's are one drawing.
    @Test func theSameNumbersAsThePages() {
        let rings = Contour.rings()
        #expect(abs(rings[0][0].x - 345.156) < 0.05 && abs(rings[0][0].y - 250.0) < 0.05)
        #expect(abs(rings[8][9].x - 320.0) < 0.05 && abs(rings[8][9].y - 450.145) < 0.05)
    }
}
