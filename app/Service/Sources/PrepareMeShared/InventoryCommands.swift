import Foundation

/// What the Mac's Inventory works on for the table shown and its selection (the Apple guidelines plan, phase 2): the
/// toolbar and the Inventory menu both read it, so a button and its menu item can't disagree. Apple's menu bar page:
/// every toolbar item is a menu command too, dimmed when it doesn't apply, never hidden.
public struct InventoryCommands: Equatable, Sendable {
    /// The table shown: "Inventory" for All items and every view of items, else Locations or Categories.
    public let table: String
    /// A grab view (Grab in 10 minutes, Grab in an hour), which prints grab sheets.
    public let grabView: Bool
    /// How many rows are selected.
    public let selected: Int
    /// The table is unlocked by Edit Table, so a click changes a cell (the inventory fresh look, spec 5.2).
    public let editing: Bool
    /// One place's own table of items (phase 3), which prints that place's label and grab sheet.
    public let placeView: Bool
    /// Inventory's home page (phase 3), with no table on screen.
    let onHome: Bool

    public init(table: String, grabView: Bool, selected: Int, editing: Bool = false, placeView: Bool = false) {
        self.init(table: table, grabView: grabView, selected: selected, editing: editing, placeView: placeView,
                  onHome: false)
    }

    init(table: String, grabView: Bool, selected: Int, editing: Bool, placeView: Bool, onHome: Bool) {
        (self.table, self.grabView, self.selected) = (table, grabView, selected)
        (self.editing, self.placeView, self.onHome) = (editing, placeView, onHome)
    }

    /// Inventory's home page (phase 3, board 1): New Item… and Add by Barcode… (on All Items), Print's blank sheet,
    /// every bin's labels and the grab sheets, Export CSV… and Remove Empty Places… (the owner's choice A,
    /// 2026-11-18: Inventory opens there); Edit Table and Columns, which need a table on screen, dimmed.
    public static let home = InventoryCommands(table: "Inventory", grabView: false, selected: 0, editing: false,
                                               placeView: false, onHome: true)

    /// Edit Table and Columns act on the table on screen: none on the home page.
    public var canEditTable: Bool { !onHome }
    public var canChooseColumns: Bool { !onHome }
    /// Export CSV… saves every table, and Remove Empty Places… looks over every place, whatever shows.
    public var canExportCSV: Bool { true }
    public var canRemoveEmptyPlaces: Bool { true }

    /// The items open locked; Locations and Categories open unlocked, since typing names is what they are for.
    public static func startsEditing(table: String) -> Bool { table != "Inventory" }

    var items: Bool { table == "Inventory" }

    /// Add: the New item form on the items (so its "…"), a new row straight in on Locations and Categories.
    public var canAdd: Bool { true }
    public var addTitle: String { items ? "New Item…" : "New Row" }
    public var canAddByBarcode: Bool { items }
    public var canOpenForm: Bool { items && selected == 1 }
    public var canDelete: Bool { selected > 0 }
    /// Several rows ask first, so the command takes its "…" (`docs/design/menus.md`).
    public var deleteTitle: String { selected > 1 ? "Delete…" : "Delete" }
    /// A stray Delete key never deletes from a locked table; the menu and the right-click still do.
    public var deleteKeyWorks: Bool { editing && canDelete }
    public var editTitle: String { editing ? "Done" : "Edit Table" }
    /// The menu bar's item, away from the table it finishes, says what it finishes (fix round 1).
    public var editMenuTitle: String { editing ? "Done Editing Table" : "Edit Table" }
    /// The sign beside Edit Table while the items are locked (owner, 2026-11-17, by click, after the review); nil once
    /// Edit Table is pressed (the bar takes over) and on Locations and Categories, which open unlocked.
    public var lockedSign: String? { items && !editing && !onHome ? "Locked" : nil }
    public var lockedSignSpoken: String { "Locked. Press Edit Table to change cells." }
    /// The selected rows still on screen: a row a search hid stays selected in the table, and must never be
    /// deleted unseen (phase 1 fixes round 2, finding F).
    public static func onScreen(_ selected: Set<Int64>, shown: [Int64]) -> Set<Int64> {
        selected.intersection(shown)
    }
    public var canPrintBlankSheet: Bool { items }
    public var canPrintLabels: Bool { table == "Locations" || placeView || onHome }
    public var canPrintGrabSheets: Bool { table == "Locations" || grabView || placeView || onHome }
    /// How many labels Print's labels item names: the place's own one on its table (phase 3), else the places picked on
    /// Locations, 0 meaning every bin's; never the items picked, which aren't places.
    public var labelCount: Int { placeView ? 1 : table == "Locations" ? selected : 0 }
}
