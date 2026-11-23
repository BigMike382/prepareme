// This file is part of Kiwix (PrepareMe), a local build of Kiwix for one household's Mac.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(iOS)
import UIKit
import Testing
@testable import Kiwix

/// PrepareMe (owner's iPhone, 2026-11-20: a guide found in search, tapped, and the Guides tab still on its guide list).
/// A memory warning dropped every tab's model made more than 6 minutes before from the cache, while the screen kept
/// showing the one it held; the next `getCached`, which a tapped search result opens into, made a second model, so the
/// guide opened in a page no screen showed. The tab keeps its one model through a memory warning.
@MainActor
struct PrepareMeMemoryWarningTests {
    @Test func aMemoryWarningKeepsTheTabsModel() async throws {
        let context = Database.shared.viewContext
        let tab = NavigationViewModel.makeTab(context: context)
        defer {
            BrowserViewModel.destroyTabById(id: tab.objectID)
            context.delete(tab)
        }
        let shown = BrowserViewModel.getCached(tabID: tab.objectID)  // the model the tab's screen holds
        BrowserViewModel.cache?.setValue(shown, forKey: tab.objectID, dated: .now.addingTimeInterval(-7 * 60))
        UIApplication.shared.perform(Selector(("_performMemoryWarning")))  // UIKit's own warning, as the device sends
        try await Task.sleep(for: .milliseconds(300))  // the purge ran in a task of its own
        #expect(BrowserViewModel.getCached(tabID: tab.objectID) === shown)
    }
}
#endif
