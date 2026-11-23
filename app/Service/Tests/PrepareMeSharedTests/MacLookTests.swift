import Foundation
import PrepareMeShared
import XCTest
#if canImport(AppKit)
import AppKit
#endif

/// The Mac app's look (owner, 2026-10-16): every sidebar group's icon is one this Mac draws (a name SF Symbols doesn't
/// know shows nothing, and the group's words slip back left of "Categories"), a group not in the list gets the folder,
/// and Settings grown taller moves up just far enough to stay on screen.
final class MacLookTests: XCTestCase {
    func testEveryGroupsIconExists() {
        #if canImport(AppKit)
        for (name, symbol) in MacLook.symbols {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), "\(name): \(symbol)")
        }
        XCTAssertNotNil(NSImage(systemSymbolName: MacLook.otherSymbol, accessibilityDescription: nil))
        #endif
    }

    func testAGroupWithoutItsOwnIconGetsTheFolder() {
        XCTAssertEqual(MacLook.symbol("For Adults"), "person")
        XCTAssertEqual(MacLook.symbol("For adults"), "person", "an older library's name still finds its icon")
        XCTAssertEqual(MacLook.symbol("A group added later"), "folder")
        XCTAssertNil(MacLook.emoji("A group added later"))
        XCTAssertNil(MacLook.emoji("Other"))
    }

    /// A4 (owner, 2026-10-18): each group's emoji in the sidebar, the guide list's own (packer/tests/test_build.py pins
    /// the table equal to dashboard/emoji.py's), found by the title-case name and by an older library's sentence case.
    func testEachGroupHasItsEmoji() {
        let wanted = ["Our Home": "🏠", "Water and Food": "💧", "Power, Heat and Fuel": "⚡",
                      "Fire, Storms, Floods": "🌪️", "Medical": "⛑️", "Family and Animals": "👪",
                      "After a Disaster": "🏚️", "Kits and Planning": "🎒", "Radio, Phones, Maps": "📱", "Calculators, Tables": "🔢",
                      "Living Outdoors": "⛺"]
        XCTAssertEqual(MacLook.emoji, wanted)
        for (name, mark) in wanted {
            XCTAssertEqual(MacLook.emoji(name), mark, name)
            XCTAssertEqual(MacLook.emoji(name.lowercased()), mark, "an older library's \(name)")
        }
        XCTAssertEqual(MacLook.emoji("Fire, Storms, Floods")?.unicodeScalars.last, "\u{FE0F}", "drawn as a picture")
        XCTAssertEqual(MacLook.emoji("Our Household"), "🏠", "a library built before Our Home's name (2026-11-16)")
    }

    func testTheSettingsWindowKeepsItsBottomOnScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1728, height: 1080)
        let ranOff = CGRect(x: 400, y: -250, width: 760, height: 760)
        XCTAssertEqual(MacLook.onScreen(ranOff, in: visible), CGPoint(x: 400, y: 0))
        let fits = CGRect(x: 400, y: 100, width: 760, height: 760)
        XCTAssertEqual(MacLook.onScreen(fits, in: visible), CGPoint(x: 400, y: 100))
        let tall = CGRect(x: 400, y: -500, width: 760, height: 1200)
        XCTAssertEqual(MacLook.onScreen(tall, in: visible), CGPoint(x: 400, y: -120))
    }
}
