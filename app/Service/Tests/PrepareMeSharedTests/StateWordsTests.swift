@testable import PrepareMeShared
import Testing

/// Look 3's empty and error screens (spec section 10, rule 2; plan Task 4.2): a dead end gets its next step, in words
/// kept here beside the words they replace.
struct StateWordsTests {
    /// The welcome once paired no longer points to a "Home Mac tab": on an adult's iPhone Home Mac is a button.
    @Test func theWelcomeOncePairedNamesHomeMacNotATab() {
        #expect(StateWords.welcomePaired == "The library comes from the Mac at home, over Wi-Fi. Downloads shows how "
            + "far it has got.")
        #expect(!StateWords.welcomePaired.contains("tab"))
        #expect(StateWords.openHomeMac == "Open Downloads")
    }

    /// A camera turned off for PrepareMe says so, with the way to Settings; a camera that can't read keeps its words.
    @Test func aCameraTurnedOffSaysSoWithAWayToSettings() {
        #expect(StateWords.cameraOff == "The camera is turned off for PrepareMe.")
        #expect(StateWords.cameraTurnOn == "Turn on Camera in PrepareMe's settings to scan.")
        #expect(StateWords.openSettings == "Open Settings")
        #expect(StateWords.cantReadCodes == "This device's camera can't read codes here.")
        #expect(StateWords.cantReadDates == "This device's camera can't read dates here.")
        #expect(StateWords.cantReadPairing == "The camera can't read codes here; paste the code instead.")
        #expect(StateWords.cameraIsOff(.denied) && StateWords.cameraIsOff(.restricted))
        #expect(!StateWords.cameraIsOff(.allowed) && !StateWords.cameraIsOff(.notAsked))
    }

    /// A bin the phone's copy doesn't hold says where to go, from the scanner as from a bin label's link.
    @Test func aBinNotInTheCopySaysWhereToGo() {
        #expect(StateWords.binNotInCopy(device: "iPad") == "That bin isn't in this iPad's copy of the inventory yet. "
            + "Open Inventory at home once to bring it up to date.")
    }

    /// "Open Home Mac" opens Home Mac's sheet where Home Mac is a button (an adult's iPhone), else its tab (look 3
    /// phase 0, question 7: choosing a tab not in the bar showed Today).
    @Test func openHomeMacOpensTheSheetWhereHomeMacIsAButton() {
        #expect(HomeMacRoute.opens(inBar: true) == .sheet)
        #expect(HomeMacRoute.opens(inBar: false) == .tab)
    }
}
