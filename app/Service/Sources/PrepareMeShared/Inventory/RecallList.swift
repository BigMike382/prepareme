import Foundation

/// The Mac's Recalls list (top-ten plan phase 6, Task 6.3; the owner's fix 1, 2026-10-16: recalls left Today for the
/// Inventory window): the open recalls in the lists job's order, then the cleared ones (a Status picked) in a closed
/// fold at the foot, where one can be set back to open. A Mac-only item's row carries no title or brand in the lists
/// (items step 2); on the Mac it is named by its inventory item and its recall's title from `Lists.macOnlyRecalls`,
/// never on a phone.
public enum RecallList {
    /// readiness/listrows.py's MAC_ONLY_ITEM, copied (readiness/tests/test_applists.py pins it)
    public static let macOnlyItem = "Mac-only item, inventory row {row}"
    /// The matches are the script's, never CPSC's word (CPSC's terms; Today's recalls panel said it until Task 6.2)
    public static let ours = "These matches are made by a plain script from the brands and model numbers on our list; "
        + "CPSC hasn't checked them."

    public static func isOpen(_ row: ListRow) -> Bool { row["Status"].isBlank }

    /// The open recalls, then the cleared, each in the lists job's order
    public static func split(_ rows: [ListRow]) -> (open: [ListRow], cleared: [ListRow]) {
        (rows.filter(isOpen), rows.filter { !isOpen($0) })
    }

    public static func clearedHeading(_ count: Int) -> String { "Cleared (\(count))" }

    /// The Inventory window's sidebar row: "Recalls (n)", n the open ones; shown while any recall is listed, open or
    /// cleared (so a cleared one can be set back), nil when none is
    public static func sidebar(_ rows: [ListRow]) -> String? {
        rows.isEmpty ? nil : "Recalls (\(rows.filter(isOpen).count))"
    }

    /// Whether a row is a Mac-only item's: by its Item cell or by its ID among the lists' Mac-only recalls (review: never
    /// the Item text alone), so it never reaches a phone
    public static func isMacOnly(_ row: ListRow, in lists: Lists) -> Bool {
        macOnlyRow(row) != nil || lists.macOnlyRecalls[row.id] != nil
    }

    /// A Mac-only item's inventory row, read from its Item cell; nil for any other row
    public static func macOnlyRow(_ row: ListRow) -> Int64? {
        let parts = macOnlyItem.components(separatedBy: "{row}")
        let text = row["Item"].text
        guard parts.count == 2, text.hasPrefix(parts[0]), text.hasSuffix(parts[1]) else { return nil }
        return Int64(text.dropFirst(parts[0].count).dropLast(parts[1].count))
    }

    /// The serial numbers of a recall's item on this Mac (step 6, part 1), to compare by eye with any serial range the
    /// recall names (nothing matches them): a Mac-only item's by its inventory row (its place in the list, as the lists
    /// job numbers rows, never its stored id: the two drift apart after a delete; the review), any other's by every
    /// item of its name (two items of one name show both); blank ones left out. Never on a phone: the phones' copy has
    /// no serials.
    public static func serials(_ row: ListRow, in inventory: Inventory) -> [String] {
        guard let column = inventory.items.column(Insurance.serial) else { return [] }
        let items: [InventoryRow]
        if let inventoryRow = macOnlyRow(row) {
            items = inventory.itemRows.filter { Int64($0.position) == inventoryRow }
        } else {
            let name = row["Item"].text
            items = name.isEmpty ? [] : inventory.itemRows.filter { inventory.name(ofItem: $0) == name }
        }
        return items.map { InventoryValues.plain($0[column]).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The serials as a recall's row shows them, under its title; nil when there are none.
    public static func serialLine(_ serials: [String]) -> String? {
        serials.isEmpty ? nil : "Serial number\(serials.count == 1 ? "" : "s"): \(serials.joined(separator: ", "))"
    }

    /// A row as the Mac shows it: its item, its recall's title and its page (https only). A Mac-only row is named by
    /// its inventory item (`itemName`, given the row's place in the list: `macOnlyRow`) and titled from the lists' Mac-only recalls, falling back to its own cells.
    public static func shown(_ row: ListRow, in lists: Lists,
                             itemName: (Int64) -> String?) -> (item: String, recall: String, link: URL?) {
        var item = row["Item"].text, recall = row["Recall"].text, link = row["Link"].text
        if let inventoryRow = macOnlyRow(row) {
            if let name = itemName(inventoryRow), !name.isEmpty { item = name }
            if let mine = lists.macOnlyRecalls[row.id] {
                recall = mine.title
                link = mine.link
            }
        }
        let page = URL(string: link).flatMap { $0.scheme == "https" && $0.host != nil ? $0 : nil }
        return (item, recall, page)
    }
}
