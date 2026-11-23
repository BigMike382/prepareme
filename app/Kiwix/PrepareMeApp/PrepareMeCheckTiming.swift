// The check build only: PREPAREME_CHECK_TIMING=<file in the check home> times the inventory's table, for the inventory
// fresh look's phase 1 fixes (finding 6). Ten of each after a first left out, the median written: a switch between All
// items and a category's view, a click selecting a row (the app's own queued events; the real pointer never moves),
// and a save of one cell with the ID check. Each ends once the table shows it and the window has laid out and drawn.
// Kept apart so the same file times an older build too (phase 0's probe wasn't kept).
#if PREPAREME_CHECK
import AppKit
import PrepareMeShared

@MainActor
enum PrepareMeCheckTiming {
    static func start(_ path: String) {
        Task {
            try? await Task.sleep(for: .seconds(14))  // the inventory open and its first table settled
            let lines = await run()
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    static func table(_ window: NSWindow) -> NSTableView? {
        func tables(_ view: NSView) -> [NSTableView] { (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables) }
        return window.contentView.map(tables)?.first { $0.tableColumns.first?.title == "#" }
    }

    /// Polls every 2 ms until `done` (at most 5 s), then lays out and draws what is waiting.
    static func settle(_ window: NSWindow, until done: () -> Bool) async -> Bool {
        let limit = Date().addingTimeInterval(5)
        while !done() {
            if Date() > limit { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        window.layoutIfNeeded()
        window.displayIfNeeded()
        return true
    }

    static func median(_ values: [Double]) -> String {
        let sorted = values.sorted(), middle = sorted.count / 2
        guard !sorted.isEmpty else { return "none" }
        let value = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        return String(format: "%.0f ms", value)
    }

    static func run() async -> [String] {
        let model = InventoryModel.shared
        guard case .ready(let inventory) = model.state, let window = PrepareMeMacTabs.shared.window,
              let categoryColumn = inventory.items.column(Inventory.Label.category),
              let category = inventory.names(for: categoryColumn).keys.min(),
              let brand = inventory.items.column("Brand")
        else { return ["not ready: no inventory, window, category or Brand"] }
        var lines = ["rows \(inventory.itemRows.count), window \(window.frame.size)"]
        var switches: [Double] = [], clicks: [Double] = [], saves: [Double] = []
        for round in 0..<11 {  // the first is left out
            let before = table(window), count = before?.numberOfRows ?? -1
            let start = CACurrentMediaTime()
            model.requestedPick = round.isMultiple(of: 2) ? .view(.category(category)) : .table("Inventory")
            let ok = await settle(window) { let now = table(window); return now != nil && (now !== before || now?.numberOfRows != count) }
            if round > 0, ok { switches.append((CACurrentMediaTime() - start) * 1000) }
            try? await Task.sleep(for: .milliseconds(400))
        }
        model.requestedPick = .table("Inventory")
        try? await Task.sleep(for: .seconds(1))
        for round in 0..<11 {
            guard let shown = table(window) else { break }
            let row = 3 + round
            let point = shown.convert(NSPoint(x: shown.rect(ofRow: row).midX, y: shown.rect(ofRow: row).midY), to: nil)
            let start = CACurrentMediaTime()
            // the release queued, then the press handed to the window: the table's press waits for its release
            // (two queued events never selected a row)
            func click(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            if let up = click(.leftMouseUp), let down = click(.leftMouseDown) {
                NSApp.postEvent(up, atStart: false)
                window.sendEvent(down)
            }
            let ok = await settle(window) { table(window)?.selectedRow == row }
            if round > 0, ok { clicks.append((CACurrentMediaTime() - start) * 1000) }
            if !ok { lines.append("click \(round): row \(row) asked, \(table(window)?.selectedRow ?? -9) selected") }
            try? await Task.sleep(for: .milliseconds(300))
        }
        for round in 0..<11 {
            guard let first = inventory.itemRows.first else { break }
            let start = CACurrentMediaTime()
            _ = await model.apply(.set(table: "Inventory", row: first.id, colId: brand.colId,
                                       value: .text(round.isMultiple(of: 2) ? "Timing A" : "Timing B")),
                                  undo: nil, name: "Timing")
            window.layoutIfNeeded()
            window.displayIfNeeded()
            if round > 0 { saves.append((CACurrentMediaTime() - start) * 1000) }
            try? await Task.sleep(for: .milliseconds(300))
        }
        lines.append("table switch: median \(median(switches)) of \(switches.count): "
                     + switches.map { String(format: "%.0f", $0) }.joined(separator: ", "))
        lines.append("selection click: median \(median(clicks)) of \(clicks.count): "
                     + clicks.map { String(format: "%.0f", $0) }.joined(separator: ", "))
        lines.append("save: median \(median(saves)) of \(saves.count): "
                     + saves.map { String(format: "%.0f", $0) }.joined(separator: ", "))
        return lines
    }
}
#endif
