// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (build plan phase 9).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import PDFKit
import PrepareMeShared
import SwiftUI

/// The Mac's street map (plan phase 9; screens approved 2026-10-14, owner, by click, on a mockup), Maps' Street map
/// side in the main window since the Mac sidebar plan's part 2 (Window › Street map opens it there). Since part 3 it is
/// the phone's screen (`StreetMapFullView`: Find a place, Layers, Topo map for here, a click's details) at the full
/// width, with the Mac's own tools in the toolbar: Add pin, Draw route and Print household map. The rally
/// points and routes list opens from the list button, beside the map. They are kept in the inventory file
/// (MapMarks.swift), so they change only through the inventory's editor, with its ID check and undo, and reach every
/// phone with the inventory.
struct PrepareMeStreetMapView: View {
    @ObservedObject private var model = InventoryModel.shared
    @ObservedObject private var store = PrepareMeMac.shared.store

    var body: some View {
        Group {
            switch model.state {
            case .notOpened: ProgressView()
            case .missing: InventoryMissing()
            case .problem(let why): InventoryNote(text: "The street map couldn't be read", line: why, kind: .damaged,
                                                  symbol: "exclamationmark.triangle")
            case .ready(let inventory):
                if let file = StreetMap.heldFile(store.record, in: store.libraryFolder),
                   let info = StreetMap.info(file) {
                    StreetMapMacScreen(file: file, info: info, marks: inventory.marks, pins: inventory.pins,
                                       built: StreetMap.built(store.record)).id(file)
                } else {
                    ListColumnSplit {  // no map to place them on: the list alone, to rename, note or delete
                        MapMarksList(marks: inventory.marks, pins: inventory.pins, select: { _ in })
                            .frame(minWidth: 240, idealWidth: 280, maxWidth: 400)
                    } content: {
                        InventoryNote(text: "No street map yet: it is made on this Mac, at home on Wi-Fi, and then "
                                      + "appears here and under Downloads on each phone.", symbol: "map")
                            .frame(minWidth: 360)
                    }
                }
            }
        }
        .navigationTitle("Street map")
        .onAppear { model.open() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.open() }
    }
}

/// The shared map screen with the Mac's tools in the toolbar, and the naming sheet a placed rally point or route asks.
private struct StreetMapMacScreen: View {
    let marks: [MapMark]
    let pins: [MapMark]  // the shared pins (the shared marks plan, phase 2)
    @State private var askCancel = false  // Cancel asking before it throws a route away (Task 11.7; F30)
    @State private var askCancelPoints = 0  // kept apart, so the title never flashes "0 points" as it closes
    @StateObject private var map: StreetMapModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.undoManager) private var undo

    init(file: URL, info: StreetMap.Info, marks: [MapMark], pins: [MapMark], built: String? = nil) {
        self.marks = marks
        self.pins = pins
        _map = StateObject(wrappedValue: StreetMapModel(file: file, info: info, built: built, platform: .mac))
    }

    var body: some View {
        StreetMapFullView(model: map)
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItemGroup {
                    switch map.mode {
                    case .browse:
                        Button { map.mode = .pin } label: { Label("Add pin", systemImage: "mappin") }
                            .help("Click the map where the pin goes: a meeting place, a hazard, water, a cache, anything worth marking")
                        Button { map.mode = .route([]) } label: {
                            Label("Draw route", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        }
                        .help("Click at every bend in the road, then Finish route")
                        Button { Task { await map.printHouseholdMap() } } label: {
                            Label("Print Household Map…", systemImage: "printer.fill")  // the Map menu's name (look 3, change 20); owner, 2026-10-15: the outline read as a box
                        }
                        .labelStyle(.titleAndIcon)
                        .disabled(marks.isEmpty || map.printing)
                        .help("The meeting places and routes on one page, with a legend, for the go-bags")
                    case .start, .pin:
                        Button("Cancel") { map.mode = .browse }
                            .keyboardShortcut(.cancelAction)  // Escape, as in a sheet (seen on screen, 2026-10-16)
                    case .route(let points):
                        Button("Undo point") { map.undoPoint() }.disabled(points.isEmpty)
                        Button("Finish route") { map.finishRoute() }.disabled(points.count < 2)
                        Button("Cancel") {  // past a few points, asks first (Task 11.7; F30)
                            if RouteDrawing.cancelAsks(points: points.count) {
                                askCancelPoints = points.count
                                askCancel = true
                            }
                            else { map.mode = .browse }
                        }
                        .keyboardShortcut(.cancelAction)  // Escape, as in a sheet (seen on screen, 2026-10-16)
                    }
                }
            }
            .focusedSceneValue(\.streetMapMenu, StreetMapMenuActions(  // the Map menu (task 5.1)
                browsing: map.mode == .browse, canPrint: !marks.isEmpty && !map.printing, hasStart: hasStart,
                findMe: { map.whereAmI() }, toggleList: { map.listing.toggle() },
                addPin: { map.mode = .pin }, drawRoute: { map.mode = .route([]) },
                addStart: { map.mode = .start },
                print: { Task { await map.printHouseholdMap() } }))
            .onAppear {
                map.controller?.setDark(scheme == .dark)
                map.appear()  // conditions every minute while it shows, and the Mac's position (task 12)
                #if PREPAREME_CHECK
                // The check build only, for a check that can't click (screenshots only): PREPAREME_CHECK_MAP=list opens
                // the marks panel, pin the new pin's sheet, tap a click on the first pin (the shared marks plan, phase 2),
                // rightclick a right-click beside it (the map pins plan, 3.1);
                // any of them moves the map to hold every mark and pin, since a made-up home opens on an empty middle
                if ProcessInfo.processInfo.environment["PREPAREME_CHECK_MAP"] != nil,
                   let box = StreetMapModel.bounds(marks + pins) {
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        map.controller?.fit(west: box.west - 0.01, south: box.south - 0.01, east: box.east + 0.01,
                                            north: box.north + 0.01)
                    }
                }
                switch ProcessInfo.processInfo.environment["PREPAREME_CHECK_MAP"] {
                case "list":
                    map.listing = true
                case "pin":
                    map.naming = MapMarkDraft(mark: MapMark(kind: .pin, name: "", points: [pins.first?.points.first ?? [0, 0]]))
                case "tap":
                    if let pin = pins.first, let at = pin.points.first, at.count == 2 {
                        map.tapped = StreetMapTap(longitude: at[0], latitude: at[1],
                                                  features: [["layer": "pm-pin", "shared": true, "pin": pin.uid ?? "", "at": at]],
                                                  point: CGPoint(x: 320, y: 260))
                    }
                case "rightclick":  // a right-click on an empty spot near the first pin: Add pin here alone (3.1)
                    if let at = pins.first?.points.first, at.count == 2 {
                        map.tapped = StreetMapTap(longitude: at[0] + 0.002, latitude: at[1], features: [],
                                                  point: CGPoint(x: 420, y: 300), longPress: true)
                    }
                default:
                    break
                }
                #endif
            }
            .onDisappear { map.disappear() }
            .alert(RouteDrawing.discardTitle(points: askCancelPoints), isPresented: $askCancel) {
                Button(RouteDrawing.discard, role: .destructive) { map.mode = .browse }
                Button(RouteDrawing.keepDrawing, role: .cancel) {}
            }
            .onChange(of: scheme) { _, now in map.controller?.setDark(now == .dark) }
            .onChange(of: marks) { _, _ in map.refreshMarks() }
            .onChange(of: pins) { _, _ in map.refreshPins() }
            .sheet(item: $map.naming) { draft in
                MapMarkNaming(draft: draft, startRole: Position.newRallyRole(marks), looks: PinLook.offered(pins)) { mark in
                    map.naming = nil
                    guard let mark else { return }
                    Task { await InventoryModel.shared.apply(.addMark(mark.rounded), undo: undo,
                                                             name: "Add \(mark.kind.undoWord)") }
                }
            }
    }

    private var hasStart: Bool { marks.contains { $0.kind == .start } }
}

extension MapMark.Kind {
    /// Its name in Edit › Undo's menu item.
    var undoWord: String {
        switch self {
        case .rally: "Meeting Place"
        case .route: "Route"
        case .start: "Printed Directions Start"
        case .pin: "Pin"
        }
    }
}

/// The list button's panel beside the map: the inventory's rally points and routes, edited in place.
struct StreetMapMacMarks: View {
    @ObservedObject var model: StreetMapModel
    @ObservedObject private var inventory = InventoryModel.shared  // its marks change: the list shows them

    var body: some View {
        MapMarksList(marks: model.marks, pins: model.sharedPins, select: { model.show($0) }, map: model)
    }
}

/// The rally points and routes list beside the map, opened from the list button (part 3). A plain panel, not an
/// inspector: an inspector brings a toolbar-high frosted strip of its own, which lay over Find a place below Maps'
/// switch, or hid it under the switch (seen on screen, 2026-10-16).
struct StreetMapSidePanel<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder let panel: () -> Panel

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            content
            if isPresented {
                Divider()
                panel().frame(width: 280)
            }
        }
    }
}

// MARK: The Map menu

/// What the Map menu calls on the street map shown, published with `focusedSceneValue` while it is on screen.
struct StreetMapMenuActions {
    let browsing, canPrint, hasStart: Bool
    let findMe, toggleList, addPin, drawRoute, addStart, print: () -> Void
}

private struct StreetMapMenuKey: FocusedValueKey { typealias Value = StreetMapMenuActions }

extension FocusedValues {
    var streetMapMenu: StreetMapMenuActions? {
        get { self[StreetMapMenuKey.self] }
        set { self[StreetMapMenuKey.self] = newValue }
    }
}

/// The menu bar's Map (street map fixes plan, task 5.1; Apple's menu bar page: every toolbar item is a menu command
/// too), its items dimmed when the street map isn't on screen. ⌘L is Apple Maps' own for the current location;
/// File › Print… (⌘P) prints the household map while the street map shows, so this Print has no key of its own.
struct StreetMapMenu: Commands {
    @FocusedValue(\.streetMapMenu) private var map

    var body: some Commands {
        CommandMenu("Map") {
            Button("Find Me") { map?.findMe() }.keyboardShortcut("l").disabled(map == nil)
            Button("Pins and Routes") { map?.toggleList() }.disabled(map == nil)
            Divider()
            Button("Add Pin") { map?.addPin() }.disabled(map?.browsing != true)
            Button("Draw Route") { map?.drawRoute() }.disabled(map?.browsing != true)
            Button("Set Printed Directions Start…") { map?.addStart() }.disabled(map?.browsing != true || map?.hasStart != false)
            Divider()
            Button("Print Household Map…") { map?.print() }.disabled(map?.browsing != true || map?.canPrint != true)
        }
    }
}

// MARK: What the Mac hands the shared model

extension StreetMapPlatform {
    /// The Mac's: its own library and the inventory file's marks; the map-conditions.json it packs, with no storm
    /// outlines of its own; Topo map for here on Maps › Find a map; no compass. Since the Mac sidebar plan's task 12 it
    /// asks where it is (Wi-Fi, no GPS; the location entitlement) and hands Drive there and Walk there to Organic Maps,
    /// to which macOS hands the phone's om:// link (Organic Maps for Apple silicon Macs; checked 2026-10-16).
    static var mac: StreetMapPlatform {
        StreetMapPlatform(record: { PrepareMeMac.shared.store.record },
                          marks: {
                              switch InventoryModel.shared.state {
                              case .ready(let inventory): inventory.marks
                              default: []
                              }
                          },
                          pins: {
                              switch InventoryModel.shared.state {
                              case .ready(let inventory): inventory.pins
                              default: []
                              }
                          },
                          warningShapes: { [] },
                          openTopo: { PrepareMeMacTabs.shared.open($0) },  // a map file's page: Maps, on Find a map
                          canOpen: { NSWorkspace.shared.urlForApplication(toOpen: $0) != nil },
                          open: { url in
                              // an Apple Maps link to Maps itself: https alone opens the browser (hand-off plan, 3.1)
                              if url.host == "maps.apple.com",
                                 let maps = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Maps") {
                                  NSWorkspace.shared.open([url], withApplicationAt: maps, configuration: .init())
                              } else {
                                  NSWorkspace.shared.open(url)
                              }
                          },
                          heading: false, locates: true, directions: true)
    }
}

// MARK: The Mac's tools

/// What the map is doing: looking, placing a pin (a meeting place is one, by its sheet's Kind) or the Start point, or
/// drawing a route (its points so far).
enum StreetMapMacMode: Equatable {
    case browse, start, pin, route([[Double]])
}

struct MapMarkDraft: Identifiable {
    let id = UUID()
    let mark: MapMark
}

/// Add pin, Draw route and Print household map, on the shared model (its `mode`, `naming` and `printing`).
extension StreetMapModel {
    var hint: String? {
        switch mode {
        case .browse: printing ? "Getting the map ready to print…" : nil
        case .pin: "Click the map where the pin goes."
        case .start: "Click the map where the printed turn lists begin: around the corner from your street, not the house."
        case .route(let points): RouteDrawing.hint(points: points.count)  // a click at every bend (Task 11.7; F30)
        }
    }

    /// A click on the map while placing: true when Add pin, the Start point or Draw route took it (then it shows no details).
    func placing(_ longitude: Double, _ latitude: Double) -> Bool {
        switch mode {
        case .browse:
            return false
        case .start:
            mode = .browse
            naming = MapMarkDraft(mark: MapMark(kind: .start, name: "", points: [[longitude, latitude]]))
        case .pin:
            mode = .browse
            naming = MapMarkDraft(mark: MapMark(kind: .pin, name: "", points: [[longitude, latitude]]))
        case .route(let points):
            if points.count < MapMark.routePoints { mode = .route(points + [[longitude, latitude]]) }
        }
        return true
    }

    func undoPoint() {
        if case .route(let points) = mode { mode = .route(Array(points.dropLast())) }
    }

    func finishRoute() {
        guard case .route(let points) = mode, points.count >= 2 else { return }
        mode = .browse
        naming = MapMarkDraft(mark: MapMark(kind: .route, name: "", points: points))
    }

    func showDraft(_ points: [[Double]]) {
        var features: [[String: Any]] = points.map {
            ["type": "Feature", "geometry": ["type": "Point", "coordinates": $0], "properties": [:]]
        }
        if points.count > 1 {
            features.append(["type": "Feature", "geometry": ["type": "LineString", "coordinates": points],
                             "properties": [:]])
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features]))
            ?? StreetMapWords.empty
        controller?.show(.draft, data)
    }

    static func bounds(_ marks: [MapMark]) -> (west: Double, south: Double, east: Double, north: Double)? {
        let points = marks.flatMap(\.points).filter { $0.count == 2 }
        guard let first = points.first else { return nil }
        return points.reduce((first[0], first[1], first[0], first[1])) { box, p in
            (min(box.0, p[0]), min(box.1, p[1]), max(box.2, p[0]), max(box.3, p[1]))
        }
    }

    /// The printed household map (plan phase 9, item 10; scale, grid and close-up from an audit, 2026-10-14): every
    /// rally point and route on one landscape page, north up, with the US National Grid and a scale bar so it can be
    /// read with no phone; then a close-up of home (the Near home rally point, else the first); then the rest of the
    /// legend on pages of their own when it doesn't fit beside the map.
    func printHouseholdMap() async {
        let marks = marks
        guard let box = Self.bounds(marks), !printing else { return }
        printing = true
        printLayers(marks)  // the rally points, routes and conditions always print, whatever Layers shows
        defer {
            printing = false
            screenLayers()
        }
        let pad = max(box.east - box.west, box.north - box.south) * 0.08 + 0.002
        guard let whole = await sheet(west: box.west - pad, south: box.south - pad, east: box.east + pad,
                                      north: box.north + pad) else { return }
        var close: HouseholdMap.Sheet?
        if let home = Position.planned(marks, eventOn: false) ?? Position.ordered(marks).first(where: { $0.kind == .rally }),
           let p = home.points.first, p.count == 2 {
            let dLat = 0.012, dLon = 0.012 / max(0.2, cos(p[1] * .pi / 180))
            close = await sheet(west: p[0] - dLon, south: p[1] - dLat, east: p[0] + dLon, north: p[1] + dLat)
            close?.title = "Close-up: \(home.name)"
        }
        guard let document = PDFDocument(data: HouseholdMap.pdf(whole: whole, close: close, marks: marks)) else { return }
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.paperSize = HouseholdMap.page
        info.orientation = .landscape
        for side in [\NSPrintInfo.topMargin, \.bottomMargin, \.leftMargin, \.rightMargin] { info[keyPath: side] = 0 }
        document.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: true)?.run()
    }

    private func sheet(west: Double, south: Double, east: Double, north: Double) async -> HouseholdMap.Sheet? {
        guard let shot = await controller?.snapshot(west: west, south: south, east: east, north: north) else { return nil }
        return HouseholdMap.Sheet(png: shot.png, bounds: shot.bounds, title: "Household map")
    }
}

/// A new pin's, route's or Start point's name and note, asked for once it is placed. A new pin starts with its Kind
/// (the map pins plan, Task 3.1): Meeting place makes it a rally point; a look fills its name, symbol and color. What
/// each pick does is `MarkNaming`'s (PrepareMeShared), tested there.
private struct MapMarkNaming: View {
    let looks: [PinLook]  // a pin's ready-made looks, then those already on the map
    let done: (MapMark?) -> Void  // the mark as named, or nil for Cancel
    @State private var form: MarkNaming

    init(draft: MapMarkDraft, startRole: MapMark.Role?, looks: [PinLook], done: @escaping (MapMark?) -> Void) {
        self.looks = looks
        self.done = done
        var form = MarkNaming(draft: draft.mark, startRole: startRole)
        #if PREPAREME_CHECK
        // The check build only, for a check that can't click: PREPAREME_CHECK_KIND=meeting, or a look's name
        switch ProcessInfo.processInfo.environment["PREPAREME_CHECK_KIND"] {
        case "meeting": form.choose(.meeting)
        case let wanted?: if let look = looks.first(where: { $0.name == wanted }) { form.choose(.look(look)) }
        case nil: break
        }
        #endif
        _form = State(initialValue: form)
    }

    var body: some View {
        PMForm {
            Text(title).font(.pmHeadline)
            if form.pick != nil {  // a pick fills the name and look; each can still change below
                Picker("Kind", selection: Binding(get: { form.pick ?? .own }, set: { form.choose($0) })) {
                    Label(MapMarkWords.meetingPlace, systemImage: "flag.fill").tag(MarkNaming.Pick.meeting)
                    Divider()
                    ForEach(looks, id: \.self) { look in
                        Label(look.name, systemImage: look.symbol).tag(MarkNaming.Pick.look(look))
                        if look == PinLook.readyMade.last, looks.count > PinLook.readyMade.count { Divider() }
                    }
                    Divider()
                    Text(MapMarkWords.makeYourOwn).tag(MarkNaming.Pick.own)
                }
            }
            TextField("Name", text: $form.name, prompt: Text(prompt))
            // A short label: "Note (optional)" was wider than the label column and spilled past the sheet's edge
            TextField("Note", text: $form.note, prompt: Text("Optional"), axis: .vertical)
            switch form.kind {
            case .rally:
                MapMarkRolePicker(role: $form.role)
                Text(Position.kidsPointTo).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    .fixedSize(horizontal: false, vertical: true)  // F27; whole, not cut to one line (task 5.2)
            case .route:
                MapMarkRoutePicker(role: $form.routeRole)
                Text(MapMarkRoutePicker.what).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    .fixedSize(horizontal: false, vertical: true)
            case .start:
                Text(StreetMap.startPoint).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    .fixedSize(horizontal: false, vertical: true)
            case .pin:
                PinLookFields(symbol: $form.symbol, color: $form.color)
            }
            Text("Every phone gets it with the inventory, a child's phone included. Names are checked for ID numbers.")
                .font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                .fixedSize(horizontal: false, vertical: true)  // wraps to the column, not widening it past the labels
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Save") { done(form.mark) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .pmScreen()  // the margin in the form's ground too, so its labels don't sit on the ground's edge
        .frame(width: 460)
    }

    private var title: String {
        switch form.kind {
        case .rally: "New meeting place"
        case .route: "New route (\(form.draft.points.count) points)"
        case .start: "Printed directions start"
        case .pin: "New pin"
        }
    }

    private var prompt: String {
        switch form.kind {
        case .rally: "Meet at the big oak"
        case .route: "Way out north by the creek"
        case .start: "Around the corner"
        case .pin: "Cache"
        }
    }
}

/// A rally point's role (owner, 2026-10-14): the kids' arrow points to Near home, or Out of town in Event mode.
private struct MapMarkRolePicker: View {
    @Binding var role: MapMark.Role?

    var body: some View {
        Picker(MapMarkWords.whichOne, selection: $role) {
            Text(MapMarkWords.anotherPlace).tag(MapMark.Role?.none)
            ForEach(MapMark.Role.allCases, id: \.self) { Text($0.words).tag(MapMark.Role?.some($0)) }
        }
        .help("The kids' phones point to Near home, or to Out of town while Event mode is On")
    }
}

/// A route's part (the street map fixes plan, task 2.1): the phones' strip names the main route, or the alternate
/// once someone taps Use the alternate.
private struct MapMarkRoutePicker: View {
    @Binding var role: MapMark.RouteRole?
    static let what = StreetMap.routeRoles

    var body: some View {
        Picker("Role", selection: $role) {
            Text("No role").tag(MapMark.RouteRole?.none)
            ForEach(MapMark.RouteRole.allCases, id: \.self) { Text($0.words).tag(MapMark.RouteRole?.some($0)) }
        }
        .help(Self.what)
    }
}

/// The rally points and routes: each one's name and note, edited in place, Show on map, and Delete (Edit › Undo
/// puts it back).
private struct MapMarksList: View {
    let marks: [MapMark]
    let pins: [MapMark]  // the shared pins, listed under their own heading (the shared marks plan, phase 2)
    let select: (MapMark) -> Void
    /// The map, for the right-click's Drive and Walk and Set start…; nil in the list shown with no map yet
    var map: StreetMapModel? = nil
    @ObservedObject private var model = InventoryModel.shared
    @State private var selecting = false  // Select: tick the ones to share (owner, 2026-10-19)
    @State private var ticked: Set<Int64> = []
    /// The paired phones and the owner's names for them, read as the panel opens: "Added Nov 12 by Sam's iPhone"
    @State private var makers: [MapMark.PhoneName] = []
    @State private var deletedOpen = false  // closed with its count: test pins made it long (owner, 2026-11-15)

    var body: some View {
        PMList {
            if let message = model.message {  // why the last change was refused (an ID in a name, say)
                Text(message).foregroundStyle(PrepareMeColors.red).lineLimit(6).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if marks.isEmpty, pins.isEmpty {
                Text("No pins or routes yet. Add pin and Draw route are above the map.")
                    .foregroundStyle(PrepareMeColors.text2)
            } else if selecting {
                Text("Tick the pins and routes to share, then Share.").foregroundStyle(PrepareMeColors.text2)
                VStack(alignment: .leading) {  // one above the other: side by side, the panel cut the words off
                    let chosen = OrganicMaps.picked(marks + pins, ticked)
                    OrganicMapsShare(marks: chosen, picked: chosen.count).pmAction(fullWidth: false)
                    OrganicMapsShare(marks: chosen, picked: chosen.count, gpx: true).pmAction(fullWidth: false)
                    Button("Cancel") {
                        selecting = false
                        ticked = []
                    }
                }
            } else {
                VStack(alignment: .leading) {
                    OrganicMapsShare(marks: marks).pmAction(fullWidth: false)  // step 6, part 3: a button, not plain text
                    OrganicMapsShare(marks: marks, gpx: true).pmAction(fullWidth: false)  // task 3.5
                    Button("Select…") { selecting = true }.help("Tick the pins and routes to share")
                }
            }
            let ordered = Position.ordered(marks)
            let rally = ordered.filter { $0.kind == .rally }, routes = ordered.filter { $0.kind == .route }
            let start = ordered.filter { $0.kind == .start }
            if !rally.isEmpty {
                Section(pmTitle: "Meeting places") { ForEach(rally) { row($0) } }
            }
            if !routes.isEmpty {
                Section(pmTitle: "Routes") { ForEach(routes) { row($0) } }
            }
            if !pins.isEmpty {
                Section(pmTitle: "Pins") { ForEach(pins) { row($0) } }
            }
            if case .ready(let inventory) = model.state {  // a phone's delete, put back in one click (2026-11-12)
                let gone = DeletedMark.shown(inventory.deletedMarks, marks: marks + pins)
                if !gone.isEmpty {
                    Section {  // a fold, not a folding Section: those fold only in a sidebar's list
                        DisclosureGroup(isExpanded: $deletedOpen) {
                            ForEach(Array(gone.enumerated()), id: \.offset) {
                                DeletedMarkRow(deleted: $0.element, marks: marks + pins)
                            }
                        } label: {
                            Text(MapMarkWords.deletedHeading(gone.count)).font(.pmHeadline)
                                .foregroundStyle(PrepareMeColors.text2)
                        }
                    }
                }
            }
            // last, where it is set once (the map pins plan, Task 3.2); with the Map menu, its only way in. None in the
            // list shown with no map yet, where there is nothing to place it on
            if let map, start.isEmpty {
                Section(pmTitle: "Printed directions") {
                    Button("Set start…") { map.mode = .start }
                        .pmAction(fullWidth: false)
                        .disabled(map.mode != .browse)
                        .help("Click the map where the printed turn lists begin")
                    Text(StreetMap.startPoint).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !start.isEmpty {
                Section(pmTitle: "Printed directions") { ForEach(start) { row($0) } }
            }
        }
        .onAppear { makers = PhonePairing.shared.makers() }
    }

    func row(_ mark: MapMark) -> some View {
        let lists = model.turnLists
        let words = UserDefaults.standard.stringArray(forKey: HouseholdPagesModel.ownWordsKey) ?? []
        let start = marks.first { $0.kind == .start }
        return HStack(alignment: .top) {
            if selecting, mark.kind != .start {  // never shared: it is often the house
                MarkTick(name: mark.name, on: ticked.contains(mark.id)) {
                    if ticked.contains(mark.id) { ticked.remove(mark.id) } else { ticked.insert(mark.id) }
                }
                .help("Pick it to share")
            }
            MapMarkRow(mark: mark, select: select, map: map,  // turn lists are for rally points and routes
                       turns: mark.kind == .start || mark.kind == .pin ? nil
                           : lists?.line(for: mark, start: start) ?? TurnLists.notYet,
                       namesHome: lists?.namesHome(mark, start: start, words: words) == true,
                       maker: mark.makerName(makers))
        }
    }
}

/// A rally point or route a phone deleted, with Put back (Edit › Undo takes it away again), for 30 days.
private struct DeletedMarkRow: View {
    let deleted: DeletedMark
    let marks: [MapMark]
    @Environment(\.undoManager) private var undo

    var body: some View {
        HStack {
            Label(MapMarkWords.deletedOn(deleted.mark.name, deleted.at.formatted(.dateTime.month(.abbreviated).day())),
                  systemImage: deleted.mark.symbol)
                .foregroundStyle(PrepareMeColors.text2)
            Spacer()
            Button(MapMarkWords.putBack) {
                Task {
                    await InventoryModel.shared.apply(deleted.putBack(among: marks), undo: undo,
                                                      name: "Put Back \(deleted.mark.kind.undoWord)")
                }
            }
            .help("Back on the Mac's map, and every phone's at its next check")
        }
    }
}

private struct MapMarkRow: View {
    let mark: MapMark
    let select: (MapMark) -> Void
    let map: StreetMapModel?
    /// The printed turn lists' line (hand-off improvements, phase 3): what was made, or why not; nil for the Start.
    var turns: String?
    var namesHome = false
    var maker: String?  // the owner's name for the phone that added it, when there is one
    @State private var name = ""
    @State private var note = ""
    @State private var role: MapMark.Role?
    @State private var routeRole: MapMark.RouteRole?
    @State private var symbol = "mappin"
    @State private var color = "accent"
    @FocusState private var editing: Bool
    @Environment(\.undoManager) private var undo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if mark.kind == .pin { StreetMapPinIcon(mark) }
                TextField("Name", text: $name).font(.pmHeadline).onSubmit(save).focused($editing)
                Button { select(mark) } label: { Image(systemName: "scope") }
                    .buttonStyle(.borderless)
                    .help("Show on map")
                    .accessibilityLabel("Show on map")  // VoiceOver's name for the picture (phase 8)
                Button(role: .destructive) { delete() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete")  // the picture's spoken name (look 3, accessibility fix 12)
                .help("Delete (Edit › Undo puts it back)")
            }
            TextField("Note", text: $note, axis: .vertical).font(.pmNote).onSubmit(save).focused($editing)
            switch mark.kind {
            case .rally:
                MapMarkRolePicker(role: $role).labelsHidden().controlSize(.small)
                    .onChange(of: role) { _, now in if now != mark.role { save() } }
            case .route:
                MapMarkRoutePicker(role: $routeRole).labelsHidden().controlSize(.small)
                    .onChange(of: routeRole) { _, now in if now != mark.routeRole { save() } }
            case .start:
                Text(StreetMap.startPoint).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            case .pin:
                PinLookFields(symbol: $symbol, color: $color).labelsHidden().controlSize(.small)
                    .onChange(of: symbol) { _, now in if now != mark.pinSymbol { save() } }
                    .onChange(of: color) { _, now in if now != mark.pinColor { save() } }
            }
            Text(place).font(.pmNote).foregroundStyle(PrepareMeColors.text2).textSelection(.enabled)
            if let added = MapMarkWords.added(mark, here: StreetMapWords.here, device: StreetMapWords.device, name: maker) {
                Text(added).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            }
            if let turns {
                Label(turns, systemImage: "list.number").font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if namesHome {
                Label(mark.kind == .route ? TurnLists.namesHomeRouteWarning : TurnLists.namesHomeWarning,
                      systemImage: "exclamationmark.triangle.fill").font(.pmNote)
                    .foregroundStyle(PrepareMeColors.caution).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {  // the row's own buttons, by right-click too (the Apple guidelines plan, phase 8)
            Button("Show on Map") { select(mark) }
            // as the phone's card (the map pins plan, Task 3.2): Drive and Walk straight to Organic Maps, Apple Maps after
            // the share items; none on the Start point, which is often the house (owner, 2026-11-12, by click)
            if mark.kind != .start {
                if let map, map.platform.directions, let to = map.goSpot(mark) {
                    Button("Drive") { map.directions(to: to, name: mark.name, travel: .drive) }
                    Button("Walk") { map.directions(to: to, name: mark.name, travel: .walk) }
                }
                OrganicMapsShare(marks: [mark])
                OrganicMapsShare(marks: [mark], gpx: true)
                if let map, map.platform.directions { AppleMapsItems(model: map, mark: mark) }
            }
            Divider()
            PMMenuDelete("Delete") { delete() }
        }
        .onAppear { show(mark) }
        .onChange(of: mark) { _, now in show(now) }
        .onChange(of: editing) { _, now in if !now { save() } }  // clicking away saves too, not only Return
    }

    /// Where it is: a point's latitude and longitude, or a route's length in points.
    private var place: String {
        guard mark.kind != .route, let point = mark.points.first, point.count == 2 else {
            return "\(mark.points.count) points"
        }
        return String(format: "%.6f, %.6f", point[1], point[0])
    }

    private func delete() {
        Task {
            await InventoryModel.shared.apply(.removeMark(id: mark.id, expected: mark), undo: undo,
                                              name: "Delete \(mark.kind.undoWord)")
        }
    }

    /// The fields as the mark holds them (a pin's look too).
    private func show(_ mark: MapMark) {
        (name, note, role, routeRole) = (mark.name, mark.note, mark.role, mark.routeRole)
        (symbol, color) = (mark.pinSymbol ?? "mappin", mark.pinColor ?? "accent")
    }

    private func save() {
        var changed = mark
        changed.name = name
        changed.note = note
        changed.role = mark.kind == .rally ? role : nil
        changed.routeRole = mark.kind == .route ? routeRole : nil
        if mark.kind == .pin { (changed.pinSymbol, changed.pinColor) = (symbol, color) }
        guard changed != mark else { return }
        Task {
            let kept = await InventoryModel.shared.apply(.changeMark(changed, expected: mark), undo: undo,
                                                         name: name != mark.name ? "Rename" : note != mark.note ? "Note"
                                                             : mark.kind == .pin ? "Look" : "Role")
            if kept == nil { show(mark) }  // refused: shows what is kept
        }
    }
}
#endif
