// This file is part of PrepareMe, a local build of Kiwix for one household (build plan phase 9; Mac sidebar plan,
// part 3).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import CoreLocation
import PrepareMeShared
import SwiftUI
import UniformTypeIdentifiers

/// One street map screen for the phone and the Mac (Mac sidebar plan, part 3; owner, 2026-10-15): the full map, its
/// list, a spot's details and its model, moved here from the iPhone-only code so a fix to the map reaches both. What
/// differs by device is handed to the model (`StreetMapPlatform`); the phone's own views (the strip, the simple view,
/// Share) stay in PrepareMeStreetMap.swift, and the phone's safe areas, sheet heights and title bar stay behind
/// `#if os(iOS)` here. The Mac's tools (Add pin, Draw route, Print) and its list panel are in
/// PrepareMeStreetMapMac.swift; here, behind `#if os(macOS)`, are their state, a click's details in a popover and the
/// list as an inspector. Each closure runs on the main thread, where the screens' own models live.
struct StreetMapPlatform {
    /// The files this device holds: phone, PrepareMeLibrary.shared.record; Mac, PrepareMeMac.shared.store.record.
    var record: @MainActor () -> LibraryRecord
    /// The rally points and routes: phone, PhoneInventoryModel's copy; Mac, InventoryModel's.
    var marks: @MainActor () -> [MapMark]
    /// The shared pins (the shared marks plan): the Mac, InventoryModel's; the phone, none until its phase 3.
    var pins: @MainActor () -> [MapMark] = { [] }
    /// Storm warnings' outlines: phone, LiveConditions' own reading; Mac, none (it draws map-conditions.json only).
    var warningShapes: @MainActor () -> [WarningShape]
    /// Topo map for here, opened where the device shows Find a map: phone, PrepareMeTabs.open; Mac,
    /// PrepareMeMacTabs.shared.open.
    var openTopo: @MainActor (URL) -> Void
    /// Organic Maps' and Apple Maps' links: UIApplication on the phone, NSWorkspace on the Mac.
    var canOpen: @MainActor (URL) -> Bool, open: @MainActor (URL) -> Void
    /// Whether to read the compass: the phone, yes; the Mac has none.
    var heading: Bool
    /// Whether the map asks where the device is (Where am I and the position): the phone, by GPS; the Mac, by Wi-Fi,
    /// with the location entitlement (Mac sidebar plan, task 12; kiwix-mac/build.sh checks the signed app has it).
    var locates: Bool
    /// Drive there and Walk there, in Organic Maps or Apple Maps: both (on the Mac since task 12: macOS hands it the same
    /// link).
    var directions: Bool
}

// MARK: The full map

struct StreetMapFullView: View {
    @ObservedObject var model: StreetMapModel
    /// A child's phone: back to the rally view (Task 11.1; F22), else nil.
    var backToRally: (() -> Void)? = nil
    @State private var query = ""
    @State private var found: [PlaceIndex.Place] = []
    @State private var foundFor = ""  // the text `found` answers
    @FocusState private var searching: Bool
    @AppStorage("streetMap.showConditions") private var showConditions = true
    @AppStorage("streetMap.showMarks") private var showMarks = true
    @AppStorage("streetMap.showPins") private var showPins = true
    @State private var askOldPins = false  // the phone's own pins from before pins were shared (phase 3)
    @AppStorage("streetMap.showOld") private var showOld = false
    @ObservedObject private var redNight = PrepareMeRedNight.shared  // phase D
    @State private var noTopo = false
    #if os(iOS)
    @State private var screen: CGSize?  // the map's room, for folding the strip on a narrow phone (S4.1)
    @State private var stripOpen = false  // a folded strip opened by a tap
    #if os(iOS)
    private var buttonsAside: Bool {
        stripOpen && screen.map { StripFold.folded(width: $0.width, height: $0.height) } == true
    }
    #endif
    @State private var addingPins = false  // Add pins from a file's picker (task 4.1)
    @State private var pdf: StreetMapPDF?  // Save as PDF's file, waiting for where to save it (task 4.2)
    @State private var notice: String?  // what Add pins from a file did, or why Save as PDF couldn't
    @Environment(\.dynamicTypeSize) private var textSize
    #endif
    #if os(macOS)
    @State private var detailsAt: CGPoint?  // the last click's place, for the popover's anchor as it closes
    #endif

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let controller = model.controller {  // the full map is shown only with a map file
                StreetMapWebView(controller: controller)
                #if os(iOS)
                    .ignoresSafeArea(edges: [.top, .bottom])  // under the glass bars, as Apple's Maps (phase 10)
                #else
                    .popover(item: $model.tapped, attachmentAnchor: tapAnchor) { StreetMapDetails(model: model, tap: $0) }
                #endif
            }
            VStack(spacing: 0) {
                search
                if let backToRally {  // a child's way back from the full map (Task 11.1; F22)
                    Button(action: backToRally) { Label(RallyWords.backToRally, systemImage: "flag.fill") }
                        .pmAction(fullWidth: false)
                        .background {  // the outlined box needs a backing over the map; the glass button has its own
                            if #available(iOS 26, macOS 26, *) {} else {
                                RoundedRectangle(cornerRadius: 12).fill(.regularMaterial)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                #if os(iOS)
                // the round buttons in the room above the strip, so a tall strip never runs under their words (the
                // phase 11 look); they only overlap it when the phone has no room for both
                Color.clear.allowsHitTesting(false)  // their size never pushes the page: an overlay
                    .overlay {  // the width is read here and handed down, so a row wraps whatever ViewThatFits asks
                        GeometryReader { room in
                            fittedButtons(width: room.size.width - 12)
                                .padding(.trailing, 12).padding(.top, 8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        }
                    }
                    // an opened strip on a narrow or sideways phone leaves no room for even two rows of them: they
                    // step aside until Less, so they never cover its Drive and Walk (map pins phase 2)
                    .opacity(buttonsAside ? 0 : 1)
                    .allowsHitTesting(!buttonsAside)
                    .accessibilityHidden(buttonsAside)
                    .zIndex(1)  // on a short phone they then stay on top of the strip, not under it
                if !searching {  // out of the way of the results and the keyboard
                    StreetMapStrip(model: model,
                                   // narrow until measured; folded at the accessibility sizes too, where the whole
                                   // strip ran taller than the screen and pushed the map over its bar (2026-11-12)
                                   folded: textSize.isAccessibilitySize
                                       || screen.map { StripFold.folded(width: $0.width, height: $0.height) } ?? true,
                                   open: $stripOpen,
                                   // opened, it scrolls in a third (half below the accessibility sizes), leaving
                                   // the buttons room: Drive and Walk made it too tall on an SE (map pins phase 2)
                                   room: screen.map { $0.height / (textSize.isAccessibilitySize ? 3 : 2) })
                        .fixedSize(horizontal: false, vertical: true)  // its whole height: the buttons get the rest
                }
                #else
                Spacer(minLength: 0)
                if let hint = model.hint {  // Add pin's and Draw route's next step, or a print under way
                    Text(hint)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 16)
                } else if model.here == nil, let line = model.noFixLine {  // no fix, or a stale one dropped (task 12)
                    Text(line)
                        .foregroundStyle(PrepareMeColors.text2)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 16)
                }
                #endif
            }
            #if os(iOS)
            .ignoresSafeArea(.keyboard)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { screen = $0 }
            .onDisappear { stripOpen = false }  // folded again each time Maps opens (S4.1)
            #endif
            #if os(macOS)
            buttons
                .padding(.trailing, 12)
                .padding(.top, 72)
            #endif
        }
        .onChange(of: showConditions, initial: true) { _, on in model.show(conditions: on) }
        .onChange(of: showOld, initial: true) { _, on in model.show(old: on) }
        #if os(iOS)
        .sheet(isPresented: $model.listing) { StreetMapMarksList(model: model) }
        #if targetEnvironment(simulator)
        .task { await checkMarkTap() }  // the simulator draws no map to tap
        #endif
        #else
        .modifier(StreetMapSidePanel(isPresented: $model.listing) {  // the Mac's list is edited in place, beside the map
            StreetMapMacMarks(model: model)
        })
        #if PREPAREME_CHECK
        .task {  // the check build only, for a check that can't click: PREPAREME_CHECK_PART=marks opens the list
            if ProcessInfo.processInfo.environment["PREPAREME_CHECK_PART"] == "marks" { model.listing = true }
            if ProcessInfo.processInfo.environment["PREPAREME_CHECK_PART"] == "rightclick" {  // task 5.1's details
                try? await Task.sleep(for: .seconds(4))
                model.tapped = StreetMapTap(longitude: -77.02, latitude: 38.9, features: [], point: nil, longPress: true)
            }
            await checkMarkTap()
            if ProcessInfo.processInfo.environment["PREPAREME_CHECK_PART"] == "naming" {  // a new pin's sheet (3.1)
                try? await Task.sleep(for: .seconds(4))  // PREPAREME_CHECK_KIND picks its Kind
                model.naming = MapMarkDraft(mark: MapMark(kind: .pin, name: "", points: [[-77.02, 38.9]]))
            }
        }
        #endif
        #endif
        .onChange(of: showMarks, initial: true) { _, on in model.show(marks: on) }
        .onChange(of: pinsOn, initial: true) { _, on in model.show(pins: on) }
        #if os(iOS)
        .sheet(item: $model.tapped) { tap in
            StreetMapTapSheet(model: model, tap: tap).tapCardHeight(tall: textSize.isAccessibilitySize)
        }
        .task(id: model.oldPins) { if model.oldPins > 0 { askOldPins = true } }
        .alert(MapMarkWords.oldPinsTitle, isPresented: $askOldPins) {  // none is sent without asking (plan section 5)
            Button(MapMarkWords.oldPinsShare) { model.shareOldPins() }
            Button(MapMarkWords.oldPinsDelete, role: .destructive) { model.deleteOldPins() }
            Button(MapMarkWords.oldPinsLater, role: .cancel) {}  // asked again the next time the map opens
        } message: {
            Text(MapMarkWords.oldPinsQuestion(model.oldPins, device: StreetMapWords.device))
        }
        .alert(LocationAsk.refusedTitle, isPresented: $model.explainRefusal) {  // Find me, refused (Task 11.3; F66)
            Button(LocationAsk.turnOn) { LocationLine.openSettings() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text(LocationAsk.refused)
        }
        #else
        .onChange(of: model.tapped?.id) { _, _ in if let p = model.tapped?.point { detailsAt = p } }
        #endif
        .alert(model.missingWords.title, isPresented: $model.noOrganicMaps) {
            if let spot = model.missingSpot {  // never a dead end (task 2.3)
                Button {  // an alert's button keeps the system's look (PaletteTests lists the styled Show on map)
                    model.showSpot(longitude: spot.1, latitude: spot.0, zoom: 16)
                } label: { Text("Show on map") }
                Button { model.appleMaps(to: spot, travel: model.missingTravel) } label: { Text(AppleMaps.openInAppleMaps) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.missingWords.message)
        }
        #if os(iOS)
        .overlay {
            if model.printing {  // the map turns white for its picture: covered, so red night never flashes (W9 review)
                ZStack {
                    PrepareMeColors.ground.ignoresSafeArea()
                    Text(StreetMap.makingPDF).font(.pmBody).foregroundStyle(PrepareMeColors.ink)
                }
                .onAppear { UIAccessibility.post(notification: .announcement, argument: StreetMap.makingPDF) }
            }
        }
        .fileImporter(isPresented: $addingPins, allowedContentTypes: [.json]) { picked in
            if case .success(let url) = picked { notice = model.addPins(from: url) }
        }
        .background {  // a second file sheet on a view of its own: two on one view, SwiftUI shows only one
            Color.clear.fileExporter(isPresented: Binding(get: { pdf != nil }, set: { if !$0 { pdf = nil } }),
                                     document: pdf, contentType: .pdf, defaultFilename: "PrepareMe street map") { _ in }
        }
        .alert("Street map", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
        #endif
        .alert("No topo map here", isPresented: $noTopo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("None of the topo maps on this \(StreetMapWords.device) covers the middle of the map. Find a map lists "
                 + "what this \(StreetMapWords.device) has.")
        }
    }

    /// The search box's and the round buttons' words stop growing here (2026-11-12): at the largest sizes they ran over
    /// each other and the strip. The box's text and each button's spoken name are unchanged; the strip's text isn't capped.
    static let controlsCap = DynamicTypeSize.accessibility1

    #if os(iOS)
    static let gap: CGFloat = 4  // each word already sits under its icon (the phase 11 look: a 6.3-inch phone's full strip)
    #else
    static let gap: CGFloat = 12
    #endif

    /// The round buttons, each with its word under it on the phone (Task 11.4; F26), in the map pins plan's order
    /// (2026-11-14): Find me, Add pin, Pins, Layers, Topo map, Red night. The Mac adds from its toolbar (phase 3).
    var buttons: some View {
        VStack(spacing: Self.gap) {
            findMe
            #if os(iOS)
            addPin
            #endif
            rallyList
            layers
            #if os(macOS)
            topo
            #endif
            redNightSwitch
        }
    }

    #if os(iOS)
    /// The buttons in the room above the strip: one column where it fits, else two (the owner's fix, 2026-10-19: with
    /// Red night added, a tall strip ran under the fifth button on a 6.3-inch phone), else one row, wrapping into two
    /// where the phone is narrow (an SE; B2-23), and only when even that doesn't fit, the column over the strip as
    /// before.
    func fittedButtons(width: CGFloat) -> some View {
        ViewThatFits(in: .vertical) {
            buttons
            HStack(alignment: .top, spacing: Self.gap * 2) {
                VStack(spacing: Self.gap) { layers; redNightSwitch }
                VStack(spacing: Self.gap) { findMe; addPin; rallyList }
            }
            // two rows on a narrow phone
            ButtonWrap(spacing: Self.gap, maxWidth: width) { findMe; addPin; rallyList; layers; redNightSwitch }
            buttons
        }
    }
    #endif

    @ViewBuilder var findMe: some View {
        if model.platform.locates {
            // while following, the arrow with its line (task 1.2); a tap stops it
            round(model.follow.on ? "location.north.line.fill" : "location.fill", "Find me", word: "Find me") {
                model.whereAmI()
            }
            .accessibilityValue(model.follow.on ? "Following you" : "")
        }
    }

    /// Its own view, compared by what it shows: built inside this body, it was rebuilt on every location fix, and an
    /// open menu on an iPhone redrew its rows about once a second (owner, family-2026-11-15; owner-checks section 65).
    var layers: some View {
        #if os(iOS)
        StreetMapLayers(model: model, showConditions: $showConditions, showOld: $showOld, showMarks: $showMarks,
                        noTopo: $noTopo, hiddenOld: model.hiddenOld, showPins: $showPins,
                        sharesPins: model.sharesPins, sharedPins: model.sharedPins, pins: model.pins,
                        printing: model.printing, addingPins: $addingPins, pdf: $pdf, notice: $notice)
            .equatable()
        #else
        StreetMapLayers(model: model, showConditions: $showConditions, showOld: $showOld, showMarks: $showMarks,
                        noTopo: $noTopo, hiddenOld: model.hiddenOld)
            .equatable()
        #endif
    }

    #if os(iOS)
    /// The add sheet at the phone's place (the map pins plan, Task 2.1: Layers' Add a pin where I am, moved out where it
    /// can be seen); a held finger still adds at the spot held.
    @ViewBuilder var addPin: some View {
        if model.platform.locates, !PrepareMeSample.shared.on {  // the sample changes nothing
            round("mappin.and.ellipse", PersonalPins.addWhereIAm, word: "Add pin") {
                if let here = model.here {
                    model.tapped = StreetMapTap(longitude: here.coordinate.longitude,
                                                latitude: here.coordinate.latitude, features: [], point: nil)
                } else if LocationAsk.whereAmI(model.locationStatus) == .wait {
                    notice = LocationAsk.finding
                } else {
                    model.whereAmI()  // the system's question, or the refusal and its way to Settings
                }
            }
        }
    }
    #endif

    var topo: some View {
        round("map", "Topo map for here", word: "Topo map") { if !model.openTopo() { noTopo = true } }
    }

    /// Shared pins show with the rest of the Map Marks; a phone's own from before, by their own switch.
    private var pinsOn: Bool {
        #if os(macOS)
        showMarks
        #else
        model.sharesPins ? showMarks : showPins
        #endif
    }

    var rallyList: some View {
        round("list.bullet", "Pins", word: "Pins") { model.listing.toggle() }
    }

    var redNightSwitch: some View {
        round(redNight.on ? "moon.fill" : "moon", PrepareMeRedNight.title, word: "Red night screen") {
            redNight.on.toggle()
        }
            .accessibilityValue(redNight.on ? "On" : "Off")  // phase D: the map's own switch, beside the rest
            .accessibilityAddTraits(.isToggle)  // announced as a switch (spec section 8, fix 11)
    }

    #if os(macOS)
    /// A click's details point at the click (the page says where), else at the middle of the map. The last click's
    /// place is kept while the popover closes, so it doesn't jump to the middle on its way out (fix round 1).
    var tapAnchor: PopoverAttachmentAnchor {
        guard let p = model.tapped?.point ?? detailsAt else { return .rect(.bounds) }
        return .rect(.rect(CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)))
    }
    #endif

    var search: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(PrepareMeColors.text2)
                TextField("Find a place", text: $query)
                    #if os(macOS)
                    .textFieldStyle(.plain)  // inside the rounded panel, as on the phone: no box of its own
                    .help("Find a place")
                    #endif
                    .focused($searching)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(PrepareMeColors.text2) }
                        .accessibilityLabel("Clear")
                    #if os(macOS)
                        .buttonStyle(.plain)
                        .help("Clear")
                    #else
                        // a 44-point tap that keeps the box its height (Apple's Accessibility page; guidelines plan, 4)
                        .frame(width: 44, height: 44).contentShape(Rectangle()).padding(.vertical, -12)
                    #endif
                }
            }
            .padding(10)
            .pmGlass(in: RoundedRectangle(cornerRadius: 12))
            .dynamicTypeSize(...StreetMapFullView.controlsCap)
            if searching, !query.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    if model.placesLoading {
                        Text("Getting the place names ready…").foregroundStyle(PrepareMeColors.text2).padding(10)
                    } else if model.places == nil {
                        Text("This map file has no place list yet.").foregroundStyle(PrepareMeColors.text2).padding(10)
                    } else if found.isEmpty, foundFor == query {
                        Text("No place by that name.").foregroundStyle(PrepareMeColors.text2).padding(10)
                    }
                    ForEach(Array(found.prefix(8).enumerated()), id: \.offset) { _, place in
                        HStack {  // side by side, never one inside the other: a tap does one thing
                            Button {
                                model.go(to: place)
                                query = ""
                                searching = false
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(place.title)
                                    Text(StreetMapWords.found(place, from: model.here?.coordinate))
                                        .font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if model.platform.directions {
                                StreetMapDirections(model: model, to: (place.latitude, place.longitude),
                                                    name: place.title)
                                    .equatable()
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.trailing, 56)  // the round buttons' column
        .task(id: "\(model.placesLoading) \(query)") {  // after typing stops, off the screen's thread; again once loaded
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let results = await model.find(query)
            if !Task.isCancelled { (found, foundFor) = (results, query) }
        }
    }

    func round(_ symbol: String, _ label: String, word: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Self.circle(symbol, label, word: word) }
        #if os(macOS)
            .buttonStyle(.plain)  // a Mac button is a bordered push button otherwise, around the circle
            .help(label)  // the pointer's hint, the same words as the accessibility label (fix round 1)
        #endif
    }

    /// A round map button; on the phone with its word under it (Task 11.4; F26; owner, 2026-10-18, by click), the Mac
    /// keeping the circle alone with the pointer's hint.
    static func circle(_ symbol: String, _ label: String, word: String) -> some View {
        #if os(iOS)
        let name = SpokenName.of(label, word: word)  // the word under it is in its spoken name (spec section 8, fix 10)
        #else
        let name: (label: String, hint: String?) = (label, nil)  // the Mac shows no word
        #endif
        return VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.pmTitle)
                .frame(width: 44, height: 44)
                .pmGlass(in: Circle())
            #if os(iOS)
            Text(word)
                .font(.pmNote)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .pmGlass(in: Capsule())
            #endif
        }
        .dynamicTypeSize(...Self.controlsCap)  // its icon too: at the largest sizes it spilled out of its circle
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name.label)
        .accessibilityHint(name.hint ?? "")
    }
}

/// The street map's Layers menu (StreetMapFullView.layers). Not an observer of the model: SwiftUI rebuilds it only when
/// == says what it shows has changed, never for a location fix alone.
struct StreetMapLayers: View, Equatable {
    let model: StreetMapModel
    @Binding var showConditions: Bool
    @Binding var showOld: Bool
    @Binding var showMarks: Bool
    @Binding var noTopo: Bool
    let hiddenOld: Int
    #if os(iOS)
    @Binding var showPins: Bool
    let sharesPins: Bool
    let sharedPins: [MapMark]
    let pins: PersonalPins
    let printing: Bool
    @Binding var addingPins: Bool
    @Binding var pdf: StreetMapPDF?
    @Binding var notice: String?
    #endif

    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated {
            var same = a.model === b.model && a.hiddenOld == b.hiddenOld && a.showConditions == b.showConditions
                && a.showOld == b.showOld && a.showMarks == b.showMarks
            #if os(iOS)
            same = same && a.showPins == b.showPins && a.sharesPins == b.sharesPins && a.sharedPins == b.sharedPins
                && a.pins == b.pins && a.printing == b.printing
            #endif
            return same
        }
    }

    var body: some View {
        Menu {
            Toggle(StreetMapWords.conditionsLayer, isOn: $showConditions).pmSwitch()
            Toggle(hiddenOld > 0 ? "Show old conditions (\(hiddenOld) over 3 days old)"
                                 : "Show old conditions", isOn: $showOld).pmSwitch()
            // one switch for the group, the shared pins with it (owner, 2026-11-12, by click: "Map Marks")
            Toggle("Pins and Routes", isOn: $showMarks).pmSwitch()
            #if os(iOS)
            // a phone's own pins keep their switch until the Mac shares them (the shared marks plan, phase 3)
            if !sharesPins { Toggle("My pins", isOn: $showPins).pmSwitch() }
            // six round buttons ran over the opened strip on the smallest phone: Topo map moved here (the map pins
            // plan, Task 2.1, step 3; docs/streetmap.md)
            Button("Topo Map for Here", systemImage: "map") { if !model.openTopo() { noTopo = true } }
            Section {  // the street map fixes plan, tasks 4.1 and 4.2; Add a pin where I am is the Add pin button now
                if sharesPins {  // the shared pins, for a phone away from home with you (they go by the Mac too)
                    if !sharedPins.isEmpty {
                        ShareLink(item: SharedPinsTransfer(pins: sharedPins), preview: SharePreview("Pins")) {
                            Label("Share pins", systemImage: "square.and.arrow.up")
                        }
                    }
                } else if !pins.pins.isEmpty {
                    ShareLink(item: PinsFile(pins: pins), preview: SharePreview("My pins")) {
                        Label("Share my pins", systemImage: "square.and.arrow.up")
                    }
                }
                if !PrepareMeSample.shared.on {  // the sample changes nothing
                    Button("Add pins from a file", systemImage: "square.and.arrow.down") { addingPins = true }
                }
                Button("Save as PDF", systemImage: "doc.richtext") {
                    Task {
                        if let data = await model.pdfOfView() { pdf = StreetMapPDF(data: data) }
                        else { notice = StreetMap.pdfNotReady }
                    }
                }
                .disabled(printing)
            }
            #endif
        } label: { StreetMapFullView.circle("square.3.layers.3d", "Layers", word: "Layers") }
        #if os(macOS)
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()  // the round look, as the rest
        .help("Layers")  // the pointer's hint: an icon alone says little on a Mac
        #endif
    }
}

/// The Pins list (the map pins plan, Task 2.4; the plan's accessible list too: map labels aren't read aloud): Meeting
/// places, Other pins and Routes, each hidden when empty. A row is its picture, its name, one gray line and how far; a
/// tap closes the list and opens its card over the map, a held finger its More menu. Select ticks several to share or,
/// on an adult's phone, delete.
struct StreetMapMarksList: View {
    @ObservedObject var model: StreetMapModel
    @Environment(\.dismiss) private var dismiss
    @State private var selecting = false
    @State private var ticked: Set<Int64> = []
    @State private var askDelete = false
    @State private var ask: MapMarkAsk?  // a held finger's Edit… or Delete…
    @Environment(\.dynamicTypeSize) private var textSize
    /// Select's Delete, an adult's phone only (owner, 2026-11-12, by click): a child's phone keeps Select for sharing
    #if os(iOS)
    private var mayDelete: Bool { PhoneInventoryModel.shared.mayEdit }
    #else
    private let mayDelete = false
    #endif

    var body: some View {
        let groups = Position.pinGroups(marks: model.marks, pins: model.sharedPins,
                                        here: model.here.map { ($0.coordinate.latitude, $0.coordinate.longitude) })
        let all = groups.meeting + groups.pins + groups.routes
        NavigationStack {
            PMList {
                if all.isEmpty {
                    Text("No pins or routes yet. Press and hold the map to add a pin. Routes are drawn on the Mac's "
                         + "street map.")
                        .foregroundStyle(PrepareMeColors.text2)
                }
                if selecting {
                    Text(mayDelete ? MapMarkWords.pickToShareOrDelete : "Tick the pins to share, then Share.")
                        .foregroundStyle(PrepareMeColors.text2)
                }
                group("Meeting places", groups.meeting)
                group("Other pins", groups.pins)
                group("Routes", groups.routes)
            }
            .mapMarkAsk($ask)
            .pmBar(.bottom) {  // Share, in words with how many: a toolbar shows only its icon
                if selecting {
                    let chosen = OrganicMaps.picked(model.marks + model.sharedPins, ticked)
                    VStack {
                        OrganicMapsShare(marks: chosen, picked: chosen.count).pmAction()
                        OrganicMapsShare(marks: chosen, picked: chosen.count, gpx: true).pmAction()
                        if mayDelete {  // everywhere, through the Mac, asked first
                            Button(MapMarkWords.deleteButton(chosen.count), systemImage: "trash", role: .destructive) {
                                askDelete = true
                            }
                            .pmAction()
                            .disabled(chosen.isEmpty)
                            .confirmationDialog(MapMarkWords.deleteQuestion(chosen.count), isPresented: $askDelete,
                                                titleVisibility: .visible) {
                                Button("Delete", role: .destructive) { delete(chosen) }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text(MapMarkWords.deleteWhy)
                            }
                        }
                    }
                    .padding(.horizontal).padding(.vertical, 8)
                }
            }
            .navigationTitle("Pins")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if selecting {
                    ToolbarItem(placement: .navigation) {
                        Button("Cancel") {
                            selecting = false
                            ticked = []
                        }
                    }
                    ToolbarItem(placement: .primaryAction) { Button("Select All") { ticked = Set(all.map(\.id)) } }
                } else {
                    if !all.isEmpty {
                        ToolbarItem(placement: .primaryAction) { Button("Select") { selecting = true } }
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
        }
    }

    @ViewBuilder func group(_ title: String, _ marks: [MapMark]) -> some View {
        if !marks.isEmpty {
            Section(pmTitle: title) {
                ForEach(marks) { row($0) }
            }
        }
    }

    func row(_ mark: MapMark) -> some View {
        let line = MapMarkWords.rowLine(mark, waiting: mark.id < 0, kidsTarget: mark.id == model.kidsTarget,
                                        added: MapPinCard.added(mark))
        let way = model.way(to: mark)
        return HStack(spacing: 12) {
            if selecting { MarkTick(name: mark.name, on: ticked.contains(mark.id)) { toggle(mark.id) } }
            MapPinPicture(mark: mark)
            VStack(alignment: .leading, spacing: 2) {
                Text(mark.name).font(.pmHeadline)
                if let line { Text(line).font(.pmNote).foregroundStyle(PrepareMeColors.text2) }
                // under the name at the accessibility sizes: beside it, it squeezed names to a few letters a line
                if textSize.isAccessibilitySize, let way {
                    Text(Position.distance(way.meters)).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                }
            }
            Spacer(minLength: 0)
            if !textSize.isAccessibilitySize, let way {
                Text(Position.distance(way.meters)).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if selecting { toggle(mark.id) } else { model.open(mark) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(selecting ? "" : "Opens it on the map")
        .contextMenu {  // a held finger: the card's More (the map pins plan, Task 2.4)
            if !selecting { MapMarkActions(model: model, mark: mark, ask: $ask).equatable() }
        } preview: {
            Label { Text(mark.name) } icon: { MapPinPicture(mark: mark) }.font(.pmHeadline).padding()
        }
    }

    func toggle(_ id: Int64) {
        if ticked.contains(id) { ticked.remove(id) } else { ticked.insert(id) }
    }

    /// Each one as the phone saw it, so the Mac refuses one it changed since; gone from this phone at once, from the
    /// Mac and every phone once the Mac has it (PhoneOutbox.view, PhoneRules).
    func delete(_ chosen: [MapMark]) {
        #if os(iOS)
        for mark in chosen {
            PhoneInventoryModel.shared.editMark(.removeMark(id: mark.id, expected: mark), what: MapMarkWords.deleted(mark.name))
        }
        #endif
        selecting = false
        ticked = []
    }
}

/// Every rally point and route as one file Organic Maps imports and keeps offline (step 6, part 3): "Import with
/// Organic Maps" in the share sheet. Exact places leave PrepareMe only when someone shares it and picks where, as with
/// Share this spot. The file is written when the share sheet asks for it (MarksFile), into this device's temporary
/// folder, replacing any earlier one.
struct OrganicMapsShare: View {
    let marks: [MapMark]
    /// How many were picked in Select (shown in its words), or nil for every mark.
    var picked: Int? = nil
    /// The same marks as GPX, for map apps that don't take KML (the street map fixes plan, task 3.5).
    var gpx = false

    var body: some View {
        if !marks.isEmpty {
            Group {  // two types, not one with a switch: the share sheet wrote KML for a GPX one (exportingCondition)
                if gpx {
                    ShareLink(item: MarksGPXFile(marks: marks), preview: SharePreview("Pins and Routes")) {
                        Label(OrganicMaps.shareWords(count: picked, gpx: true), systemImage: "square.and.arrow.up")
                    }
                } else {
                    ShareLink(item: MarksFile(marks: marks), preview: SharePreview("Pins and Routes")) {
                        Label(OrganicMaps.shareWords(count: picked), systemImage: "square.and.arrow.up")
                    }
                }
            }
            .help((picked != nil ? "The ones ticked" : marks.count == 1 ? "This one" : "Every meeting place and route")
                  + " as one file "
                  + (gpx ? "most map apps open" : "Organic Maps opens offline")
                  + "; the exact places go only where you send it")
        } else if picked != nil {  // Select with nothing ticked yet
            Button {} label: { Label(OrganicMaps.shareWords(count: 0, gpx: gpx), systemImage: "square.and.arrow.up") }
                .disabled(true)
        }
    }
}

#if os(iOS)
/// A phone's pins as the file Share my pins sends (task 4.1), written when the share asks for it: kinds, places and
/// times only. The other phone saves it to Files and adds it with Add pins from a file.
struct SharedPinsTransfer: Transferable {
    let pins: [MapMark]  // the shared pins, as the same file (SharedPinsFile, its version 2)

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType(exportedAs: AppCopy.pinsType, conformingTo: .json)) { file in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PrepareMe pins", isDirectory: true)
            let url = folder.appendingPathComponent(PersonalPins.sharedFileName)
            try? FileManager.default.removeItem(at: folder)  // no older copy lingers
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try SharedPinsFile.encode(file.pins).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

struct PinsFile: Transferable {
    let pins: PersonalPins

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType(exportedAs: AppCopy.pinsType, conformingTo: .json)) { file in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PrepareMe pins", isDirectory: true)
            let url = folder.appendingPathComponent(PersonalPins.sharedFileName)
            try? FileManager.default.removeItem(at: folder)  // no older copy lingers
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try file.pins.shared().write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

/// Save as PDF's file, for the Files sheet (task 4.2).
struct StreetMapPDF: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
#endif

/// Select in a rally points list (the owner's choice, 2026-10-19: "Pick several, then share"): a tick before each
/// rally point and route, tapped to pick it: a checkbox to VoiceOver, named for its point (spec section 8, fix 13).
struct MarkTick: View {
    let name: String
    let on: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.pmTitle)
                .foregroundStyle(on ? PrepareMeColors.ink : PrepareMeColors.text2)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(name)
        .accessibilityValue(on ? "Picked" : "Not picked")
        .accessibilityAddTraits(.isToggle)
    }
}

/// The marks as the KML file a share hands over, written when the share asks for it.
struct MarksFile: Transferable {
    let marks: [MapMark]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType(importedAs: OrganicMaps.kmlType, conformingTo: .xml)) { file in
            guard let url = OrganicMaps.file(file.marks) else { throw CocoaError(.fileWriteUnknown) }
            return SentTransferredFile(url)
        }
    }
}

/// The same as GPX (task 3.5).
struct MarksGPXFile: Transferable {
    let marks: [MapMark]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType(importedAs: OrganicMaps.gpxType, conformingTo: .xml)) { file in
            guard let url = OrganicMaps.gpxFile(file.marks) else { throw CocoaError(.fileWriteUnknown) }
            return SentTransferredFile(url)
        }
    }
}

/// Drive and Walk, as one small menu, each opening Organic Maps or Apple Maps with the route asked for (hand-off plan,
/// 3.1: a menu under each, so the strip's row stays one row).
/// Not an observer of the model, and compared by where it goes, as every menu on the map: a menu rebuilt on each location
/// fix redrew its open rows about once a second on an iPhone (owner, family-2026-11-15; StreetMapLayers).
struct StreetMapDirections: View, Equatable {
    let model: StreetMapModel
    let to: (Double, Double)  // latitude, longitude
    let name: String

    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated { a.model === b.model && a.to == b.to && a.name == b.name }
    }

    var body: some View {
        Menu {
            Menu("Drive there", systemImage: "car.fill") { StreetMapWays(model: model, to: to, name: name, travel: .drive) }
            Menu("Walk there", systemImage: "figure.walk") { StreetMapWays(model: model, to: to, name: name, travel: .walk) }
        } label: {
            Image(systemName: "arrow.triangle.turn.up.right.circle.fill").font(.pmTitle)
                .frame(minWidth: 44, minHeight: 44)  // a tap target of 44 points (F64)
                .contentShape(Rectangle())
        }
        #if os(macOS)
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()  // the icon alone, as on the phone
        .help("Directions in Organic Maps or Apple Maps")
        #endif
        .accessibilityLabel("Directions to \(name) in Organic Maps or Apple Maps")
    }
}

/// Drive and Walk as two buttons, in a spot's details, each a menu of the two apps.
struct StreetMapDirectionsRow: View, Equatable {
    /// The card's buttons stop growing here, where "Drive there" and its car still fit on one line (2026-11-12).
    static let cap = DynamicTypeSize.accessibility3

    let model: StreetMapModel  // not observed, as StreetMapDirections
    let to: (Double, Double)
    let name: String

    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated { a.model === b.model && a.to == b.to && a.name == b.name }
    }
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        // one above the other at the accessibility sizes, and no bigger than one line holds: "Drive there" broke
        // mid-word side by side, and alone at the largest size still did (owner, 2026-11-12)
        let row = size.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
        row {
            Menu("Drive there", systemImage: "car.fill") { StreetMapWays(model: model, to: to, name: name, travel: .drive) }
            Menu("Walk there", systemImage: "figure.walk") { StreetMapWays(model: model, to: to, name: name, travel: .walk) }
        }
        .pmAction()
        .dynamicTypeSize(...Self.cap)
        .padding(.top, 4)
    }
}

/// In Organic Maps and In Apple Maps, under Drive there or Walk there (owner, 2026-10-30: both, always).
struct StreetMapWays: View {
    let model: StreetMapModel  // not observed: it sits in menus (StreetMapDirections)
    let to: (Double, Double)
    let name: String
    let travel: OrganicMaps.Travel

    var body: some View {
        let how = travel == .drive ? "Drive" : "Walk"
        Button(AppleMaps.inOrganicMaps) { model.directions(to: to, name: name, travel: travel) }
            .accessibilityLabel("\(how) to \(name) in Organic Maps")
        Button(AppleMaps.inAppleMaps) { model.appleMaps(to: to, travel: travel) }
            .accessibilityLabel("\(how) to \(name) in Apple Maps")
    }
}

/// Drive and Walk, one tap each, straight to Organic Maps (the map pins plan, Task 2.2; spec: Apple Maps moves under
/// More). Organic Maps missing shows today's message, with Show on map and Open in Apple Maps: never a dead end.
struct StreetMapGo: View {
    @ObservedObject var model: StreetMapModel
    let to: (Double, Double)  // latitude, longitude
    let name: String
    /// The strip's: the regular size, so two rows of them leave the map room (the map pins plan, Task 2.1's pictures)
    var compact = false
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        // one above the other at the accessibility sizes, as Drive there and Walk there were (owner, 2026-11-12)
        let row = size.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
        row {
            Button("Drive", systemImage: "car.fill") { model.directions(to: to, name: name, travel: .drive) }
                .accessibilityLabel("Drive to \(name)")
            Button("Walk", systemImage: "figure.walk") { model.directions(to: to, name: name, travel: .walk) }
                .accessibilityLabel("Walk to \(name)")
        }
        .pmAction(compact: compact)
        .dynamicTypeSize(...StreetMapDirectionsRow.cap)
    }
}

/// Apple Maps' two ways, for a pin's More menu (the map pins plan, Task 2.2). The place is worked out on the tap (a
/// route's nearest point moves as you do), so the menu needn't be rebuilt on each fix (MapMarkActions).
struct AppleMapsItems: View {
    let model: StreetMapModel  // not observed: it sits in menus
    let mark: MapMark

    var body: some View {
        if model.goSpot(mark) != nil {
            Button(AppleMaps.driveInAppleMaps, systemImage: "car") { go(.drive) }
            Button(AppleMaps.walkInAppleMaps, systemImage: "figure.walk") { go(.walk) }
        }
    }

    func go(_ travel: OrganicMaps.Travel) {
        if let to = model.goSpot(mark) { model.appleMaps(to: to, travel: travel) }
    }
}

/// How far to trust the position: its accuracy, and its age once over a minute, kept current while on screen.
struct StreetMapFixLine: View {
    let here: CLLocation

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(Position.fix(accuracy: here.horizontalAccuracy, taken: here.timestamp, now: context.date))
        }
    }
}

#if PREPAREME_CHECK || targetEnvironment(simulator)
extension StreetMapFullView {
    /// A check that can't tap the map: PREPAREME_CHECK_PART=marktap opens the first rally point's details (2026-11-12).
    func checkMarkTap() async {
        let part = ProcessInfo.processInfo.environment["PREPAREME_CHECK_PART"] ?? ""
        #if os(iOS)
        await checkPins(part)
        #endif
        guard part == "marktap" else { return }
        try? await Task.sleep(for: .seconds(4))
        if let mark = model.marks.first(where: { $0.kind == .rally }), let at = mark.points.first {
            model.tapped = StreetMapTap(longitude: at[0], latitude: at[1], features: [[
                "layer": "pm-rally", "id": NSNumber(value: mark.id), "kind": mark.kind.rawValue, "name": mark.name,
                "note": mark.note, "at": at]], point: nil)
        }
    }

    #if os(iOS)
    /// The shared pins' simulator checks (the shared marks plan, phase 3; screenshots, no taps), once the Mac's copy
    /// has come: `spot` holds a finger on the map (the add sheet), `list` opens the list, `pintap` taps the first
    /// shared pin, `addpin` adds a ready-made pin as the sheet's button does, `removepin` removes the first pin this
    /// phone may (a child's: its own), `ownpins` gives the phone two pins of its own from before, for the question.
    func checkPins(_ part: String) async {
        guard ["spot", "list", "pintap", "addpin", "removepin", "ownpins"].contains(part) else { return }
        if part == "ownpins" {
            model.addPin(.water, longitude: -48.16, latitude: 15.02)
            model.addPin(.meet, longitude: -48.15, latitude: 15.03)
        }
        try? await Task.sleep(for: .seconds(14))
        let at = model.marks.first?.points.first ?? [-48.16, 15.02]
        switch part {
        case "spot":
            model.tapped = StreetMapTap(longitude: at[0] + 0.004, latitude: at[1] + 0.004, features: [], point: nil,
                                        longPress: true)
        case "list":
            model.listing = true
        case "pintap":
            if let pin = model.sharedPins.first, let p = pin.points.first {
                model.tapped = StreetMapTap(longitude: p[0], latitude: p[1], features: [[
                    "layer": "pm-pin", "shared": true, "pin": pin.uid ?? "", "at": p]], point: nil)
            }
        case "addpin":
            if let look = PinLook.readyMade.first(where: { $0.name == "Car parked" }) {
                model.addShared(MapMark.pin(look, longitude: at[0] - 0.006, latitude: at[1] + 0.006))
            }
            model.listing = true
        case "removepin":
            if let pin = model.sharedPins.first(where: { MapMarkAsk.mayDelete($0) }) {
                PhoneInventoryModel.shared.editMark(.removeMark(id: pin.id, expected: pin), what: MapMarkWords.deleted(pin.name))
            }
            model.listing = true
        default:
            break
        }
    }
    #endif
}
#endif

// MARK: A tap on the map

struct StreetMapTap: Identifiable {
    let id = UUID()
    let longitude: Double
    let latitude: Double
    let features: [[String: Any]]
    let point: CGPoint?  // where in the map's view, in points from its top left
    var longPress = false  // a held finger, a held trackpad click on the iPad, or the Mac's right-click (task 5.1)
}

#if os(macOS)
/// A click on a road event, river gauge, pin, meeting place or route on the Mac: what it is, in a popover at the click
/// (part 3). No storm outlines (they come from a phone's own alerts), so an empty spot shows nothing.
struct StreetMapDetails: View {
    @ObservedObject var model: StreetMapModel
    let tap: StreetMapTap

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(tap.features.enumerated()), id: \.offset) { index, feature in
                if index > 0 { Divider() }
                StreetMapFeatureRow(model: model, feature: feature, tap: (tap.latitude, tap.longitude),
                                    close: { model.tapped = nil })
            }
            // the right-click's own action (task 5.1), as Add pin then a click; none on a pin, as the phone's
            if tap.longPress, StreetMap.offersAdding(layers: tap.features.compactMap { $0["layer"] as? String },
                                                     longPress: true) {
                if !tap.features.isEmpty { Divider() }
                Button("Add pin here") {
                    model.tapped = nil
                    model.mode = .browse
                    model.naming = MapMarkDraft(mark: MapMark(kind: .pin, name: "", points: [[tap.longitude, tap.latitude]]))
                }
                .pmAction()  // its sheet's Kind makes a meeting place; the Start is the Map menu's (map pins plan, 3.1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 300, alignment: .leading)
        .padding()
    }
}
#endif

struct StreetMapTapSheet: View {
    @ObservedObject var model: StreetMapModel
    let tap: StreetMapTap
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @State private var making: NewMark?  // Make your own, or Add a rally point here (an adult's phone)
    private var sampleOpen: Bool { PrepareMeSample.shared.on }  // the sample changes nothing
    #else
    private let sampleOpen = false
    #endif

    var body: some View {
        // adding on an empty spot, or a held finger on a warning, road or route; a pin shows its card alone (2.5)
        let offers = StreetMap.offersAdding(layers: tap.features.compactMap { $0["layer"] as? String },
                                            longPress: tap.longPress)
        let adding = offers && !sampleOpen
        NavigationStack {
            PMList {
                ForEach(Array(tap.features.enumerated()), id: \.offset) { _, feature in
                    StreetMapFeatureRow(model: model, feature: feature, tap: (tap.latitude, tap.longitude),
                                        close: { dismiss() })
                }
                if offers && sampleOpen {  // never an empty card
                    #if os(iOS)
                    Text(SampleLibrary.noPins).foregroundStyle(PrepareMeColors.text2)
                    #endif
                }
                if adding {
                    #if os(iOS)
                    if model.sharesPins { shared } else { own }
                    #else
                    own
                    #endif
                }
            }
            .navigationTitle(adding ? MapMarkWords.addPinHere : "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $making) { new in
                MarkForm(new: new) { mark in
                    making = nil
                    guard let mark else { return }
                    model.addShared(mark)
                    dismiss()
                }
            }
            #endif
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    #if os(iOS)
    /// The shared pins (the shared marks plan, phase 3; the map pins plan, Task 2.5): Meeting place first on an adult's
    /// phone, then Ready-made, then Yours (looks already on the map, and Make your own… on an adult's phone). A child's
    /// phone picks a look, never types.
    @ViewBuilder private var shared: some View {
        if MapMarkAsk.mayChange {  // a meeting place is no pin in the store: the 500 marks limit is the Mac's to say
            Section {
                Button {
                    making = NewMark(kind: .rally, at: [tap.longitude, tap.latitude], role: Position.newRallyRole(model.marks))
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(MapMarkWords.meetingPlace)
                            Text(MapMarkWords.meetingPlaceWhy).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                        }
                    } icon: { StreetMapPinIcon(symbol: "flag.fill", color: "ok-mark") }
                }
            }
        }
        if model.sharedPins.count >= MapMark.pinLimit {
            Section { Text(MapMarkWords.pinsFull) }
        } else {
            Section(pmTitle: "Ready-made") {
                ForEach(PinLook.readyMade, id: \.self) { look($0) }
            }
            let yours = PinLook.offered(model.sharedPins).filter { !PinLook.readyMade.contains($0) }
            if !yours.isEmpty || MapMarkAsk.mayChange {
                Section(pmTitle: "Yours") {
                    ForEach(yours, id: \.self) { look($0) }
                    if MapMarkAsk.mayChange {
                        Button(MapMarkWords.makeYourOwn, systemImage: "pencil") {
                            making = NewMark(kind: .pin, at: [tap.longitude, tap.latitude], role: nil)
                        }
                    }
                }
            }
        }
        Section {
            Text(MapMarkWords.pinsShared).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
        }
    }

    private func look(_ look: PinLook) -> some View {
        Button {
            model.addShared(MapMark.pin(look, longitude: tap.longitude, latitude: tap.latitude))
            dismiss()
        } label: {
            Label { Text(look.name) } icon: { StreetMapPinIcon(symbol: look.symbol, color: look.color) }
        }
    }
    #endif

    /// A phone's own pins, as before pins were shared: while it isn't paired, or its Mac doesn't share them yet.
    @ViewBuilder private var own: some View {
                Section(pmTitle: "Add one of your own pins here") {
                    if model.pinsFull {  // task 3.3: said, in place of kinds that would do nothing
                        Text(PersonalPins.fullWords(device: StreetMapWords.device))
                    } else {
                        ForEach(PersonalPins.Label.allCases, id: \.self) { label in
                            Button {
                                model.addPin(label, longitude: tap.longitude, latitude: tap.latitude)
                                dismiss()
                            } label: {
                                Label { Text(label.rawValue) } icon: { StreetMapPinIcon(label: label) }
                            }
                        }
                    }
                }
                Section {
                    Text("Your pins stay on this \(StreetMapWords.device) only.").font(.pmNote)
                        .foregroundStyle(PrepareMeColors.text2)
                }
    }
}

#if os(iOS)
/// A pin of your own or a rally point, to be named (the shared marks plan, phase 3): what it is and where.
struct NewMark: Identifiable {
    let id = UUID()
    let kind: MapMark.Kind
    let at: [Double]  // longitude, latitude
    let role: MapMark.Role?  // a first rally point starts as Near home (Position.newRallyRole)
}

/// Its name, note and, for a pin, its look, for a meeting place which one (a route: its role), on an adult's phone:
/// the same form adds and edits (the map pins plan, Task 2.3). The Mac checks the name and note when it takes it.
struct MarkForm: View {
    var new: NewMark? = nil
    var editing: MapMark? = nil
    let done: (MapMark?) -> Void  // as named or changed, or nil for Cancel
    @State private var name: String
    @State private var note: String
    @State private var symbol: String
    @State private var color: String
    @State private var role: MapMark.Role?
    @State private var routeRole: MapMark.RouteRole?

    init(new: NewMark? = nil, editing: MapMark? = nil, done: @escaping (MapMark?) -> Void) {
        (self.new, self.editing, self.done) = (new, editing, done)
        _name = State(initialValue: editing?.name ?? "")
        _note = State(initialValue: editing?.note ?? "")
        _symbol = State(initialValue: editing?.pinSymbol ?? "mappin")
        _color = State(initialValue: editing?.pinColor ?? "accent")
        _role = State(initialValue: editing.map(\.role) ?? new?.role)
        _routeRole = State(initialValue: editing?.routeRole)
    }

    private var kind: MapMark.Kind { editing?.kind ?? new?.kind ?? .pin }

    var body: some View {
        NavigationStack {
            PMForm {
                TextField("Name", text: $name)
                TextField("Note (optional)", text: $note, axis: .vertical)
                switch kind {
                case .pin:
                    PinLookFields(symbol: $symbol, color: $color)
                case .rally:
                    Picker(MapMarkWords.whichOne, selection: $role) {
                        Text(MapMarkWords.anotherPlace).tag(MapMark.Role?.none)
                        ForEach(MapMark.Role.allCases, id: \.self) { Text($0.words).tag(MapMark.Role?.some($0)) }
                    }
                    Text(Position.kidsPointTo).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                case .route:  // a route keeps its Role picker (the plan: Role and No role stay on a route's)
                    Picker("Role", selection: $routeRole) {
                        Text("No role").tag(MapMark.RouteRole?.none)
                        ForEach(MapMark.RouteRole.allCases, id: \.self) { Text($0.words).tag(MapMark.RouteRole?.some($0)) }
                    }
                case .start:
                    EmptyView()
                }
                Section {
                    Text(editing != nil ? MapMarkWords.editWhy : kind == .pin ? MapMarkWords.pinsShared : MapMarkWords.rallyShared)
                        .font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { done(result) }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var title: String {
        let word = kind == .pin ? "pin" : kind == .rally ? "meeting place" : "route"
        return (editing == nil ? "New " : "Edit ") + word
    }

    private var result: MapMark? {
        let typed = name.trimmingCharacters(in: .whitespaces)
        if var changed = editing {
            changed.name = typed
            changed.note = note
            switch kind {
            case .pin: (changed.pinSymbol, changed.pinColor) = (symbol, color)
            case .rally: changed.role = role
            case .route: changed.routeRole = routeRole
            case .start: break
            }
            return changed
        }
        guard let new else { return nil }
        if new.kind == .pin {
            var pin = MapMark.pin(PinLook(name: typed, symbol: symbol, color: color), longitude: new.at[0], latitude: new.at[1])
            pin.note = note
            return pin
        }
        return MapMark(kind: .rally, name: typed, note: note, points: [new.at], role: role,
                       uid: UUID().uuidString.lowercased())
    }
}
#endif

/// A pin kind's symbol on its color (task 3.2), as the map draws it.
struct StreetMapPinIcon: View {
    let symbol: String
    let color: String  // one of BASE's color roles (PinLook.colors)

    init(label: PersonalPins.Label) {
        (symbol, color) = (label.symbol, label.color)
    }

    /// A shared pin's own look (the shared marks plan).
    init(_ pin: MapMark) {
        (symbol, color) = (pin.pinSymbol ?? "mappin", pin.pinColor ?? "accent")
    }

    init(symbol: String, color: String) {
        (self.symbol, self.color) = (symbol, color)
    }

    var body: some View {
        Image(systemName: symbol).font(.system(size: 15, weight: .bold)).foregroundStyle(PrepareMeColors.onFill)
            .frame(width: 30, height: 30)
            .background(Circle().fill(PrepareMeColors.mapMark(color)))
            .accessibilityHidden(true)
    }
}

/// A pin's symbol and color, each a pick from PinLook's fixed sets with its word (the shared marks plan): the color
/// alone never says what it means, and VoiceOver reads the word.
struct PinLookFields: View {
    @Binding var symbol: String
    @Binding var color: String

    var body: some View {
        Picker("Symbol", selection: $symbol) {
            ForEach(PinLook.symbolWords, id: \.0) { Label($0.1, systemImage: $0.0).tag($0.0) }
        }
        Picker("Color", selection: $color) {
            ForEach(PinLook.colorWords, id: \.0) { Text($0.1).tag($0.0) }
        }
    }
}

struct StreetMapFeatureRow: View {
    @ObservedObject var model: StreetMapModel
    let feature: [String: Any]
    let tap: (Double, Double)  // latitude, longitude of the tap
    let close: () -> Void
    @State private var askRemove = false

    /// The feature's own point (a rally point's, a pin's), else where it was tapped (on a route's line).
    var spot: (Double, Double) {
        if let at = feature["at"] as? [Double], at.count == 2 { return (at[1], at[0]) }
        return tap
    }

    var body: some View {
        let layer = feature["layer"] as? String ?? ""
        VStack(alignment: .leading, spacing: 4) {
            switch layer {
            case "pm-rally", "pm-route", "pm-start":  // one card for every mark (the map pins plan, Task 2.3)
                if let id = (feature["id"] as? NSNumber)?.int64Value, let mark = model.marks.first(where: { $0.id == id }) {
                    MapPinCard(model: model, mark: mark, close: close)
                } else {  // gone since the map drew it
                    Text(feature["name"] as? String ?? "").font(.pmHeadline)
                }
            case "pm-pin" where feature["shared"] as? Bool == true:  // a shared pin, found by uid: one waiting too
                if let pin = model.sharedPins.first(where: { $0.uid == feature["pin"] as? String }) {
                    MapPinCard(model: model, mark: pin, close: close)
                }
            case "pm-pin":
                let kind = PersonalPins.Label(rawValue: feature["label"] as? String ?? "") ?? .other
                Label { Text(kind.rawValue) } icon: { StreetMapPinIcon(label: kind) }.font(.pmHeadline)
                if model.platform.directions {
                    StreetMapDirectionsRow(model: model, to: spot, name: kind.rawValue).equatable()
                }
                if let id = feature["pin"] as? String {
                    // below a divider, and asked first (task 3.1): a slip beside Drive there loses the pin
                    Divider().padding(.vertical, 4)
                    Button("Remove this pin", role: .destructive) { askRemove = true }
                        .confirmationDialog(PersonalPins.removeQuestion(kind), isPresented: $askRemove,
                                            titleVisibility: .visible) {
                            Button("Remove", role: .destructive) {
                                model.removePin(id)
                                close()
                            }
                            Button("Cancel", role: .cancel) {}
                        }
                }
            default:
                Text(feature["text"] as? String ?? "").font(.pmHeadline)
                if let detail = feature["detail"] as? String, !detail.isEmpty { Text(detail) }
                if let asOf = feature["as_of"] as? String {
                    Text(StreetMapWords.asOf(asOf, old: feature["old"] as? Bool ?? false))
                        .font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                }
            }
        }
    }
}

// MARK: One rally point's or route's own choices

/// An edit or a delete asked about first (owner, 2026-11-12, by click; Edit… is one form since the map pins plan).
enum MapMarkAsk: Identifiable {
    case edit(MapMark), delete(MapMark)

    var mark: MapMark {
        switch self { case .edit(let m), .delete(let m): m }
    }
    var id: String {
        switch self { case .edit(let m): "e\(m.id)" case .delete(let m): "d\(m.id)" }
    }
}

/// What one pin, meeting place or route can do from here: the card's More, and a held finger on a Pins list row (the
/// map pins plan, Task 2.3): Edit… (an adult's phone; the Mac edits in its list), Share, Apple Maps' two ways, then
/// Delete… in red below a line where this device may. The Start point is never shared (it is often the house).
/// A pin's More, on its card and on a held finger in the Pins list. Not an observer of the model, and compared by its
/// mark: rebuilt on each location fix, an open menu redrew its rows about once a second on an iPhone (owner,
/// family-2026-11-15; StreetMapLayers).
struct MapMarkActions: View, Equatable {
    let model: StreetMapModel
    let mark: MapMark
    @Binding var ask: MapMarkAsk?

    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated { a.model === b.model && a.mark == b.mark }
    }

    var body: some View {
        // menu words: title capitals and "…" for the box that follows (docs/design/menus.md)
        if MapMarkAsk.mayChange, mark.kind != .start {
            Button("Edit…", systemImage: "pencil") { ask = .edit(mark) }
        }
        if mark.kind != .start {
            Menu("Share", systemImage: "square.and.arrow.up") {
                OrganicMapsShare(marks: [mark])
                OrganicMapsShare(marks: [mark], gpx: true)
            }
            if model.platform.directions { AppleMapsItems(model: model, mark: mark) }
        }
        if MapMarkAsk.mayDelete(mark) {
            Divider()
            PMMenuDelete("Delete…", systemImage: "trash") { ask = .delete(mark) }
        }
    }
}

extension MapMarkAsk {
    #if os(iOS)
    @MainActor static var mayChange: Bool { PhoneInventoryModel.shared.mayEdit }
    /// An adult's phone: any but the Start point; a child's: a pin it made (MapMark.removable; owner, 2026-11-12).
    @MainActor static func mayDelete(_ mark: MapMark) -> Bool {
        mark.removable(adult: mayChange, phone: StreetMapWords.here)
    }

    /// A role or a look changed from the menu: sent as the phone saw the mark, so the Mac refuses one changed since.
    @MainActor static func send(_ mark: MapMark, _ what: String, _ change: (inout MapMark) -> Void) {
        var changed = mark
        change(&changed)
        guard changed != mark else { return }
        PhoneInventoryModel.shared.editMark(.changeMark(changed, expected: mark), what: what)
    }
    #else
    static let mayChange = false
    static func mayDelete(_ mark: MapMark) -> Bool { true }  // Edit › Undo puts it back, as the list's Delete
    #endif
}

extension View {
    /// Asks the edit or delete MapMarkActions set, then sends it: to the home Mac from a phone (its outbox),
    /// at once on the Mac. `done` after it is sent (the map's details close, showing the old name otherwise).
    func mapMarkAsk(_ ask: Binding<MapMarkAsk?>, done: @escaping () -> Void = {}) -> some View {
        modifier(MapMarkAskModifier(ask: ask, done: done))
    }
}

private struct MapMarkAskModifier: ViewModifier {
    @Binding var ask: MapMarkAsk?
    let done: () -> Void
    @State private var shown: MapMarkAsk?
    #if os(macOS)
    @Environment(\.undoManager) private var undo
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .sheet(item: Binding<MapMark?>(get: { if case .edit(let m)? = shown { return m } else { return nil } },
                                           set: { if $0 == nil { (shown, ask) = (nil, nil) } })) { mark in
                MarkForm(editing: mark) { changed in
                    (shown, ask) = (nil, nil)
                    // one change, sent as the phone saw the mark, so the Mac refuses one changed since
                    if let changed, changed != mark {
                        PhoneInventoryModel.shared.editMark(.changeMark(changed, expected: mark),
                                                            what: MapMarkWords.changed(changed.name))
                        done()
                    }
                }
            }
            .confirmationDialog(title, isPresented: showing { if case .delete = $0 { true } else { false } },
                                titleVisibility: .visible, presenting: shown) { ask in
                Button("Delete", role: .destructive) {
                    PhoneInventoryModel.shared.editMark(.removeMark(id: ask.mark.id, expected: ask.mark),
                                                        what: MapMarkWords.deleted(ask.mark.name))
                    done()
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(MapMarkWords.deleteOneWhy)
            }
            .onChange(of: ask?.id) { _, _ in shown = ask }
        #else
        content.onChange(of: ask?.id) { _, _ in  // the Mac deletes at once, as its list's Delete (Edit › Undo)
            guard case .delete(let mark) = ask else { return }
            ask = nil
            Task {
                await InventoryModel.shared.apply(.removeMark(id: mark.id, expected: mark), undo: undo,
                                                  name: "Delete \(mark.kind.undoWord)")
            }
            done()
        }
        #endif
    }

    #if os(iOS)
    private var title: String {
        if case .delete(let m)? = shown { MapMarkWords.deleteOneQuestion(m.name) } else { "" }
    }

    private func showing(_ kind: @escaping (MapMarkAsk) -> Bool) -> Binding<Bool> {
        Binding(get: { shown.map(kind) ?? false }, set: { if !$0 { (shown, ask) = (nil, nil) } })
    }
    #endif
}

// MARK: The model

/// What the street map shows, and the position while it's on screen; what differs by device comes in `platform`.
@MainActor
final class StreetMapModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    let controller: StreetMapController?  // nil without the map file: the rally view only (beta run F04)
    let file: URL?
    let platform: StreetMapPlatform
    @Published private(set) var here: CLLocation?
    /// How old `here` is (task 1.1): the phone grays the dot from half a minute and shows the banner from two. The Mac
    /// stays fresh: it asks for a fix once a minute and drops one at two minutes (expire).
    @Published private(set) var freshness = Position.Freshness.fresh
    @Published private(set) var heading: CLLocationDirection?
    @Published private(set) var places: PlaceIndex?
    @Published private(set) var placesLoading = true
    @Published var tapped: StreetMapTap?
    @Published var noOrganicMaps = false
    /// Where the directions Organic Maps couldn't take were going: the alert's way and its Show on map (task 2.3).
    private(set) var missingSpot: (Double, Double)?
    /// How, for the alert's Open in Apple Maps (hand-off plan, 3.1).
    private(set) var missingTravel = OrganicMaps.Travel.drive
    /// This device's choice of route on the strip (task 2.2): the alternate once Use the alternate is tapped, until
    /// Back to the main route. Kept between uses; never sent anywhere.
    @Published var useAlternate = UserDefaults.standard.bool(forKey: "streetMap.useAlternate") {
        didSet { UserDefaults.standard.set(useAlternate, forKey: "streetMap.useAlternate") }
    }
    @Published private(set) var authorization: CLAuthorizationStatus
    /// Follow me (task 1.2): on after Find me with a fix, off after a drag, Find me again, or the map leaving the
    /// screen. The phone only: the Mac's Find me flies there once.
    @Published private(set) var follow = StreetMap.Follow() {
        didSet {
            #if os(iOS)
            // the screen stays awake only while following (the owner's ruling, 2026-10-24; task 1.4)
            if follow.on != oldValue.on { UIApplication.shared.isIdleTimerDisabled = follow.on }
            #endif
        }
    }
    /// Find me was tapped while location is refused: the refusal and its way to Settings (Task 11.3; F66).
    @Published var explainRefusal = false
    /// The pins file couldn't be read (audit D3): set aside, or saving blocked. Said when the map opens.
    @Published var pinsProblem: String?
    private(set) var pins: PersonalPins
    private var topo: TopoIndex?
    private var conditions = MapConditions()
    private var showing = (conditions: true, marks: true, pins: true, old: false)
    @Published private(set) var hiddenOld = 0
    /// Every rally point's and route's way from the last fix, worked out once per fix or change of marks: the screen
    /// redraws on each compass turn too, and a full set of routes is a lot to measure that often (a stress test,
    /// 2026-10-14).
    @Published private(set) var currentWays: [Position.Way] = []
    /// The routes the phone has been on this visit (within 300 feet): only then does the strip say "Off route" (owner,
    /// 2026-10-25). Held in memory while the map is on screen, never saved, like `here`.
    private var joinedRoutes: Set<Int64> = []
    private var firstFix: Date?  // GPS eases off after a good fix, or a minute of fixes (Position.shouldEase)
    private var bestAccuracy = Double.infinity
    private let location = CLLocationManager()
    private var timer: Timer?
    private var ageTimer: Timer?  // the phone's: the fix's age checked every few seconds while on screen
    #if os(macOS)
    private var expiry: Timer?  // the Mac's fix leaves the screen when it passes Position.freshFix (fix round 1)
    /// The Mac's own tools (kept, Mac only: the spec's part 3, folded in from the Mac's own model): what a click on the
    /// map does now, the new rally point or route waiting for its name, and a print under way. Their work is in
    /// PrepareMeStreetMapMac.swift.
    @Published var mode: StreetMapMacMode = .browse {
        didSet { if case .route(let points) = mode { showDraft(points) } else { showDraft([]) } }
    }
    @Published var naming: MapMarkDraft?
    #endif
    /// The rally points and routes list: the phone's sheet, the Mac's panel beside the map (and its Map menu's item).
    @Published var listing = false
    /// The Mac's print, or the phone's Save as PDF, under way: the dot isn't drawn into the picture.
    @Published var printing = false

    /// Your own pins, kept on the phone that made them; the Mac has none (the spec's part 3), so nil there.
    static var pinsFolder: URL? {
        #if os(iOS)
        PrepareMeLibrary.root.appendingPathComponent("pins", isDirectory: true)
        #else
        nil
        #endif
    }

    /// `travel`: the travel maps the phone holds (combined step 9), drawn where the home file has no tile; none on the Mac
    init(file: URL?, info: StreetMap.Info?, travel: [URL] = [], built: String? = nil, platform: StreetMapPlatform) {
        self.file = file
        self.platform = platform
        #if os(macOS)
        controller = file.flatMap { file in info.map {
            StreetMapController(file: file, info: $0, printable: true, built: built)
        } }
        #else
        controller = file.flatMap { file in info.map {
            StreetMapController(file: file, info: $0, travel: travel, printable: true, built: built)  // Save as PDF
        } }
        #endif
        pins = Self.pinsFolder.map { PersonalPins.load($0) } ?? PersonalPins()
        pinsProblem = pins.problem  // said once: a file set aside is gone from its name at the next opening (D3)
        authorization = location.authorizationStatus
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        controller?.onTap = { [weak self] longitude, latitude, features, point, longPress in
            guard let self else { return }
            #if os(macOS)
            if placing(longitude, latitude) { return }  // Add pin, the Start point or Draw route took the click
            if features.isEmpty && !longPress { return }  // an empty spot shows nothing; a right-click offers to add
            #else
            // a tap opens This spot only on something; a long press anywhere, to drop a pin (Task 11.2; F23)
            guard MapTap.opensSpot(layers: features.map { $0["layer"] as? String ?? "" }, longPress: longPress)
            else { return }
            #endif
            tapped = StreetMapTap(longitude: longitude, latitude: latitude, features: features, point: point,
                                  longPress: longPress)
        }
        controller?.onDrag = { [weak self] in self?.follow.dragged() }
        refreshMarks()
        controller?.show(.pins, pinsData)
        guard let file else {  // the rally view without the map: no place list to read
            placesLoading = false
            return
        }
        if let kept = Self.kept, kept.file == file {  // the screen is made again on each switch to the street map
            places = kept.places
            placesLoading = false
            return
        }
        Task.detached(priority: .utility) { [file] in
            let found = PlaceIndex(mapFile: file)
            await MainActor.run {
                Self.kept = (file, found)
                self.places = found
                self.placesLoading = false
            }
        }
    }

    /// The place list read once per map file: over a million names, read again on every switch to the street map
    /// otherwise (an audit, 2026-10-14). A new file is a new name, so an old list is never used for it.
    private static var kept: (file: URL, places: PlaceIndex?)?

    func appear() {
        if platform.locates {
            #if os(macOS)
            // the question comes only from Find me, as on the phone (the Apple guidelines plan, phase 8: Apple's
            // Privacy page, ask when the feature is used), not when the map opens
            askOnce()  // the Mac asks for one fix at a time (askOnce), the phone for a stream
            #else
            // the phone asks only from its why line's button or Find me (askLocation; Task 11.3, F25), and starts
            // its fixes once allowed (here, or locationManagerDidChangeAuthorization)
            if locationStatus == .allowed { location.startUpdatingLocation() }
            #endif
        }
        if platform.heading, CLLocationManager.headingAvailable() { location.startUpdatingHeading() }
        #if targetEnvironment(simulator)
        // the store screenshots (Unlisted plan, phase 6): a simulator has no compass, so PREPAREME_CHECK_HEADING=DEGREES
        // stands in for one and the map leaves out its "No compass" line
        if let degrees = ProcessInfo.processInfo.environment["PREPAREME_CHECK_HEADING"].flatMap(Double.init) {
            heading = degrees
        }
        #endif
        Task { await refreshConditions() }
        Task { await loadTopo() }
        timer?.invalidate()  // an appear with no disappear between (fix round 1): never two timers
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                #if os(macOS)
                self?.askOnce()  // a new fix each minute, well before the last passes freshFix
                #endif
                await self?.refreshConditions()
            }
        }
        #if os(iOS)
        ageTimer?.invalidate()
        ageTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAge() }
        }
        #endif
    }

    /// Follow me ends when the app goes to the background (its screen kept awake no longer: task 1.4).
    func stopFollowing() { follow = StreetMap.Follow() }

    /// The dot redrawn when the fix crosses half a minute or two minutes old with no newer one (task 1.1).
    private func checkAge() {
        guard let here else { return }
        let now = Position.freshness(taken: here.timestamp)
        guard now != freshness else { return }
        freshness = now
        drawPosition()
    }

    /// The dot, its circle and heading, for the fix kept (none while printing on the Mac: printLayers).
    private func drawPosition() {
        guard let here, !printing else { return }
        controller?.showPosition(latitude: here.coordinate.latitude, longitude: here.coordinate.longitude,
                                accuracy: here.horizontalAccuracy, heading: heading, stale: freshness != .fresh)
    }

    func disappear() {
        location.stopUpdatingLocation()
        #if os(iOS)
        location.stopUpdatingHeading()  // macOS has no stop for it (the Mac never starts it: platform.heading)
        #endif
        timer?.invalidate()
        timer = nil
        ageTimer?.invalidate()
        ageTimer = nil
        freshness = .fresh
        #if os(macOS)
        expiry?.invalidate()
        expiry = nil
        #endif
        stopFollowing()  // and the screen may sleep again
        here = nil  // never kept once the map is off screen
        currentWays = []
        joinedRoutes = []
        heading = nil
        firstFix = nil
        bestAccuracy = .infinity
        location.desiredAccuracy = kCLLocationAccuracyBest  // the next visit starts with a good fix again
        controller?.clearPosition()
    }

    // MARK: Layers

    func show(conditions on: Bool) {
        showing.conditions = on
        sendConditions()
    }

    func show(marks on: Bool) {
        showing.marks = on
        refreshMarks()
    }

    func show(old on: Bool) {
        showing.old = on
        sendConditions()
    }

    func show(pins on: Bool) {
        showing.pins = on
        refreshPins()
    }

    /// The shared pins as this device holds them, and the pin layer's data: those, after a phone's own from before.
    var sharedPins: [MapMark] { platform.pins() }
    private var pinsData: Data { MapMark.pinsGeoJSON(sharedPins, own: pins) }

    func refreshPins() {
        if printing { return }  // as refreshMarks: pins never print on the household map
        controller?.show(.pins, showing.pins ? pinsData : StreetMapWords.empty)
    }

    func refreshMarks() {
        if printing { return }  // the print's layers stay until it's done (printLayers, pdfOfView), then come back
        controller?.show(.marks, showing.marks ? MapMark.geoJSON(marks) : StreetMapWords.empty)
        currentWays = here.map { ways(from: $0) } ?? []
        // the alternate, once gone, isn't picked again by itself when a new one is marked (the W9 review); not while
        // the marks haven't come yet, which would undo the choice on every start
        let now = marks
        if useAlternate, now.contains(where: { $0.kind == .route }), !Position.canSwitchRoutes(now) {
            useAlternate = false
        }
    }

    /// The Mac's road events and gauges from the daily library, and the storm warnings' outlines from the device's
    /// own reading (the phone's, only while its own alerts show: LiveConditions.warningShapes; the Mac reads none).
    func refreshConditions() async {
        for held in platform.record().held.values where held.entry.kind == "library" {
            guard let content = await ZimFileService.shared.getURLContent(zimFileID: held.entry.id,
                                                                          contentPath: MapConditions.path),
                  let read = try? MapConditions(content.data) else { continue }
            conditions = read
            break
        }
        sendConditions()
    }

    private func sendConditions() {
        hiddenOld = showing.old ? 0 : conditions.hidden()
        #if os(macOS)
        if printing { return }  // as refreshMarks
        #endif
        guard showing.conditions else { controller?.show(.conditions, StreetMapWords.empty); return }
        controller?.show(.conditions, conditions.geoJSON(warnings: platform.warningShapes(), showOld: showing.old))
    }

    #if os(macOS)
    /// The printed household map's layers, whatever Layers says (fix round 1: a saved switch had printed a map with no
    /// rally points beside a legend of them): every rally point and route given, and the conditions as the Mac drew
    /// them before the switches (none over 3 days old). Sent before the snapshots, which the page takes in order.
    /// The Mac's own dot and its circle never print on the household map (part 3 review): the position is cleared
    /// here, a fix while printing is kept but not drawn (didUpdateLocations), and screenLayers puts the dot back.
    func printLayers(_ marks: [MapMark]) {
        controller?.clearPosition()
        controller?.show(.pins, StreetMapWords.empty)  // never on the household map (hazards pass; the go-bag's map stays)
        controller?.show(.marks, MapMark.geoJSON(marks))
        controller?.show(.conditions, conditions.geoJSON())
    }

    /// What Layers shows, back on screen once the print's pictures are taken, with the dot if there is a fix.
    func screenLayers() {
        refreshMarks()
        refreshPins()
        sendConditions()
        drawPosition()
    }
    #endif

    /// The topo overview this device holds (its Find a map page), by its file name.
    private var overviewID: UUID? {
        platform.record().held.values.first { $0.entry.name == PrepareMeKeptTabs.overviewFile }
            .flatMap { UUID(uuidString: $0.entry.id) }
    }

    private func loadTopo() async {
        guard topo == nil, let id = overviewID,
              let content = await ZimFileService.shared.getURLContent(zimFileID: id.uuidString,
                                                                      contentPath: TopoIndex.page)
        else { return }
        topo = TopoIndex(page: String(decoding: content.data, as: UTF8.self))
    }

    /// Topo map for here: the topo map on this device covering the middle of the map, opened on Find a map. False when
    /// none does.
    func openTopo() -> Bool {
        guard let c = controller?.camera else { return false }
        let held = Set(platform.record().held.values.map(\.entry.id))
        guard let map = topo?.covering(longitude: c.longitude, latitude: c.latitude, held: held).first,
              let url = TopoIndex.url(map) else { return false }
        platform.openTopo(url)
        return true
    }

    // MARK: Places and pins

    func find(_ text: String) async -> [PlaceIndex.Place] {
        guard let places, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let near = here.map { ($0.coordinate.latitude, $0.coordinate.longitude) }
        return await Task.detached(priority: .userInitiated) { places.search(text, near: near, limit: 8) }.value
    }

    func go(to place: PlaceIndex.Place) {
        stopFollowing()  // as showSpot
        controller?.flyTo(longitude: place.longitude, latitude: place.latitude,
                         zoom: StreetMapWords.kind(place.kind) == "Town" ? 13 : 15)
    }

    var pinsFull: Bool { pins.full }

    func addPin(_ label: PersonalPins.Label, longitude: Double, latitude: Double) {
        #if os(iOS)
        guard !PrepareMeSample.shared.on else { return }
        #endif
        guard pins.add(label, longitude: longitude, latitude: latitude) != nil else { return }
        savePins()
    }

    func removePin(_ id: String) {
        guard let uuid = UUID(uuidString: id) else { return }
        pins.remove(uuid)
        savePins()
    }

    #if os(iOS)
    /// Whether pins are shared through the Mac (PhoneInventoryModel.sharesPins); until then they are this phone's own.
    var sharesPins: Bool { PhoneInventoryModel.shared.sharesPins }

    /// A new shared pin or rally point where the map was pressed: on this phone at once, the Mac's at its next check.
    func addShared(_ mark: MapMark) {
        PhoneInventoryModel.shared.editMark(.addMark(mark.rounded), what: MapMarkWords.pinAdded(mark.name))
    }

    /// This phone's own pins from before pins were shared, to ask about once the Mac shares them.
    var oldPins: Int { sharesPins ? pins.pins.count : 0 }

    /// Share them: each becomes a shared pin (its kind's look, its own id), and leaves the phone's own list once
    /// the change is waiting for the Mac.
    func shareOldPins() {
        for (old, shared) in zip(pins.pins, pins.asShared)
        where PhoneInventoryModel.shared.editMark(.addMark(shared), what: MapMarkWords.pinAdded(shared.name)) != nil {
            pins.remove(old.id)
        }
        savePins()
    }

    func deleteOldPins() {
        pins.removeAll()
        savePins()
    }
    #endif

    private func savePins() {
        #if os(iOS)
        guard !PrepareMeSample.shared.on else { return }  // the sample changes nothing (its buttons are hidden too)
        #endif
        objectWillChange.send()  // Share my pins follows what there is to share
        if let folder = Self.pinsFolder { try? pins.save(folder) }
        refreshPins()
    }

    #if os(iOS)
    /// Another phone's shared pins added to these (the street map fixes plan, task 4.1): what to say once done.
    func addPins(from url: URL) -> String {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // the size first: a big file picked by mistake is never read whole (the W9 review); one whose size can't be
        // read is read anyway, with PersonalPins.read's own size check as the backstop
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if sharesPins {  // shared pins (phase 3): added as this phone's own adds, each kept once by its uid
            guard size < PersonalPins.sharedMaxBytes, let data = try? Data(contentsOf: url),
                  let found = SharedPinsFile.read(data) else { return PersonalPins.readWrong }
            let fresh = SharedPinsFile.new(found, among: sharedPins)
            let added = fresh.filter {
                PhoneInventoryModel.shared.editMark(.addMark($0), what: MapMarkWords.pinAdded($0.name)) != nil
            }.count
            return SharedPinsFile.words(added: added, already: found.count - fresh.count)
        }
        guard size < PersonalPins.sharedMaxBytes,
              let data = try? Data(contentsOf: url), let others = PersonalPins.read(shared: data) else {
            return PersonalPins.readWrong
        }
        let result = pins.merged(with: others)
        pins = result.pins
        savePins()
        return PersonalPins.mergeWords(added: result.added, already: result.already, leftOut: result.leftOut,
                                       device: StreetMapWords.device)
    }

    /// The view on screen as a PDF (task 4.2): north up, with the US National Grid, a scale bar and the legend of the
    /// rally points and routes in it, as the Mac prints its household map; the dot never in it. Nil if the map
    /// couldn't give its picture.
    func pdfOfView() async -> Data? {
        guard !printing, let controller else { return nil }
        printing = true
        controller.clearPosition()
        let all = marks
        // the rally points and routes always print, whatever Layers shows, as the Mac's printLayers (the W9 review)
        controller.show(.marks, MapMark.geoJSON(all))
        defer {
            printing = false
            refreshMarks()
            drawPosition()
        }
        guard let shot = await controller.snapshotHere(),
              let sheet = HouseholdMap.Sheet(png: shot.png, bounds: shot.bounds, title: "Street map") else { return nil }
        let b = shot.bounds
        let inView = all.filter { mark in
            mark.points.contains { $0.count == 2 && (b[0]...b[2]).contains($0[0]) && (b[1]...b[3]).contains($0[1]) }
        }
        return HouseholdMap.pdf(whole: sheet, close: nil, marks: inView, numbered: all)
    }
    #endif

    // MARK: Directions

    /// Organic Maps opened routing from here to a spot (owner, 2026-10-14): it routes offline on its own maps.
    func directions(to spot: (Double, Double), name: String, travel: OrganicMaps.Travel) {
        let from = here.map { ($0.coordinate.latitude, $0.coordinate.longitude) }
        guard let url = OrganicMaps.url(from: from, to: spot, name: name, travel: travel) else { return }
        tapped = nil  // a spot's details close first: the map is there to come back to
        guard platform.canOpen(url) else {
            missingSpot = spot
            missingTravel = travel
            #if os(iOS)
            listing = false  // the alert shows from the map, not under the Marks list (the W9 review)
            #endif
            Task {  // once the details have gone, or the message can't show
                try? await Task.sleep(for: .milliseconds(600))
                noOrganicMaps = true
            }
            return
        }
        platform.open(url)
    }

    /// Apple Maps opened routing to a spot (hand-off plan, 3.1): from this device's fix only while it is fresh
    /// (Position.usable, the two-minute rule), else Apple Maps routes from where it finds the device. On every device,
    /// so no check that it's there.
    func appleMaps(to spot: (Double, Double), travel: OrganicMaps.Travel) {
        let from = here.flatMap { fix in
            Position.usable(accuracy: fix.horizontalAccuracy, taken: fix.timestamp)
                ? (fix.coordinate.latitude, fix.coordinate.longitude) : nil
        }
        guard let url = AppleMaps.url(from: from, to: spot, travel: travel) else { return }
        tapped = nil  // as directions: a spot's details close first
        platform.open(url)
    }

    // MARK: Position

    var marks: [MapMark] { platform.marks() }

    /// The route the strip names (task 2.1): main, or the alternate once chosen, else the nearest.
    func chosenRoute(_ ways: [Position.Way]) -> Position.Way? {
        Position.chosenRoute(ways, alternate: useAlternate)
    }

    /// The Organic Maps alert's title and message, the way first when this device knows where it is (task 2.3).
    var missingWords: (title: String, message: String) {
        OrganicMaps.missingWords(device: StreetMapWords.device,
                                 from: here.map { ($0.coordinate.latitude, $0.coordinate.longitude) },
                                 to: missingSpot ?? (0, 0),
                                 lostSince: freshness == .stale ? here?.timestamp : nil)
    }

    /// The chosen route's "Off route" line, or nil (Position.offRoute: only once on it, and only with a sure fix).
    func offRoute(_ way: Position.Way) -> String? {
        guard let here else { return nil }
        return Position.offRoute(way, accuracy: here.horizontalAccuracy, joined: joinedRoutes.contains(way.mark.id))
    }

    /// A spot chosen to look at (Show on map, a strip row): Follow me stops first, or the next fix pulls the map back
    /// (the W9 review).
    func showSpot(longitude: Double, latitude: Double, zoom: Double? = nil) {
        stopFollowing()
        controller?.flyTo(longitude: longitude, latitude: latitude, zoom: zoom)
    }

    func ways(from here: CLLocation) -> [Position.Way] {
        Position.ways(from: (here.coordinate.latitude, here.coordinate.longitude), to: marks)
    }

    /// The way from here to one mark (its nearest point, how far, which way), or nil without a fix or for the Start.
    func way(to mark: MapMark) -> Position.Way? {
        here.flatMap { Position.ways(from: ($0.coordinate.latitude, $0.coordinate.longitude), to: [mark]).first }
    }

    /// Where Drive and Walk go (latitude, longitude): a route's nearest spot from here, else the mark's own point.
    func goSpot(_ mark: MapMark) -> (Double, Double)? {
        if let near = way(to: mark)?.nearest { return (near[1], near[0]) }
        return mark.points.first { $0.count == 2 }.map { ($0[1], $0[0]) }
    }

    /// The meeting place the kids' phones point to (Position.kidsTarget), by Event mode on a phone.
    var kidsTarget: Int64? {
        #if os(iOS)
        Position.kidsTarget(marks, eventOn: eventOn)
        #else
        Position.kidsTarget(marks, eventOn: false)
        #endif
    }

    /// A Pins list row tapped (the map pins plan, Task 2.4): the list closes, the map moves to the mark, and its card
    /// opens. The mark is found again by `sameMark`, so a pin still waiting for the Mac, or one given its row since,
    /// opens too.
    func open(_ mark: MapMark) {
        let current = (marks + sharedPins).first { $0.sameMark(mark) } ?? mark
        listing = false
        show(current)
        guard let at = current.points.first(where: { $0.count == 2 }) else { return }
        let feature: [String: Any] = current.kind == .pin
            ? ["layer": "pm-pin", "shared": true, "pin": current.uid ?? "", "at": at]
            : ["layer": "pm-\(current.kind.rawValue)", "id": NSNumber(value: current.id), "kind": current.kind.rawValue,
               "name": current.name, "note": current.note]
        Task {  // a sheet can't open while the list's is closing: after it has gone
            #if os(iOS)
            try? await Task.sleep(for: .milliseconds(600))
            #endif
            tapped = StreetMapTap(longitude: at[0], latitude: at[1], features: [feature], point: nil)
        }
    }

    /// A rally point or route chosen in the list, shown on the map.
    func show(_ mark: MapMark) {
        let points = mark.points.filter { $0.count == 2 }
        guard let first = points.first else { return }
        stopFollowing()  // as showSpot
        if points.count == 1 { controller?.flyTo(longitude: first[0], latitude: first[1], zoom: 16); return }
        let box = points.reduce((first[0], first[1], first[0], first[1])) { b, p in
            (min(b.0, p[0]), min(b.1, p[1]), max(b.2, p[0]), max(b.3, p[1]))
        }
        controller?.fit(west: box.0, south: box.1, east: box.2, north: box.3)
    }

    /// "You'd arrive after dark" under `way` (step 6, part 4): from the last fix, setting out now at the slower
    /// walking rate; nil in daylight or with no fix.
    func afterDark(_ way: Position.Way) -> String? {
        guard let here else { return nil }
        return Sky.afterDark(way, latitude: here.coordinate.latitude, longitude: here.coordinate.longitude, now: Date())
    }

    /// The arrow's turn: toward the way from the way the phone faces, or from north when the heading isn't known.
    func arrow(for way: Position.Way) -> Double {
        way.bearing - (heading ?? 0)
    }

    var locationStatus: LocationAsk.Status {
        switch authorization {
        case .notDetermined: .notAsked
        case .denied, .restricted: .refused
        default: .allowed
        }
    }

    var locationWords: String { LocationAsk.line(locationStatus) }

    /// The system's question, asked under the why line (Task 11.3; F25): only while it is unanswered.
    func askLocation() {
        if platform.locates, location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
    }

    func whereAmI() {
        guard let here else {
            switch LocationAsk.whereAmI(locationStatus) {
            case .ask: askLocation()
            case .explainRefusal:
                #if os(iOS)
                explainRefusal = true  // it used to do nothing (F66); the Mac's line already says where
                #endif
            case .wait:
                #if os(macOS)
                askOnce()  // try again now, not at the next minute
                #endif
            }
            return
        }
        #if os(iOS)
        follow.tapFindMe(hasFix: true)
        guard follow.on else { return }  // Find me again stops following: the map stays where it is
        #endif
        controller?.flyTo(longitude: here.coordinate.longitude, latitude: here.coordinate.latitude, zoom: 16)
    }

    /// Only a fresh fix with a real accuracy is shown: iOS hands over its saved one first, maybe hours old and from
    /// home (an audit, 2026-10-14).
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last(where: { Position.usable(accuracy: $0.horizontalAccuracy, taken: $0.timestamp) })
        else { return }
        MainActor.assumeIsolated {
            here = last
            freshness = Position.freshness(taken: last.timestamp)
            currentWays = ways(from: last)
            joinedRoutes.formUnion(currentWays.filter { Position.onRoute($0, accuracy: last.horizontalAccuracy) }.map(\.mark.id))
            ease(after: last)
            #if os(macOS)
            expire(last)
            if printing { return }  // kept, not drawn: the dot never prints (printLayers); screenLayers draws it
            #endif
            drawPosition()
            if follow.on, !printing {
                controller?.follow(longitude: last.coordinate.longitude, latitude: last.coordinate.latitude)
            }
        }
    }

    /// No fix could be had (`requestLocation`'s answer on the Mac, or a passing failure): what is shown stays as it is;
    /// a fix still leaves once it passes freshFix. Core Location expects this method once a fix is asked for.
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}

    /// Battery (an audit, 2026-10-14): best accuracy only until a good fix or a minute of fixes (Position.shouldEase,
    /// task 1.4), then about 10 m, or about 100 m in Low Power Mode: enough for an arrow and a grid number, longer on
    /// a phone with no charger.
    private func ease(after fix: CLLocation) {
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        let first = firstFix ?? Date()
        firstFix = first
        bestAccuracy = min(bestAccuracy, fix.horizontalAccuracy)
        let calmed = Position.shouldEase(bestAccuracy: bestAccuracy, sinceFirstFix: Date().timeIntervalSince(first))
        let want = low ? kCLLocationAccuracyHundredMeters
            : calmed ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyBest
        guard location.desiredAccuracy != want else { return }
        location.desiredAccuracy = want  // no distance filter: standing still, the fix must still come, or it reads as old
        location.headingFilter = 5
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let degrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        let trusted = newHeading.headingAccuracy >= 0  // below 0: the compass can't say (interference, uncalibrated)
        MainActor.assumeIsolated {
            guard degrees >= 0, trusted else {
                heading = nil
                return
            }
            heading = degrees
            #if os(macOS)
            if printing { return }  // as didUpdateLocations
            #endif
            drawPosition()
        }
    }

    #if os(macOS)
    /// The Mac's fix kept current (Mac sidebar plan, task 12; fix round 1). A Mac standing still may send no new fix
    /// for minutes, and restarting its updates can hand back the saved fix with its old time, so it asks for one fresh
    /// fix (`requestLocation`) on appearing, once allowed, and each minute while on screen. Not while the question is
    /// unanswered or the answer is no; a request while one is pending does nothing.
    func askOnce() {
        guard platform.locates else { return }
        switch location.authorizationStatus {
        case .notDetermined, .denied, .restricted: return
        default: location.requestLocation()
        }
    }

    /// Each fix leaves the screen the moment it passes `Position.freshFix`, its dot and distances with it, unless a
    /// newer one has come; the line then says this Mac can't tell. The phone keeps a fix and says its age instead
    /// (StreetMapFixLine).
    private func expire(_ fix: CLLocation) {
        expiry?.invalidate()
        let left = Position.freshFix - Date().timeIntervalSince(fix.timestamp)
        expiry = Timer.scheduledTimer(withTimeInterval: max(0, left) + 0.25, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dropStale() }
        }
    }

    private func dropStale() {
        guard let last = here, !Position.usable(accuracy: last.horizontalAccuracy, taken: last.timestamp) else { return }
        here = nil
        currentWays = []
        controller?.clearPosition()
    }

    /// The Mac's line while it has no fix to show: none while macOS's question is on screen; how to turn location on
    /// when PrepareMe may not use it; else that this Mac can't tell (the words are pinned in app/Service).
    var noFixLine: String? {
        guard platform.locates else { return nil }
        switch authorization {
        case .notDetermined: return nil
        case .denied, .restricted: return StreetMapWords.locationOff
        default: return StreetMapWords.noFix
        }
    }
    #endif

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            authorization = status
            #if os(macOS)
            if timer != nil { askOnce() }  // allowed while the map shows: its first fix now
            #else
            if timer != nil, locationStatus == .allowed { location.startUpdatingLocation() }  // allowed on the map
            #endif
        }
    }
}

#if os(iOS)
/// Buttons in a row that wraps (beta run 2, B2-23): as many to a row as the width allows (ButtonRows.split), the rows
/// right-aligned under one another, every button whole. A fixed row ran off both edges of an iPhone SE.
struct ButtonWrap: Layout {
    var spacing: CGFloat
    var maxWidth: CGFloat  // the room, handed down: never wider whatever the parent proposes

    /// Each button's own size, measured once per layout pass (Layout's cache), not again for its size and its places
    func makeCache(subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func updateCache(_ cache: inout [CGSize], subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache sizes: inout [CGSize]) -> CGSize {
        let size = ButtonRows.size(widths: sizes.map { Double($0.width) }, heights: sizes.map { Double($0.height) },
                                   spacing: Double(spacing), available: Double(min(proposal.width ?? .infinity, maxWidth)))
        return CGSize(width: size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache sizes: inout [CGSize]) {
        var y = bounds.minY
        let rows = ButtonRows.split(widths: sizes.map { Double($0.width) }, spacing: Double(spacing),
                                    available: Double(min(bounds.width, maxWidth)))
        for row in rows {
            let widths = row.map { sizes[$0].width }
            var x = bounds.maxX - (widths.reduce(0, +) + spacing * CGFloat(max(row.count - 1, 0)))
            for i in row {
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
                x += sizes[i].width + spacing
            }
            y += (row.map { sizes[$0].height }.max() ?? 0) + spacing
        }
    }
}
#endif

#if os(iOS)
extension View {
    /// The tap card: half height, and at the accessibility text sizes full height and, on the iPad, the page-sized
    /// sheet (it ignores the heights), so Drive and Walk show without scrolling (the map pins plan's phase 4 pass).
    @ViewBuilder func tapCardHeight(tall: Bool) -> some View {
        if tall { presentationDetents([.large]).presentationSizing(.page) } else { presentationDetents([.medium]) }
    }
}
#endif
