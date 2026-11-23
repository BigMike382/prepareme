// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.
//
// Kiwix is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
// General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Kiwix; If not, see https://www.gnu.org/licenses/.

#if os(iOS)
import SwiftUI
import WebKit

struct ContentSearchButton: View {
    @FocusedValue(\.isBrowserURLSet) var isBrowserURLSet
    let findInteraction: () -> Void
    #if PREPAREME_APP
    // PrepareMe's reading tabs never set the focused value (three tabs, one scene), so the item was always greyed out:
    // it goes by its own tab's page instead (remaining-findings plan, Task 10.3; F19)
    @ObservedObject private var browser: BrowserViewModel
    #endif
    
    init(browser: BrowserViewModel) {
        #if PREPAREME_APP
        self.browser = browser
        #endif
        findInteraction = { [weak browser] in
            browser?.webView.isFindInteractionEnabled = true
            browser?.webView.findInteraction?.presentFindNavigator(showingReplace: false)
        }
    }

    var body: some View {
        Button(LocalString.common_search_inpage,
               systemImage: "text.page.badge.magnifyingglass",
               action: {
            findInteraction()
        }
        )
        #if PREPAREME_APP
        .disabled(browser.url == nil)
        #else
        .disabled(isBrowserURLSet != true)
        #endif
    }
}
#endif
