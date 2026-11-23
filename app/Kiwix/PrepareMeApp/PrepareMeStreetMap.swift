// This file is part of PrepareMe, a local build of Kiwix for one household (build plan phase 9).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import CoreLocation
import PrepareMeShared  // StreetMapWords, at the end, is the Mac's too

/// The Maps tab's two views (plan phase 9): Find a map (the map files' pages, as before) and the street map. The
/// Mac's Maps row has the same two (Mac sidebar plan, part 2).
typealias MapsPane = MapsSide  // PrepareMeShared (MapsFirstSide.swift): which side Maps opens on is tested there

#if os(iOS)
import SwiftUI
import WebKit

/// The street map in the Maps tab: the map itself when this phone holds the file (`StreetMap.heldFile`), with each
/// travel map it holds (combined step 9), else where to get it.
struct StreetMapPane: View {
    @ObservedObject private var store = PrepareMeLibrary.shared.store
    @ObservedObject private var travel = PrepareMeTravel.store
    @ObservedObject private var sample = PrepareMeSample.shared

    var body: some View {
        if let file = sample.mapFile, let info = StreetMap.info(file) {  // the sample's Washington, DC, no travel maps
            StreetMapScreen(file: file, info: info).id([file])
        } else if let file = StreetMap.heldFile(store.record, in: store.libraryFolder), let info = StreetMap.info(file) {
            StreetMapScreen(file: file, info: info, travel: travel.files, built: StreetMap.built(store.record))
                .id([file] + travel.files)
        } else if store.record.manifest?.files.contains(where: \.isStreetMap) == true {
            // the beta run's F04 (owner, 2026-10-16): the rally points come with the inventory, so they show even
            // before the map file is fetched, with where to get the map itself
            StreetMapScreen(file: nil, info: nil).id("no map file")
        } else {
            // look 3's one look for "nothing here" (spec section 10), the switch's word for this side over its words
            PMStateScreen { PMState(symbol: "map", heading: "Street map", line: "No street map yet: the Mac hasn't made it.") }
        }
    }

}

/// The street map's screen (screens approved 2026-10-14, owner, by click, on a mockup): adults' phones get the full
/// map (Find a place at the top; Where am I, layers and Topo map for here on the right; the nearest rally point and
/// route, and the position, along the bottom); phones paired read-only (a child's) open the simple view (one big
/// arrow to the nearest rally point, and "I'm lost: show my place number"), with the map a tap away.
struct StreetMapScreen: View {
    @StateObject private var model: StreetMapModel
    @ObservedObject private var inventory = PhoneInventoryModel.shared
    @ObservedObject private var tabs = PrepareMeTabs.shared
    @ObservedObject private var redNight = PrepareMeRedNight.shared  // the pins' red night look (the W9 review)
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var phase
    @State private var mapAnyway = false

    init(file: URL?, info: StreetMap.Info?, travel: [URL] = [], built: String? = nil) {
        _model = StateObject(wrappedValue: StreetMapModel(file: file, info: info, travel: travel, built: built,
                                                          platform: .phone))
    }

    var body: some View {
        ZStack {  // not a Group: a Group's onAppear and onDisappear run for each view inside, so switching from the
                  // simple view to the map could stop the position just after starting it (an audit, 2026-10-14)
            switch RallyWords.screen(hasMapFile: model.controller != nil, hasCopy: inventory.shown != nil,
                                     // the sample opens on the full map, as an adult's (it still changes nothing)
                                     canEdit: inventory.canEdit || inventory.sample, mapAsked: mapAnyway) {
            case .rally(let role):  // no map file: the rally view for everyone; a child's phone: theirs, the map a tap away
                StreetMapSimpleView(model: model, role: role,
                                    showMap: model.controller == nil ? nil : { mapAnyway = true })
            case .map(let backToRally):  // a child's full map has its way back (Task 11.1; F22)
                StreetMapFullView(model: model, backToRally: backToRally ? { mapAnyway = false } : nil)
            }
        }
        .onAppear {
            #if targetEnvironment(simulator)
            // a session's check of the shared pins on a child's phone (screenshots, no taps): straight to its map
            if ["spot", "list", "pintap", "addpin", "removepin", "ownpins"]
                .contains(ProcessInfo.processInfo.environment["PREPAREME_CHECK_PART"] ?? "") { mapAnyway = true }
            #endif
            model.controller?.setDark(scheme == .dark)
            model.controller?.setRed(redNight.on)
            model.appear()
            // the Mac's lists, since the rally points come with them: each time the map opens, not only with no copy
            // held, as a phone holds one from pairing on (beta run 2, B2-01; phase 2 review)
            Task { await inventory.lookIfDue(.streetMapOpened) }
        }
        .onDisappear { model.disappear() }  // the position is read only while the map is on screen
        // here, over both views: a child's phone, or one with no map file, never opens the full map (audit D3)
        .alert("Street map", isPresented: Binding(get: { model.pinsProblem != nil },
                                                  set: { if !$0 { model.pinsProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.pinsProblem ?? "")
        }
        .onChange(of: phase) { _, now in if now == .background { model.stopFollowing() } }  // the screen may sleep
        .onChange(of: scheme) { _, now in model.controller?.setDark(now == .dark) }
        .onChange(of: redNight.on) { _, now in model.controller?.setRed(now) }
        .onChange(of: inventory.shown?.mapMarks) { _, _ in model.refreshMarks() }
        .onChange(of: inventory.shown?.pins) { _, _ in model.refreshPins() }  // the shared pins (the shared marks plan)
        .onChange(of: tabs.streetMapFit, initial: true) { _, box in  // a topo map's "Show on street map"
            guard let box, box.count == 4 else { return }
            mapAnyway = true
            model.controller?.fit(west: box[0], south: box[1], east: box[2], north: box[3])
            tabs.streetMapFit = nil
        }
    }
}

// MARK: The phone's own views (the shared ones and the model are in PrepareMeStreetMapScreen.swift)

/// The strip along the bottom: the planned rally point (Near home, or Out of town in Event mode; else the nearest) with
/// its arrow and distance, then the nearest route, then where the phone is, how good the fix is, and Share. Without a
/// fix the rally point's name still shows (an audit, 2026-10-14: a basement may never get one).
struct StreetMapStrip: View {
    @ObservedObject var model: StreetMapModel
    /// A narrow phone (`StripFold.folded`): the strip is one row, the name, how far and the arrow, until `open`
    /// (beta run 3, S4.1; B2-23). A wide phone's strip is always whole.
    var folded = false
    @Binding var open: Bool
    /// The most an opened folded strip's rest takes before it scrolls (a third of the screen at the accessibility sizes,
    /// half below them), else nil.
    var room: CGFloat? = nil
    @Environment(\.dynamicTypeSize) private var textSize

    /// What the folded row shows: the rally point (else the nearest route) with its way once the phone has a fix, or
    /// just the planned rally point's name before it has one. Nil when there is nothing to name: the strip then stays
    /// whole, which is short.
    private var summary: (name: String, way: Position.Way?)? {
        if model.here != nil {
            let ways = model.currentWays
            return (model.rallyWay(ways) ?? model.chosenRoute(ways) ?? ways.first).map { ($0.mark.name, $0) }
        }
        return model.plannedOrFirst.map { ($0.name, nil) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.freshness == .stale, let here = model.here { StreetMapStaleBanner(here: here) }
            strip
        }
    }

    @ViewBuilder private var strip: some View {
        if folded, let summary {
            if open {
                VStack(alignment: .trailing, spacing: 0) {
                    Button { open = false } label: {
                        Label(StripFold.less, systemImage: "chevron.down").font(.pmNote)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(PrepareMeColors.text2)
                    .accessibilityLabel(StripFold.lessLabel).accessibilityHint(StripFold.lessHint)
                    .accessibilityInputLabels([StripFold.less, StripFold.lessLabel])
                    if let room {  // at the largest text the rest runs past the screen: it scrolls in its room instead
                        ScrollView { full }.scrollBounceBehavior(.basedOnSize).frame(maxHeight: room)
                    } else {
                        full
                    }
                }
                .modifier(StripCard())
                .onTapGesture { recenter() }  // as the whole strip does on a wide phone
                .accessibilityAction(named: "Center the map on me") { recenter() }  // the tap, for VoiceOver (phase 4)
            } else {
                foldedRow(summary.name, summary.way).modifier(StripCard())
            }
        } else {
            full.modifier(StripCard())
                .onTapGesture { recenter() }
                .accessibilityAction(named: "Center the map on me") { recenter() }
        }
    }

    /// A tap on the open strip centers the map on the phone.
    private func recenter() {
        if let here = model.here {
            model.controller?.flyTo(longitude: here.coordinate.longitude, latitude: here.coordinate.latitude)
        }
    }

    /// The one row: the arrow (a flag before the phone has a fix), the name, how far and which way, and More. A tap
    /// anywhere on it opens the rest. The name never shrinks to nothing: it wraps to a second line, and at the
    /// accessibility text sizes to as many as it needs.
    func foldedRow(_ name: String, _ way: Position.Way?) -> some View {
        let brief = way.map { "\(Position.distance($0.meters)) \(Position.compass($0.bearing))" }
        let taken = model.here?.timestamp  // the fix's age follows the distance once it's a minute old (task 1.1)
        func withAge(_ brief: String, _ now: Date) -> String {
            taken.flatMap { Position.ageBrief(taken: $0, now: now) }.map { brief + ", " + $0 } ?? brief
        }
        let dark = way.flatMap { model.afterDark($0) } != nil
        // the chosen route's "Off route" shows folded too, whichever mark the row names (the W9 review)
        let off = model.chosenRoute(model.currentWays).flatMap { model.offRoute($0) }
        return Button { open = true } label: {
            HStack(spacing: 10) {
                if let way {
                    Image(systemName: "location.north.fill")
                        .rotationEffect(.degrees(model.arrow(for: way)))
                        .font(.pmTitle)
                        .foregroundStyle(PrepareMeColors.ink)
                } else {
                    Image(systemName: "flag.fill").font(.pmTitle).foregroundStyle(PrepareMeColors.ink)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.pmHeadline).lineLimit(textSize.isAccessibilitySize ? nil : 2)
                        .multilineTextAlignment(.leading)
                    if let brief {
                        HStack(spacing: 4) {
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                Text(withAge(brief, context.date)).font(.pmNote)
                            }
                            if dark {  // "You'd arrive after dark" is in the open strip; the fold keeps its mark
                                Image(systemName: "moon.fill").font(.pmNote)
                                    .foregroundStyle(PrepareMeColors.caution)
                            }
                        }
                    }
                    if let off {
                        Label(off, systemImage: "exclamationmark.triangle.fill").font(.pmNote)
                            .foregroundStyle(PrepareMeColors.caution).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    Image(systemName: "chevron.up")
                    if !textSize.isAccessibilitySize { Text(StripFold.more).font(.pmNote) }
                }
                .foregroundStyle(PrepareMeColors.text2)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StripFold.spoken(name: name, brief: brief.map { withAge($0, Date()) }, afterDark: dark,
                                             offRoute: off))
        .accessibilityHint(StripFold.moreHint)
        .accessibilityInputLabels([StripFold.more, name])  // Voice Control: "Tap More" or the point's name
        .accessibilityAddTraits(.isButton)
    }

    /// The whole strip, as on a wide phone.
    var full: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let here = model.here {
                let ways = model.currentWays
                if let rally = model.rallyWay(ways) {
                    wayRow(rally, symbol: "flag.fill", meeting: true)
                    if let nearest = RallyWords.nearestLine(ways, planned: rally.mark.id) {  // task 1.3
                        Label(nearest, systemImage: "mappin.and.ellipse").font(.pmNote)
                            .foregroundStyle(PrepareMeColors.text2)
                    }
                }
                if let route = model.chosenRoute(ways) {  // held to its role, never swapped by itself (task 2.2)
                    wayRow(route, symbol: "point.topleft.down.to.point.bottomright.curvepath.fill")
                    if Position.canSwitchRoutes(model.marks) {
                        Button(model.useAlternate ? StreetMap.backToMain : StreetMap.useAlternate,
                               systemImage: "arrow.triangle.swap") { model.useAlternate.toggle() }
                            .pmAction(fullWidth: false)  // the app's action look and a full-size target
                    }
                }
                if ways.isEmpty {
                    Text(RallyWords.noneOnMap(canEdit: MapMarkAsk.mayChange)).font(.pmNote)
                        .foregroundStyle(PrepareMeColors.text2)
                } else if model.heading == nil {
                    Text(StreetMapWords.northUpShort).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                }
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Position.latLon(here.coordinate.latitude, here.coordinate.longitude))
                            .font(.pmNote.monospacedDigit()).textSelection(.enabled)
                        if let grid = Position.usng(here.coordinate.latitude, here.coordinate.longitude) {
                            Text("USNG \(grid)").font(.pmNote.monospacedDigit()).textSelection(.enabled)
                        }
                        StreetMapFixLine(here: here).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    }
                    Spacer(minLength: 0)
                    StreetMapShare(here: here)
                }
            } else {
                if let rally = model.plannedOrFirst {
                    Label(rally.name, systemImage: "flag.fill").font(.pmHeadline).lineLimit(textSize.isAccessibilitySize ? nil : 2)
                }
                LocationLine(model: model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A meeting place's or a route's row: the arrow, the name (a meeting place's as "Meet at …"), how far, then Drive
    /// and Walk under the lines so the row stays readable (the map pins plan, Task 2.2).
    func wayRow(_ way: Position.Way, symbol: String, meeting: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "location.north.fill")
                .rotationEffect(.degrees(model.arrow(for: way)))
                .font(.pmTitle)
                .foregroundStyle(PrepareMeColors.ink)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Label(meeting ? RallyWords.meetAt(way.mark.name) : way.mark.name, systemImage: symbol)
                    .font(.pmHeadline).lineLimit(textSize.isAccessibilitySize ? nil : 2)
                if let off = model.offRoute(way) {  // more than about a block off: the way back, in amber (task 2.2)
                    // wraps, never cut: the direction comes last (the W9 review)
                    Label(off, systemImage: "exclamationmark.triangle.fill").font(.pmNote)
                        .foregroundStyle(PrepareMeColors.caution).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(StreetMapWords.brief(way)).font(.pmNote).lineLimit(textSize.isAccessibilitySize ? nil : 2)
                }
                if let dark = model.afterDark(way) {
                    Label(dark, systemImage: "moon.fill").font(.pmNote).foregroundStyle(PrepareMeColors.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
                StreetMapGo(model: model, to: (way.nearest[1], way.nearest[0]), name: way.mark.name, compact: true)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .onTapGesture { model.showSpot(longitude: way.nearest[0], latitude: way.nearest[1]) }
        .accessibilityAction(named: "Show on map") {  // the tap, for VoiceOver (guidelines plan, phase 4)
            model.showSpot(longitude: way.nearest[0], latitude: way.nearest[1])
        }
    }
}

/// The strip's card, folded or whole: padded, on a material, and set in from the screen's edge.
private struct StripCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(12)
    }
}

/// Over the strip once the fix is two minutes old (the street map fixes plan, task 1.1): GPS was lost, how long ago,
/// and that the distances are from the old spot. Caution amber; the minutes kept current while on screen.
struct StreetMapStaleBanner: View {
    let here: CLLocation

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Label(Position.staleWords(taken: here.timestamp, now: context.date), systemImage: "location.slash.fill")
                .font(.pmNote.weight(.semibold))
                .foregroundStyle(PrepareMeColors.caution)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The street map's line while it has no fix (Task 11.3; F25, F66): unasked, the why line and Use my location, the one
/// place the phone's system question comes from; refused, where to turn it on and the button to Settings; else that
/// it is finding where the phone is.
struct LocationLine: View {
    @ObservedObject var model: StreetMapModel
    var centered = false

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 8) {
            Text(model.locationWords).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                .multilineTextAlignment(centered ? .center : .leading)
            switch LocationAsk.offer(model.locationStatus) {
            case .ask: Button(LocationAsk.allow) { model.askLocation() }.pmAction(fullWidth: false)
            case .settings: Button(LocationAsk.turnOn) { Self.openSettings() }.pmAction(fullWidth: false)
            case .none: EmptyView()
            }
        }
    }

    /// PrepareMe's own page in Settings, where its Location switch is.
    static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// Share this spot (owner, 2026-10-14, by click): nothing leaves the phone unless someone taps it and picks where.
struct StreetMapShare: View {
    let here: CLLocation

    var body: some View {
        ShareLink(item: Position.shareText(latitude: here.coordinate.latitude, longitude: here.coordinate.longitude,
                                           accuracy: here.horizontalAccuracy, taken: here.timestamp)) {
            Label("Share this spot", systemImage: "square.and.arrow.up")
        }
        .pmAction(fullWidth: false)  // beside the position's lines (review)
    }
}

// MARK: The simple view (phones paired read-only)

struct StreetMapSimpleView: View {
    @ObservedObject var model: StreetMapModel
    let role: RallyWords.Role  // a child's phone asks a grown-up when there's no rally point; no copy says so
    let showMap: (() -> Void)?  // nil when the map file isn't on this phone: where to get it instead
    @State private var lost = false
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        Group {
            // At the accessibility sizes the meeting place fills the first screen, so I'm lost sits in the bottom bar
            // there, never scrolled away (owner, 2026-11-15); at the other sizes it stays under the meeting place
            if textSize.isAccessibilitySize {
                page.pmBar(.bottom) { lostButton.padding(.horizontal).padding(.vertical, 8) }
            } else {
                page
            }
        }
        .sheet(isPresented: $lost) { lostSheet }
    }

    private var lostButton: some View {
        Button { lost = true } label: {
            Text("I'm lost: show my place number").font(.pmTitle).frame(maxWidth: .infinity).padding()
        }
        .pmProminent()
        .disabled(model.here == nil)
    }

    private var page: some View {
        ScrollView {
            VStack(spacing: 20) {
                if model.here != nil, let rally = model.rallyWay(model.currentWays) {
                    Text("Your meeting place").font(.pmTitle)
                    Image(systemName: "location.north.fill")
                        .resizable().scaledToFit()
                        .frame(width: textSize.isAccessibilitySize ? 80 : 140,  // the name stays on the first screen
                               height: textSize.isAccessibilitySize ? 80 : 140)
                        .rotationEffect(.degrees(model.arrow(for: rally)))
                        .foregroundStyle(PrepareMeColors.ink)
                        .accessibilityHidden(true)
                    Text(rally.mark.name).font(.pmLargeTitle).multilineTextAlignment(.center)
                    Text("\(Position.distance(rally.meters)) \(Position.compass(rally.bearing))").font(.pmCount)
                    if let here = model.here {  // how far to trust it, and its age once a minute old (task 1.1)
                        StreetMapFixLine(here: here).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                            .multilineTextAlignment(.center)
                    }
                    if model.heading == nil {
                        Text(StreetMapWords.northUp).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                            .multilineTextAlignment(.center)
                    }
                    if !rally.mark.note.isEmpty { Text(rally.mark.note).multilineTextAlignment(.center) }
                } else if let rally = model.plannedOrFirst {  // no fix yet: where to go never waits on GPS
                    Text("Your meeting place").font(.pmTitle)
                    Text(rally.name).font(.pmLargeTitle).multilineTextAlignment(.center)
                    if !rally.note.isEmpty { Text(rally.note).multilineTextAlignment(.center) }
                    LocationLine(model: model, centered: true)
                } else {  // no rally point to show: said whether or not the phone has found itself (phase 2 review)
                    Text(RallyWords.noRallyPoint(role, device: StreetMapWords.device)).font(.pmHeadline)
                        .multilineTextAlignment(.center)
                    if model.here == nil {
                        LocationLine(model: model, centered: true)
                    }
                }
                if !textSize.isAccessibilitySize { lostButton }
                if model.here == nil, model.locationStatus == .allowed {  // why it's grey (Task 11.4; F26); refused or
                    // unasked, the location line above says why
                    Text(RallyWords.lostWaits(device: StreetMapWords.device)).font(.pmNote)
                        .foregroundStyle(PrepareMeColors.text2).multilineTextAlignment(.center)
                }
                let others = Position.ordered(model.marks).filter { $0.kind == .rally && $0.id != model.shownRally?.id }
                if !others.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Other meeting places").font(.pmHeadline)
                        ForEach(others) { mark in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mark.name).font(.pmBody.bold())
                                if let role = mark.role { Text(role.words).font(.pmNote).foregroundStyle(PrepareMeColors.text2) }
                                if !mark.note.isEmpty { Text(mark.note).font(.pmNote) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let showMap {
                    Button("Show the map", action: showMap).pmAction()
                } else {
                    Text(RallyWords.mapNotHere(device: StreetMapWords.device)).font(.pmNote)
                        .foregroundStyle(PrepareMeColors.text2).multilineTextAlignment(.center)
                    Button("Open Downloads") { PrepareMeTabs.shared.openHomeMac() }.pmAction()
                }
            }
            .padding()
        }
    }

    private var lostSheet: some View {
        ScrollView {  // scrolls at the large text sizes, Done included (spec section 8, fix 1)
            VStack(spacing: 16) {
                Text("Read this out to whoever is helping you").font(.pmTitle).multilineTextAlignment(.center)
                if let here = model.here {
                    if let grid = Position.usng(here.coordinate.latitude, here.coordinate.longitude) {
                        Text(grid).font(.pmPlaceNumber)
                            .multilineTextAlignment(.center).textSelection(.enabled)
                        Text("That's a US National Grid number.").foregroundStyle(PrepareMeColors.text2)
                    }
                    Text(Position.latLon(here.coordinate.latitude, here.coordinate.longitude))
                        .font(.pmTitle.monospacedDigit()).textSelection(.enabled)
                    StreetMapFixLine(here: here).foregroundStyle(PrepareMeColors.text2)
                    StreetMapShare(here: here).font(.pmBody)
                }
                Button("Done") { lost = false }.pmAction()
            }
            .padding()
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(PrepareMeColors.ground)  // solid: nothing behind the number shows through
    }
}

// MARK: What the phone hands the shared model

extension StreetMapPlatform {
    /// The phone's: its own library and copy of the inventory, its own storm reading, Find a map on the Maps tab, and
    /// its compass.
    static var phone: StreetMapPlatform {
        StreetMapPlatform(record: { PrepareMeLibrary.shared.record },
                          marks: { PhoneInventoryModel.shared.shown?.mapMarks ?? [] },
                          pins: { PhoneInventoryModel.shared.shown?.pins ?? [] },
                          warningShapes: { LiveConditions.shared.warningShapes() },
                          openTopo: { PrepareMeTabs.shared.open($0, in: .maps) },
                          canOpen: { UIApplication.shared.canOpenURL($0) },
                          open: { UIApplication.shared.open($0) },
                          heading: true, locates: true, directions: true)
    }
}

extension PhoneInventoryModel {
    /// Event mode as this phone shows it: its own switch while one waits or holds, else the Mac's copy. Only On counts
    /// (Auto turns on with any warning, which isn't an evacuation). The street map's arrow and Today's rally line.
    var eventModeOn: Bool { (localEventMode ?? shown?.lists?.eventMode) == "On" }
}

/// The kids' arrow, which only the phone's strip and simple view show.
extension StreetMapModel {
    /// Event mode as this phone shows it (PhoneInventoryModel.eventModeOn).
    var eventOn: Bool { PhoneInventoryModel.shared.eventModeOn }

    /// The rally point the arrow points to (owner, 2026-10-14): by role and Event mode, else the nearest.
    func rallyWay(_ ways: [Position.Way]) -> Position.Way? {
        if let planned = Position.planned(marks, eventOn: eventOn), let way = ways.first(where: { $0.mark.id == planned.id }) {
            return way
        }
        return ways.first { $0.mark.kind == .rally }
    }

    /// The rally point named before the phone knows where it is: the planned one, else the first in role order.
    var plannedOrFirst: MapMark? { Position.plannedOrFirst(marks, eventOn: eventOn) }

    /// The rally point the simple view shows at the top.
    var shownRally: MapMark? {
        if here != nil, let way = rallyWay(currentWays) { return way.mark }
        return plannedOrFirst
    }
}

/// "Show on street map" beside each map of Find a map (owner, 2026-10-14, by click: in PrepareMe only, so Kiwix
/// readers of the same pages never see a link they can't follow): added as the page is shown, from the corners each
/// link already carries (`data-bounds`, packer/map_pages.py), and only on a phone that holds the street map.
@MainActor
enum StreetMapLinks {
    static let script = """
    (function () {
      if (document.querySelector('a.pm-show-street')) return;
      document.querySelectorAll('a[data-bounds]').forEach(function (a) {
        var box = a.getAttribute('data-bounds').trim().split(/\\s+/);
        if (box.length !== 4) return;
        var show = document.createElement('a');
        show.className = 'pm-show-street';
        show.href = 'prepareme://streetmap?bounds=' + box.join(',');
        show.textContent = 'Show on street map';
        show.style.marginLeft = '0.6em';
        show.style.fontSize = '0.85em';
        show.style.whiteSpace = 'nowrap';
        a.insertAdjacentElement('afterend', show);
      });
    })();
    """

    static func pageFinished(_ webView: WKWebView) {
        guard webView.url?.lastPathComponent == TopoIndex.page,
              StreetMap.heldFile(PrepareMeLibrary.shared.store.record,
                                 in: PrepareMeLibrary.shared.store.libraryFolder) != nil else { return }
        webView.evaluateJavaScript(script)
    }

    /// The area a "Show on street map" link names, as west, south, east, north, or nil when it names none.
    nonisolated static func bounds(_ url: URL) -> [Double]? {
        StreetMap.area(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "bounds" })?.value)
    }
}
#endif

/// The street map's fixed words, on the phone and the Mac.
enum StreetMapWords {
    static let empty = Data(#"{"type":"FeatureCollection","features":[]}"#.utf8)

    /// The device the screen is on, in its words ("None of the topo maps on this Mac").
    #if os(iOS)
    @MainActor static var device: String { ThisDevice.word }  // "iPad" on an iPad
    /// This device as a mark's `by` holds it (MapMarkWords.added: "Added Nov 12 on this phone").
    @MainActor static var here: String { MapMark.by(device: MacLink.device) }
    /// The owner's name for the phone that added a mark, as the Mac sent it with the mark (owner, 2026-11-12).
    @MainActor static func maker(_ mark: MapMark) -> String? { mark.byName }
    #else
    static let device = "Mac"
    /// This device as a mark's `by` holds it (MapMarkWords.added: "Added Nov 12 on this Mac").
    static let here = MapMark.byMac
    /// The owner's name for the phone that added a mark, from Settings › Phones (owner, 2026-11-12).
    @MainActor static func maker(_ mark: MapMark) -> String? { mark.makerName(PhonePairing.shared.makers()) }
    #endif

    #if os(macOS)
    /// The Mac's Where am I line with no fix, or one older than `Position.freshFix` (Mac sidebar plan, task 12;
    /// pinned in app/Service by PositionTests). The phone keeps its own words (StreetMapModel.locationWords).
    static let noFix = Position.macNoFix
    /// The same, when location is off for PrepareMe (denied or restricted), with where to turn it on (fix round 1).
    static let locationOff = Position.macLocationOff
    #endif

    /// Layers' conditions switch: the Mac draws no storm outlines (they come from a phone's own alerts).
    #if os(iOS)
    static let conditionsLayer = "Conditions (roads, rivers, storms)"
    #else
    static let conditionsLayer = "Conditions (roads and rivers)"
    #endif

    /// Under an arrow when the phone has no compass reading: the arrow then assumes the top of the phone faces north.
    // plain words for a child (Task 11.4; F26): what to do, not what the phone assumes
    @MainActor static var northUp: String { "No compass: the arrow is right when the top of the \(device) faces north." }
    static let northUpShort = "No compass: the arrows are right with the phone's top facing north."  // the map turns

    static func kind(_ kind: String) -> String { PlaceIndex.kindWords(kind) }

    /// Under an unnamed place found by what it is.
    static let notChecked = "from OpenStreetMap, not checked"

    /// Under a search result: how far and which way from here when the phone knows ("0.3 miles north"), then what it
    /// is for a named place, or that an unnamed one is OpenStreetMap's, not checked (its title already says what it is).
    static func found(_ place: PlaceIndex.Place, from here: CLLocationCoordinate2D?) -> String {
        var parts: [String] = []
        if let here {
            let a = (here.latitude, here.longitude), b = (place.latitude, place.longitude)
            parts.append("\(Position.distance(Position.meters(from: a, to: b))) \(Position.compass(Position.bearing(from: a, to: b)))")
        }
        parts.append(place.name.isEmpty ? notChecked : PlaceIndex.kindWords(place.kind))
        return parts.joined(separator: ", ")
    }

    /// Under a route: Organic Maps can't follow it (an audit, 2026-10-14).
    static let ownRoads = "Directions go to where you'd join it; Organic Maps picks its own roads, so follow the green line."

    /// "0.8 miles northwest, straight line; at least 20 to 35 min on foot", or for a route where you'd join it and how
    /// far along it to its end.
    /// One line for the strip along the bottom: "5.5 miles northwest, 2 h 15 min+ on foot"; for a route, where you'd
    /// join it and how far along it. The list has the whole of it (`how`).
    static func brief(_ way: Position.Way) -> String {
        let there = "\(Position.distance(way.meters)) \(Position.compass(way.bearing))"
        guard let toEnd = way.toEnd else { return there + ", \(Position.walkTime(way.meters))+ on foot" }
        return "Joins it \(there), then \(Position.distance(toEnd))"
    }

    static func how(_ way: Position.Way) -> String {
        let there = "\(Position.distance(way.meters)) \(Position.compass(way.bearing))"
        guard let toEnd = way.toEnd else {
            return there + ", straight line; " + Position.onFoot(way.meters, straightLine: true)
        }
        return "Joins it \(there); then \(Position.distance(toEnd)) to its end, "
            + Position.onFoot(toEnd, straightLine: false)
    }

    /// "As of 3:10 PM", and why it's dimmed when it's old.
    static func asOf(_ iso: String, old: Bool) -> String {
        guard let when = ISO8601DateFormatter().date(from: iso) else { return "Time unknown" }
        let words = "As of " + when.formatted(date: Calendar.current.isDateInToday(when) ? .omitted : .abbreviated,
                                              time: .shortened)
        return old ? words + ": over 8 hours old, so it's dimmed" : words
    }
}
