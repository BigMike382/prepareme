import Foundation
import Testing

/// The map pins plan's phase 4 pass (2026-11-15) found two things hard to read on the phone's street map: at the
/// accessibility text sizes the tap card's name and lines filled the half-height card, leaving Drive and Walk below
/// the fold, and the child's grayed "I'm lost" kept the panel's color on the system's gray, all but invisible.
/// Reads the screens, as the other screen checks here do; the captures measured the grayed words at over 4.5:1 in light and dark.
struct MapReadabilityTests {
    @Test func tapCardOpensFullHeightAtTheAccessibilitySizes() throws {
        let screen = try MapPinsMacTests.file("PrepareMeStreetMapScreen.swift")
        let sheet = MapPinsMacTests.part(screen, from: ".sheet(item: $model.tapped)", to: ".task(id: model.oldPins)")
        #expect(sheet.contains(".tapCardHeight(tall: textSize.isAccessibilitySize)"))
        let height = MapPinsMacTests.part(screen, from: "func tapCardHeight(tall: Bool)", to: "\n    }\n")
        #expect(height.contains("if tall { presentationDetents([.large]).presentationSizing(.page) }"),
                "the tap card keeps the half height, or the iPad's small sheet, at the accessibility sizes")
        #expect(height.contains("else { presentationDetents([.medium]) }"), "the default size's card changed")
    }

    @Test func grayedFilledButtonKeepsReadableWords() throws {
        let colors = try MapPinsMacTests.file("PrepareMeColors.swift")
        let look = MapPinsMacTests.part(colors, from: "struct PMProminentLook", to: "\n}\n")
        #expect(look.contains("@Environment(\\.isEnabled)"))
        #expect(look.contains("foregroundStyle(enabled ? PrepareMeColors.panel : PrepareMeColors.ink)"),
                "a grayed filled button's words aren't ink")
        #expect(colors.contains("func pmProminent() -> some View { modifier(PMProminentLook()) }"))
        let map = try MapPinsMacTests.file("PrepareMeStreetMap.swift")
        #expect(MapPinsMacTests.part(map, from: "private var lostButton", to: "private var page")
            .contains(".pmProminent()\n        .disabled(model.here == nil)"))
    }

    /// At the accessibility sizes the meeting place filled the child's first screen and I'm lost sat below the fold
    /// (owner, 2026-11-15: "fix the child screen so I'm lost shows unscrolled"): there it sits in the bottom bar; at
    /// the other sizes it stays in the page, under the meeting place.
    @Test func lostStaysOnScreenAtTheAccessibilitySizes() throws {
        let map = try MapPinsMacTests.file("PrepareMeStreetMap.swift")
        let simple = MapPinsMacTests.part(map, from: "struct StreetMapSimpleView", to: "private var lostSheet")
        #expect(simple.contains("if textSize.isAccessibilitySize {\n                page.pmBar(.bottom) { lostButton"))
        #expect(simple.contains("if !textSize.isAccessibilitySize { lostButton }"), "the default size lost its button")
        #expect(simple.components(separatedBy: "lostButton").count - 1 == 3, "I'm lost shown other than twice")
    }
}
