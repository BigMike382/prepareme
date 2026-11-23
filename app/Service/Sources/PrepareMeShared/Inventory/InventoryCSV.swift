import Foundation

/// Every table of the inventory as CSV (plan phase 7: "a CSV export of every table", the owner's own copy and Grist's
/// archive), each cell as the editor shows it: a reference as the name it points at, a date as 2026-11-15, a tick as
/// Yes. Private rows are included: the files go where the owner saves them on the Mac, never to a phone.
public enum InventoryCSV {
    /// (file name, CSV text) for each table, in the editor's order.
    public static func export(_ inventory: Inventory) -> [(name: String, text: String)] {
        InventoryFile.tableNames.map { name in
            let table = inventory.table(name)
            var lines = [table.columns.map { field($0.label) }.joined(separator: ",")]
            for row in inventory.rows(name) {
                lines.append(table.columns.map { column in
                    field(InventoryValues.shown(row[column], in: column, names: inventory.names(for: column)))
                }.joined(separator: ","))
            }
            return ("\(name).csv", lines.joined(separator: "\r\n") + "\r\n")
        }
    }

    /// A field quoted when it holds a comma, quote or line break (RFC 4180).
    static func field(_ text: String) -> String {
        guard text.contains(where: { ",\"\r\n".contains($0) }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
