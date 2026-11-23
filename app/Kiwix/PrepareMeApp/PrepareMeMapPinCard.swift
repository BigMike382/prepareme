import PrepareMeShared
import SwiftUI

/// One card for any pin, meeting place or route (the map pins plan, Task 2.3; the spec's "One card"): its picture and
/// name, its note, a meeting place's which one and the kids line, how far and which way when the device knows where it
/// is, who added it and when (or Waiting for the Mac), then Drive, Walk and More. A tap on the map and a tap in the
/// Pins list open the same card, so a pin's choices live in one place. The Mac's popover shows it too, with no Edit.
struct MapPinCard: View {
    @ObservedObject var model: StreetMapModel
    let mark: MapMark
    let close: () -> Void
    @State private var ask: MapMarkAsk?

    var body: some View {
        let way = model.way(to: mark)
        VStack(alignment: .leading, spacing: 6) {
            Label { Text(mark.name) } icon: { MapPinPicture(mark: mark) }
                .font(.pmHeadline)  // the Mac's popover too: .headline is 13 points there (phase L, finding 2)
            if !mark.note.isEmpty { Text(mark.note) }
            switch mark.kind {
            case .rally:
                Text(mark.role?.words ?? MapMarkWords.anotherPlace).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                if model.kidsTarget == mark.id { Text(MapMarkWords.kidsPointHere).font(.pmNote) }
            case .route:
                if let role = mark.routeRole {
                    Text(role.words).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                }
                if model.platform.directions {  // Drive and Walk go to where you'd join it (an audit, 2026-10-14)
                    Text(StreetMapWords.ownRoads).font(.pmNote).fixedSize(horizontal: false, vertical: true)
                }
            case .start:
                Text(StreetMap.startPoint).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            case .pin:
                EmptyView()
            }
            if let way {
                Text(StreetMapWords.how(way)).font(.pmNote).fixedSize(horizontal: false, vertical: true)
                if let dark = model.afterDark(way) {
                    Label(dark, systemImage: "moon.fill").font(.pmNote).foregroundStyle(PrepareMeColors.caution)
                }
            }
            if let line = Self.added(mark) { Text(line).font(.pmNote).foregroundStyle(PrepareMeColors.text2) }
            if model.platform.directions, mark.kind != .start, let spot = model.goSpot(mark) {
                StreetMapGo(model: model, to: spot, name: mark.name).padding(.top, 4)
            }
            HStack {  // a plain Menu with .fixedSize() drew only its icon in a tall empty row (owner's iPhone, 2026-11-12)
                Menu("More", systemImage: "ellipsis.circle") { MapMarkActions(model: model, mark: mark, ask: $ask).equatable() }
            }
            .pmAction()
            .dynamicTypeSize(...StreetMapDirectionsRow.cap)  // as Drive and Walk above it
        }
        .mapMarkAsk($ask, done: close)
    }

    /// Waiting for the Mac (made on this phone, no row yet), else who added it and when; nil with no record of it.
    static func added(_ mark: MapMark) -> String? {
        if mark.id < 0 { return MapMarkWords.waiting }
        return MapMarkWords.added(mark, here: StreetMapWords.here, device: StreetMapWords.device,
                                  name: StreetMapWords.maker(mark))
    }
}

/// A mark's picture: a pin's own symbol on its color, a meeting place's flag on green (as the map draws it, Task 2.6),
/// a route's or the Start point's symbol alone.
struct MapPinPicture: View {
    let mark: MapMark

    var body: some View {
        switch mark.kind {
        case .pin: StreetMapPinIcon(mark)
        case .rally: StreetMapPinIcon(symbol: "flag.fill", color: "ok-mark")
        case .route, .start: Image(systemName: mark.symbol).frame(width: 30).accessibilityHidden(true)
        }
    }
}
