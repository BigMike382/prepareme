import PrepareMeShared
import Testing

/// When the map's tap sheet offers to add a pin (the map pins plan, Task 2.5, and its review): an empty spot always; a
/// held finger on a storm warning, a road report, a gauge or a route line too, since that is where a pin is wanted;
/// never a tap or hold on a pin, meeting place or the Start point, which shows that one's card alone.
struct TapSheetTests {
    @Test func anEmptySpotOffersAdding() {
        #expect(StreetMap.offersAdding(layers: [], longPress: true))
        #expect(StreetMap.offersAdding(layers: [], longPress: false))
    }

    @Test func aHeldFingerOnAWarningRoadGaugeOrRouteOffersAdding() {
        for layer in ["pm-warning-fill", "pm-road-line", "pm-road-point", "pm-gauge", "pm-route"] {
            #expect(StreetMap.offersAdding(layers: [layer], longPress: true), "\(layer)")
        }
        #expect(StreetMap.offersAdding(layers: ["pm-warning-fill", "pm-route"], longPress: true))
    }

    @Test func aPlainTapOnSomethingShowsOnlyIt() {
        #expect(!StreetMap.offersAdding(layers: ["pm-warning-fill"], longPress: false))
        #expect(!StreetMap.offersAdding(layers: ["pm-route"], longPress: false))
    }

    @Test func aPinMeetingPlaceOrStartShowsItsCardAlone() {
        for layer in ["pm-pin", "pm-rally", "pm-start"] {
            #expect(!StreetMap.offersAdding(layers: [layer], longPress: true), "\(layer)")
            #expect(!StreetMap.offersAdding(layers: ["pm-warning-fill", layer], longPress: true), "\(layer)")
        }
    }
}
