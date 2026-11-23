import Foundation

/// Maps' two sides: Find a map (the topo files' own page) and the street map.
public enum MapsSide: String, Sendable {
    case find, street
}

/// Which side Maps opens on (beta run 2, B2-22; owner, 2026-10-20, choice a): a child's phone opens on the street map,
/// where the rally point is; an adult's on Find a map (phase L). A side someone picked is kept. A phone not yet known
/// as an adult's counts as a child's (`PhoneInventoryModel.isChild` fails closed), so it too opens on the street map.
public enum MapsFirstSide {
    public static func pane(stored: String?, isChild: Bool) -> MapsSide {
        stored.flatMap(MapsSide.init(rawValue:)) ?? (isChild ? .street : .find)
    }

    /// Where re-tapping Maps (or its Back to Find a map) goes: a child's street map, an adult's Find a map.
    public static func retap(isChild: Bool) -> MapsSide { isChild ? .street : .find }
}

/// The street map's round buttons, wrapped (B2-23): which buttons share a row when the room is `available` wide, each
/// `widths[i]` wide with `spacing` between. A button wider than the room still gets a row of its own, never dropped.
/// A row may run `slack` over: the width the measure reports comes back to placement rounded, and a float sum of the
/// widths can come out a hair over, and neither may add a row (R6.2 minor, checkpoint 3); half a point is far less
/// than any button.
public enum ButtonRows {
    public static let slack = 0.5

    public static func split(widths: [Double], spacing: Double, available: Double) -> [[Int]] {
        var rows: [[Int]] = [], used = 0.0
        for (i, width) in widths.enumerated() {
            if var last = rows.last, used + spacing + width <= available + slack {
                last.append(i)
                rows[rows.count - 1] = last
                used += spacing + width
            } else {
                rows.append([i])
                used = width
            }
        }
        return rows
    }
}

/// The street map's rally strip on a narrow phone (beta run 3, S4.1; run 2's B2-23): the strip along the bottom folds
/// to one row (the point's name, its distance and the arrow) so the map above it shows whole, and a tap opens the
/// rest. Folded when the screen is the SE's width or narrower (the phones where the round buttons wrap into a second
/// row, `ButtonRows`) or a phone on its side; wider phones keep the whole strip. The words are here so a test pins
/// them.
public enum StripFold {
    /// The iPhone SE's width in points: the narrowest phone this app runs on (also the 12 and 13 mini's).
    public static let narrowWidth = 375.0
    /// A phone on its side is about 375 high: the whole strip would cover most of the map.
    public static let shortHeight = 500.0

    public static func folded(width: Double, height: Double) -> Bool {
        width <= narrowWidth || height <= shortHeight
    }

    /// The folded row's visible word and the open strip's, beside a chevron.
    public static let more = "More"
    public static let less = "Less"
    /// Read by VoiceOver after the folded row ("Open the rest...") and after the open strip's Less.
    public static let moreHint = "Opens the rest of the box: where you are, the walking time and directions."
    public static let lessHint = "Folds the box to one row so the map shows."
    public static let lessLabel = "Show less of the meeting place box"

    /// What VoiceOver reads for the folded row: the name, then how far and which way when the phone has a fix, and
    /// that the walk ends after dark (a caution the open strip spells out, so the fold never hides it), and the chosen
    /// route's "Off route" line (the W9 review).
    public static func spoken(name: String, brief: String?, afterDark: Bool, offRoute: String? = nil) -> String {
        var parts = [name]
        if let brief { parts.append(brief) }
        if afterDark { parts.append("you would arrive after dark") }
        if let offRoute { parts.append(offRoute) }
        return parts.joined(separator: ", ")
    }
}

/// The side Maps shows, settled the first time Maps is looked at in a launch (fix round 1): the first look resolves it,
/// a child's stored side being ignored then (it lasts only while the app runs), and later answers about who holds the
/// phone never swap it under the person; only a pick (or a page opened in Maps) changes it. The one exception is
/// the role arriving (B3-04): a phone paired before its role was known counts as a child's, so when Maps is opened
/// again (`reopen`, never while it is on screen) and the role now differs from the one the side was settled on, with
/// nothing picked since, the side is settled again on the new role.
public struct MapsSideState: Sendable {
    public private(set) var side: MapsSide?
    private var settledAsChild: Bool?
    private var picked = false

    public init() {}

    public mutating func resolve(stored: String?, isChild: Bool) -> MapsSide {
        if let side { return side }
        let first = MapsFirstSide.pane(stored: isChild ? nil : stored, isChild: isChild)
        side = first
        settledAsChild = isChild
        return first
    }

    public mutating func pick(_ new: MapsSide) {
        side = new
        picked = true
    }

    /// Maps is being opened (the tab was not showing). Settles the side again only if none was picked and the role
    /// has changed since it was settled; true when the side changed.
    @discardableResult
    public mutating func reopen(stored: String?, isChild: Bool) -> Bool {
        guard !picked, let before = side, let settled = settledAsChild, settled != isChild else { return false }
        side = nil
        return resolve(stored: stored, isChild: isChild) != before
    }
}

extension ButtonRows {
    /// The size the wrapped rows take: the widest row by all the rows' heights, `spacing` between rows.
    public static func size(widths: [Double], heights: [Double], spacing: Double, available: Double)
        -> (width: Double, height: Double) {
        var width = 0.0, height = 0.0
        for (n, row) in split(widths: widths, spacing: spacing, available: available).enumerated() {
            width = max(width, row.map { widths[$0] }.reduce(0, +) + spacing * Double(row.count - 1))
            height += (row.map { heights[$0] }.max() ?? 0) + (n > 0 ? spacing : 0)
        }
        return (width, height)
    }
}
