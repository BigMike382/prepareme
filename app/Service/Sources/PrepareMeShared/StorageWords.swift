import Foundation

/// A size as a person reads it (remaining-findings plan, Task 8.3; F13; phase L, finding 8, owner 2026-10-20, by
/// click: one decimal and KB, as phase B's words had them): under 1 MB in whole KB ("61 KB"), under 1 GB in whole MB
/// ("850 MB"), else GB with one decimal ("2.4 GB"), with no "about", in the same 1000-based units as the system's own
/// figures. Every size on the phones and the Mac goes through here. Never "160.94 GB", and never "about 1 MB" for a
/// 61 KB file.
public enum StorageWords {
    public enum Rounding: Sendable { case nearest, up, down }

    /// The unit is picked by the rounded figure, so 999.6 MB reads "1.0 GB", never "1000 MB"; a file of a few bytes
    /// reads "1 KB", never nothing.
    public static func size(_ bytes: Int64, rounding: Rounding = .nearest) -> String {
        let bytes = max(bytes, 0)
        func scaled(_ unit: Int64) -> Int64 {
            switch rounding {
            case .nearest: (bytes + unit / 2) / unit
            case .up: (bytes + unit - 1) / unit
            case .down: bytes / unit
            }
        }
        let kb = rounding == .nearest && bytes > 0 ? max(1, scaled(1_000)) : scaled(1_000)
        if kb < 1_000 { return "\(kb) KB" }
        let mb = scaled(1_000_000)
        if mb < 1_000 { return "\(mb) MB" }
        let tenths = scaled(100_000_000)
        return "\(grouped(tenths / 10)).\(tenths % 10) GB"
    }

    /// A refusal's two sizes, never the same words (finding 8: "needs about 2 GB… has about 2 GB"): what is needed
    /// rounded up and what is free rounded down, so needing more than is free always reads as more.
    public static func room(need: Int64, free: Int64) -> (need: String, free: String) {
        (size(need, rounding: .up), size(free, rounding: .down))
    }

    /// A device's room, in one line (beta run 2, B2-10; R4.3): what is free, what the maps that come by themselves leave
    /// free (family downloads plan, phase 4: a Download may go under it, so it isn't "for photos and apps"), and what
    /// that means for maps. Free below the reserve says no more maps come until there's room
    /// (it used to say the device "keeps" more than it has); with room, maps still come in order. The Mac's Phones list
    /// reads the same, with `showCapacity` adding the device's whole size ("Free: 75.7 GB of 994.5 GB.").
    public static func roomLine(free: Int64, capacity: Int64, showCapacity: Bool = false) -> String {
        let reserve = LibraryPlan.reserve(capacity: capacity)
        let of = showCapacity ? " of \(size(capacity))" : ""
        let head = "Free: \(size(free))\(of). Maps that come by themselves leave \(size(reserve)) free"
        return free < reserve ? head + ", so no more come until there's room."
            : head + "; they come in order while there is room."
    }

    /// An add refused at the floor (family downloads plan, phase 4, decision 1): `floor` rounded up
    public static func floorRefusal(floor: Int64) -> String {
        "Not enough room: " + floorReason(floor: floor).prefix(1).lowercased() + floorReason(floor: floor).dropFirst()
    }

    /// The same under an alert already titled "Not enough room"
    public static func floorReason(floor: Int64) -> String {
        "This would leave less than \(size(floor, rounding: .up)) free, which the library needs to update."
    }

    /// The question before an add that leaves under the 10 GB line: what it leaves, rounded down
    public static func leaves(_ left: Int64, device: String = "phone") -> String {
        "It leaves \(size(left, rounding: .down)) free on this \(device)."
    }

    /// The Mac's space bar for one phone (owner, 2026-11-14, by click: "three parts and a line"): the phone's own
    /// photos and apps, PrepareMe's files and what's free, with the line marking what PrepareMe leaves free. PrepareMe's
    /// part is the Mac's sizes for the files the phone says it holds, so it is clamped to what isn't free.
    public struct RoomBar: Equatable, Sendable {
        public let capacity: Int64, other: Int64, prepareMe: Int64, free: Int64, reserve: Int64

        public init(free: Int64, capacity: Int64, prepareMe: Int64) {
            self.capacity = max(capacity, 0)
            self.free = min(max(free, 0), self.capacity)
            self.prepareMe = min(max(prepareMe, 0), self.capacity - self.free)
            other = self.capacity - self.free - self.prepareMe
            reserve = min(LibraryPlan.reserve(capacity: capacity), self.capacity)
        }

        /// Free space under the line: no more maps come until there's room (the same rule as `roomLine`)
        public var short: Bool { free < LibraryPlan.reserve(capacity: capacity) }
        public var otherWords: String { size(other) }
        public var prepareMeWords: String { size(prepareMe) }
        public var freeWords: String { "\(size(free)) of \(size(capacity))" }
        public var reserveWords: String { "Maps that come by themselves leave \(size(LibraryPlan.reserve(capacity: capacity))) free" }
        public var mapsWords: String {
            short ? "No more maps come until there's room." : "Maps come in order while there is room."
        }

        /// What VoiceOver reads for the bar
        public var spoken: String {
            "\(size(free)) free of \(size(capacity)). PrepareMe uses \(size(prepareMe)), photos and apps \(size(other)). "
                + mapsWords
        }
    }

    /// Whole gigabytes with their thousands marked: "1,498".
    static func grouped(_ number: Int64) -> String {
        let digits = Array(String(number))
        return digits.enumerated().map { index, digit in
            index > 0 && (digits.count - index) % 3 == 0 ? ",\(digit)" : "\(digit)"
        }.joined()
    }
}
