import Foundation
import PrepareMeShared
import Testing

/// The street map pins plan, phase 3 (the Mac): one Add pin, whose naming sheet's Kind picker makes a meeting place or
/// a pin; the Start point only from the Map menu and the list's Printed directions; the list's groups in the plan's
/// order. Reads the Mac's street map screen, as the other screen checks here do.
struct MapPinsMacTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // Tests/PrepareMeSharedTests
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func file(_ name: String) throws -> String {
        try String(contentsOf: repo.appendingPathComponent("app/Kiwix/PrepareMeApp/\(name)"), encoding: .utf8)
    }

    static func part(_ text: String, from start: String, to end: String) -> String {
        guard let a = text.range(of: start), let b = text.range(of: end, range: a.upperBound..<text.endIndex) else {
            Issue.record("\(start) wasn't found")
            return ""
        }
        return String(text[a.lowerBound..<b.lowerBound])
    }

    @Test func oneAddPinAndNoMeetingPlaceMode() throws {
        let mac = try Self.file("PrepareMeStreetMapMac.swift")
        let toolbar = Self.part(mac, from: "case .browse:", to: "case .start, .pin:")
        #expect(toolbar.contains("Label(\"Add pin\""))
        #expect(toolbar.contains("Label(\"Draw route\""))
        #expect(toolbar.contains("Label(\"Print Household Map…\""))
        #expect(!toolbar.contains("Label(\"Add meeting place\""), "the toolbar still has Add meeting place")
        #expect(!toolbar.contains("Set Printed Directions Start"), "the Start point is the Map menu's and the list's")
        #expect(Self.part(mac, from: "enum StreetMapMacMode", to: "}").contains("case browse, start, pin, route"))
        let menu = Self.part(mac, from: "CommandMenu(\"Map\")", to: "\n        }\n")
        let order = ["\"Find Me\"", "\"Pins and Routes\"", "Divider()", "\"Add Pin\"", "\"Draw Route\"",
                     "\"Set Printed Directions Start…\"", "Divider()", "\"Print Household Map…\""]
        var at = menu.startIndex
        for item in order {
            let found = menu.range(of: item, range: at..<menu.endIndex)
            #expect(found != nil, "the Map menu's \(item) is missing or out of order")
            at = found?.upperBound ?? at
        }
        #expect(!menu.contains("Meeting Place"), "the Map menu still adds a meeting place")
    }

    @Test func theRightClickHasOneAddPinHere() throws {
        let screen = try Self.file("PrepareMeStreetMapScreen.swift")
        let details = Self.part(screen, from: "struct StreetMapDetails", to: "\n}\n")
        #expect(details.contains("Button(\"Add pin here\")"))
        #expect(!details.contains("meeting place here"))
        #expect(!details.contains("start here"))
        // as the phone's: a right-click on a pin, meeting place or Start point shows its card alone (phase 4's pass)
        #expect(details.contains("StreetMap.offersAdding("), "a right-click on a pin still offers Add pin here")
    }

    @Test func theNamingSheetsKindPicker() throws {
        let mac = try Self.file("PrepareMeStreetMapMac.swift")
        let sheet = Self.part(mac, from: "private struct MapMarkNaming", to: "\n}\n")
        #expect(sheet.contains("Picker(\"Kind\""))
        #expect(sheet.contains("MapMarkWords.meetingPlace"))
        #expect(sheet.contains("MapMarkWords.makeYourOwn"))
        #expect(!sheet.contains("Use a ready-made pin"), "the old menu is still there beside Kind")
    }

    @Test func theListsGroupsInOrderWithPrintedDirectionsLast() throws {
        let mac = try Self.file("PrepareMeStreetMapMac.swift")
        let list = Self.part(mac, from: "private struct MapMarksList", to: "func row(")
        let order = ["\"Meeting places\"", "\"Routes\"", "\"Pins\"", "MapMarkWords.deletedHeading(", "\"Printed directions\""]
        var at = list.startIndex
        for group in order {
            let found = list.range(of: group, range: at..<list.endIndex)
            #expect(found != nil, "the list's \(group) is missing or out of order")
            at = found?.upperBound ?? at
        }
        #expect(list.contains("Button(\"Set start…\")"), "no Set start… with no Start point")
    }

    /// The owner, 2026-11-15 (through the desk): "Make deleted pins list collapsed by default." Closed, with its count.
    @Test func deletedOnAPhoneStartsFolded() throws {
        let list = Self.part(try Self.file("PrepareMeStreetMapMac.swift"), from: "private struct MapMarksList", to: "func row(")
        #expect(list.contains("@State private var deletedOpen = false"), "the deleted group doesn't start closed")
        #expect(list.contains("DisclosureGroup(isExpanded: $deletedOpen)"), "the deleted group doesn't fold")
        #expect(list.contains("Text(MapMarkWords.deletedHeading(gone.count))"), "the fold doesn't show its count")
        #expect(MapMarkWords.deletedHeading(3) == "Deleted on a phone (3)")
    }
}
