import Foundation

/// The contour lines of look 3's band (plan Task 1.3): a map's hill as closed rings, decoration only, drawn the same
/// every time and never moving. The same numbers as the pages' `packer/contour.py` (`ContourTests`), in a 640 by 500
/// box; the band scales and places them.
public enum Contour {
    public static let width: CGFloat = 640, height: CGFloat = 500

    /// `count` closed rings of `points` points each around the box's middle, each with a slightly different wobble.
    public static func rings(count: Int = 9, points: Int = 36) -> [[CGPoint]] {
        (0..<count).map { k in
            let r = 20 + Double(k) * 20, k = Double(k)
            return (0..<points).map { s in
                let a = Double(s) / Double(points) * 2 * .pi
                let wob = 1 + 0.15 * sin(3 * a + k * 0.5) + 0.08 * sin(5 * a - k * 0.7) + 0.05 * sin(2 * a + 1.3)
                return CGPoint(x: width / 2 + r * wob * cos(a) * 1.2, y: height / 2 + r * wob * sin(a))
            }
        }
    }
}
