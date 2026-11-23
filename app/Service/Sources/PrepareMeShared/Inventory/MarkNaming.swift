/// The Mac's naming sheet, asked once a pin, route or Start point is placed (the map pins plan, Task 3.1): a new pin
/// starts with its Kind, Meeting place (a rally point), a look (its name, symbol and color filled), or Make your own
/// (blank, where it starts). A route or the Start point has no Kind. `mark` is what Save keeps.
public struct MarkNaming: Equatable, Sendable {
    public enum Pick: Hashable, Sendable { case meeting, look(PinLook), own }

    public let draft: MapMark
    public private(set) var pick: Pick?
    public var name = ""
    public var note = ""
    public var role: MapMark.Role?
    public var routeRole: MapMark.RouteRole?
    public var symbol = "mappin"
    public var color = "accent"
    private var filled: String?  // the name a look filled: the next pick clears it, never a name typed

    /// `startRole`: a meeting place's role to start on (Position.newRallyRole: Near home for the first; F27).
    public init(draft: MapMark, startRole: MapMark.Role?) {
        self.draft = draft
        role = startRole
        switch draft.kind {
        case .pin: pick = .own
        case .rally: pick = .meeting
        case .route, .start: pick = nil
        }
    }

    public var kind: MapMark.Kind {
        switch pick {
        case .meeting?: .rally
        case .look?, .own?: .pin
        case nil: draft.kind
        }
    }

    public mutating func choose(_ now: Pick) {
        guard pick != nil else { return }
        if let filled, name == filled { name = "" }
        filled = nil
        pick = now
        switch now {
        case .look(let look):
            (name, symbol, color) = (look.name, look.symbol, look.color)
            filled = look.name
        case .own:
            (symbol, color) = ("mappin", "accent")
        case .meeting:
            break
        }
    }

    public var mark: MapMark {
        var mark = draft
        mark.kind = kind
        (mark.name, mark.note) = (name.trimmingCharacters(in: .whitespaces), note)
        (mark.role, mark.routeRole) = (kind == .rally ? role : nil, kind == .route ? routeRole : nil)
        (mark.pinSymbol, mark.pinColor) = kind == .pin ? (symbol, color) : (nil, nil)
        return mark
    }
}
