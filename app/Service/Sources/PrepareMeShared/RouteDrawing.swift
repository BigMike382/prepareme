import Foundation

/// Drawing a route on the Mac's street map (remaining-findings plan, Task 11.7; F30; owner, 2026-10-18, by click: ask
/// before losing points). The route joins the clicks with straight lines, so the hint asks for a click at every bend;
/// Cancel (or Escape) throws a short route away at once and asks first past `askAbove` points.
public enum RouteDrawing {
    public static let askAbove = 5

    public static func cancelAsks(points: Int) -> Bool { points > askAbove }

    public static func hint(points: Int) -> String {
        points == 0
            ? "Click where the route starts, then at every bend in the road: the route joins your clicks with straight lines."
            : "\(points) points. Click at every bend, then Finish route."
    }

    public static func discardTitle(points: Int) -> String { "Throw away this route's \(points) points?" }
    public static let discard = "Throw away"
    public static let keepDrawing = "Keep drawing"
}
