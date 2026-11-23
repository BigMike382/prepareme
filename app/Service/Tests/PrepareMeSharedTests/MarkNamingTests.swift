import PrepareMeShared
import Testing

/// The Mac's naming sheet (the map pins plan, Task 3.1, and its review): a new pin's Kind makes a meeting place or a
/// pin, and every pick saves a mark the editor keeps.
struct MarkNamingTests {
    let spot = MapMark(kind: .pin, name: "", points: [[-77.02, 38.9]])
    let water = PinLook.readyMade.first { $0.name == "Water" }!

    @Test func aNewPinStartsOnMakeYourOwnBlank() {
        let form = MarkNaming(draft: spot, startRole: .nearHome)
        #expect(form.pick == .own)
        #expect(form.kind == .pin)
        #expect(form.name.isEmpty)
    }

    @Test func meetingPlaceSavesARallyPointWithItsRole() {
        var form = MarkNaming(draft: spot, startRole: .nearHome)
        form.choose(.meeting)
        form.name = "Big oak"
        let mark = form.mark
        #expect(mark.kind == .rally)
        #expect(mark.role == .nearHome)
        #expect(mark.pinSymbol == nil && mark.pinColor == nil)
        #expect(mark.problem == nil)
    }

    @Test func aLookFillsTheNameAndLook() {
        var form = MarkNaming(draft: spot, startRole: .nearHome)
        form.choose(.look(water))
        var mark = form.mark
        #expect(mark.kind == .pin)
        #expect((mark.name, mark.pinSymbol, mark.pinColor) == (water.name, water.symbol, water.color))
        #expect(mark.role == nil)
        mark.uid = "0f8fad5b-d9cb-469f-a165-70867728950e"  // the editor gives a new pin its uid
        #expect(mark.problem == nil)
    }

    @Test func meetingPlaceAfterALookDropsTheLooksName() {
        var form = MarkNaming(draft: spot, startRole: nil)
        form.choose(.look(water))
        form.choose(.meeting)
        #expect(form.name.isEmpty, "Water never names a meeting place")
        #expect(form.mark.kind == .rally)
    }

    @Test func aTypedNameStaysWhateverIsPicked() {
        var form = MarkNaming(draft: spot, startRole: nil)
        form.name = "Water"  // typed, though a look has that name
        form.choose(.meeting)
        #expect(form.name == "Water")
        form.choose(.look(water))
        form.name = "Creek tap"  // a look's name, changed by hand
        form.choose(.own)
        #expect(form.name == "Creek tap")
    }

    @Test func makeYourOwnAfterALookStartsBlank() {
        var form = MarkNaming(draft: spot, startRole: nil)
        form.choose(.look(water))
        form.choose(.own)
        #expect(form.name.isEmpty)
        #expect((form.symbol, form.color) == ("mappin", "accent"))
    }

    @Test func aRouteOrStartHasNoKind() {
        let route = MarkNaming(draft: MapMark(kind: .route, name: "", points: [[-77.02, 38.9], [-77.03, 38.91]]),
                               startRole: .nearHome)
        #expect(route.pick == nil)
        #expect(route.kind == .route)
        var start = MarkNaming(draft: MapMark(kind: .start, name: "", points: [[-77.02, 38.9]]), startRole: .nearHome)
        start.name = "Around the corner"
        #expect(start.mark.kind == .start)
        #expect(start.mark.role == nil, "the first meeting place's role never lands on the Start point")
        #expect(start.mark.problem == nil)
    }
}
