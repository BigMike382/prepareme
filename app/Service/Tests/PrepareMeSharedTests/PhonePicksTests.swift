import Foundation
import PrepareMeShared
import Testing

/// The phone's item form: its two switches, Manual and Holds unit as picks, never typed (inventory fresh look, Task
/// 2.3; spec 5.3, 5.4).
struct PhonePicksTests {
    static let six = Inventory.Label.holdsUnits

    @Test func theTwoSwitches() {
        #expect(PhoneEditRules.phoneSwitches == [Inventory.Label.emptyUntilNeeded, Inventory.Label.keepPastDate])
        #expect(PhoneEditRules.isSwitch("Empty until needed"))
        #expect(PhoneEditRules.isSwitch(" keep past date "))
        #expect(!PhoneEditRules.isSwitch(Inventory.Label.privateRow), "Private stays Mac only")
        // on as the Mac stores a tick: its shown "Yes", or a refused edit's 1; blank or 0 is off
        #expect(PhoneEditRules.isOn("Yes"))
        #expect(PhoneEditRules.isOn("1"))
        #expect(!PhoneEditRules.isOn(""))
        #expect(!PhoneEditRules.isOn("0"))
    }

    /// Keep past date shows wherever the Mac shows it: always, under Dates, with an expiry date or none (fix wave,
    /// spec 5.3: the same rules everywhere); Empty until needed always too.
    @Test func keepPastDateAlwaysShowsAsOnTheMac() {
        for label in [Inventory.Label.keepPastDate, Inventory.Label.emptyUntilNeeded] {
            #expect(ItemFieldGroup.shows(label, group: "Food", unit: "cans", item: "Soup"))
            #expect(ItemFieldGroup.shows(label, group: nil, unit: "", item: ""))
        }
        #expect(ItemFieldGroup.grouped([Inventory.Label.keepPastDate]).first?.group == .dates)
    }

    /// The what's-missing line goes only while an on-screen keyboard covers the screen's foot (fix round 1): a
    /// hardware keyboard's bar of shortcuts, or a keyboard put away, leaves it showing.
    @Test func onlyAnOnScreenKeyboardHidesTheLine() {
        #expect(!PhoneEditRules.screenKeyboardUp(shownHeight: 0))
        #expect(!PhoneEditRules.screenKeyboardUp(shownHeight: 69), "an iPad's hardware keyboard bar")
        #expect(PhoneEditRules.screenKeyboardUp(shownHeight: 216), "an iPhone's keyboard")
        #expect(PhoneEditRules.screenKeyboardUp(shownHeight: 162), "a number pad held sideways")
    }

    @Test func manualAndHoldsUnitArePicksOnly() {
        #expect(PhoneEditRules.isPickOnly("Manual"))
        #expect(PhoneEditRules.isPickOnly(" holds unit "))
        #expect(!PhoneEditRules.isPickOnly("Unit"))
        #expect(!PhoneEditRules.isPickOnly(Inventory.Label.grab))
        #expect(PhoneEditRules.manualBlank == "Not recorded")
        #expect(PhoneEditRules.hint(columnLabel: "Manual")
                == "Not needed: it needs no manual. None exists: the maker never made one. "
                + "A manual's PDF can only be added on the Mac.")
    }

    @Test func pickChoices() {
        let manual = ["Not recorded", "Not needed", "None exists"]
        #expect(PhoneEditRules.pickChoices("Manual", choices: ["Not needed", "None exists"], stored: "") == manual)
        #expect(PhoneEditRules.pickChoices("Manual", choices: ["", "Not needed", "None exists"], stored: "") == manual)
        #expect(PhoneEditRules.pickChoices("Manual", choices: [], stored: "") == manual, "an older file's column")
        #expect(PhoneEditRules.pickChoices("Manual", choices: ["Not needed", "None exists"], stored: "None exists")
                == manual)
        #expect(PhoneEditRules.pickChoices("Holds unit", choices: Self.six, stored: "") == [""] + Self.six)
        #expect(PhoneEditRules.pickChoices("Holds unit", choices: [], stored: "fl oz") == [""] + Self.six)
        // Holds unit offers its six as the app adds them to the file, never a file's longer list (minor 4)
        #expect(PhoneEditRules.pickChoices("Holds unit", choices: Self.six + ["quarts"], stored: "") == [""] + Self.six)
        // a stored value matching a choice but for case or spaces, or Manual's blank word, adds no near-duplicate (minor 2)
        #expect(PhoneEditRules.pickChoices("Holds unit", choices: Self.six, stored: " Gallons ") == [""] + Self.six)
        #expect(PhoneEditRules.pickChoices("Manual", choices: ["Not needed", "None exists"], stored: "not recorded")
                == manual)
        // review focus 5: a value already off the list is one more choice, so the pick shows it as stored
        #expect(PhoneEditRules.pickChoices("Holds unit", choices: Self.six, stored: "quarts").last == "quarts")
        #expect(PhoneEditRules.pickChoices("Manual", choices: ["Not needed", "None exists"], stored: "PDF on the Mac")
                == manual + ["PDF on the Mac"])
    }

    @Test func pickStored() {
        #expect(PhoneEditRules.pickStored("Manual", shown: "Not recorded") == "")
        #expect(PhoneEditRules.pickStored("Manual", shown: "PDF on the Mac") == "PDF on the Mac")
        #expect(PhoneEditRules.pickStored("Manual", shown: "Not needed") == "Not needed")
        #expect(PhoneEditRules.pickStored("Holds unit", shown: "") == "")
        #expect(PhoneEditRules.pickStored("Holds unit", shown: "gallons") == "gallons")
    }

    /// A stored pick opens as the choice it matches in any case or spacing, so the menu shows it selected (minor 2):
    /// Manual's stored "Not recorded" selects the blank; a value on no list opens as stored.
    @Test func aStoredPickOpensAsItsChoice() {
        #expect(PhoneEditRules.pickShown("Holds unit", stored: " Gallons ", choices: []) == "gallons")
        #expect(PhoneEditRules.pickShown("Manual", stored: "not needed", choices: ["Not needed", "None exists"])
                == "Not needed")
        #expect(PhoneEditRules.pickShown("Manual", stored: "Not recorded", choices: ["Not needed", "None exists"]) == "")
        #expect(PhoneEditRules.pickShown("Manual", stored: "", choices: ["Not needed", "None exists"]) == "")
    }

    /// Review focus 5: an item whose Holds unit or Manual is off its list keeps it when another field is saved. The
    /// form sends only the fields changed from the item's own, and an off-list value opens as stored.
    @Test func anOffListPickIsNeitherClearedNorRefused() {
        let was = ["holds": "quarts", "manual": "PDF on the Mac", "notes": ""]
        var now = was
        now["notes"] = "Top shelf"
        #expect(PhoneEditRules.changed(["holds", "manual", "notes"], was: was, now: now) == ["notes"])
        #expect(PhoneEditRules.changed(["holds", "notes"], was: nil, now: now) == ["holds", "notes"], "a new item")
        #expect(PhoneEditRules.pickShown("Holds unit", stored: "quarts", choices: Self.six) == "quarts")
        #expect(PhoneEditRules.pickShown("Manual", stored: "PDF on the Mac", choices: ["Not needed", "None exists"])
                == "PDF on the Mac")
    }
}
