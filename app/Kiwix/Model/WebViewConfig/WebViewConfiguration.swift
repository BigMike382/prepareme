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

import Foundation
import WebKit
#if PREPAREME_APP && os(iOS)
import PrepareMeShared
import UIKit
#endif

final class WebViewConfiguration: WKWebViewConfiguration {
    /// PrepareMe app (the Today redesign, plan phase 3): every page is marked with where it is read before it draws,
    /// data-host on its root, so the front page hides its Guides, Maps and Inventory buttons in the phone app (its
    /// tab bar has them) and names where Event mode is switched. Kiwix itself never marks a page, so App Store Kiwix
    /// and Kiwix (PrepareMe) show the page as built. A phone's page starts with the role the app holds, the child's
    /// words until the Mac has said it may edit (F-094), and its walk-through role (F-092): WalkthroughRole.phoneMarks,
    /// laid again with the scripts and sent to the open pages when the role changes (PhoneInventoryModel.canEdit).
    #if PREPAREME_APP && os(macOS)
    static var hostScript: String? { "document.documentElement.setAttribute('data-host', 'mac-app');" }
    #elseif PREPAREME_APP
    static var hostScript: String? {
        MainActor.assumeIsolated {
            WalkthroughRole.phoneMarks(canEdit: PhoneInventoryModel.shared.canEdit,
                                       child: PhoneInventoryModel.shared.isChild)
        }
    }
    #else
    static let hostScript: String? = nil
    #endif

    override init() {
        super.init()
        setURLSchemeHandler(KiwixURLSchemeHandler(), forURLScheme: KiwixURLSchemeHandler.ZIMScheme)
        #if os(macOS)
        preferences.isElementFullscreenEnabled = true
        #if PREPAREME_APP
        preferences.tabFocusesLinks = true  // Tab reaches a page's links, not only its folds (Task 13.5; F50)
        #endif
        #else
        allowsInlineMediaPlayback = true
        mediaTypesRequiringUserActionForPlayback = []
        #endif
        userContentController = {
            let controller = WKUserContentController()
            if let ruleList = WebContentBlocker.ruleList {
                controller.add(ruleList)
            }
            Self.addScripts(to: controller)
            #if PREPAREME_APP
            MainActor.assumeIsolated {
                PrepareMeRedNight.shared.register(controller)
                PrepareMeGamePlay.shared.register(controller)  // a game page's word on edge to edge (games 3b)
                PrepareMeGameSaves.shared.register(controller)  // our games' saves, in the app (players stage 1)
            }
            #endif
            return controller
        }()
    }

    /// The page scripts (PrepareMe, phase D: one place, so the red night screen can lay them again, with the switch
    /// as it now stands, into a tab made before it changed).
    static func addScripts(to controller: WKUserContentController) {
        // inject custom (bundled) .js files
        for resource in ["injection", "geolocation"] {
            if let url = Bundle.main.url(forResource: resource, withExtension: "js"),
               let javascript = try? String(contentsOf: url) {
                let script = WKUserScript(
                    source: javascript,
                    // the location stand-in before any page script (games plan phase 2: at the end, a page's own early
                    // call reached the browser's geolocation, which asked for the device's location)
                    injectionTime: resource == "geolocation" ? .atDocumentStart : .atDocumentEnd,
                    forMainFrameOnly: false
                )
                controller.addUserScript(script)
            }
        }
        
        if let url = Bundle.main.url(forResource: "zimCookies", withExtension: "js"),
           let javascript = try? String(contentsOf: url) {
            let script = WKUserScript(
                source: javascript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            controller.addUserScript(script)
        }

        if let mark = Self.hostScript {
            controller.addUserScript(WKUserScript(
                source: mark,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        #if PREPAREME_APP
        controller.addUserScript(WKUserScript(
            source: MainActor.assumeIsolated { PrepareMeRedNight.pageScript(on: PrepareMeRedNight.shared.on) },
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        // full-screen play (games 3b): a game page marked data-pm-full before its own scripts run
        controller.addUserScript(WKUserScript(
            source: MainActor.assumeIsolated { PrepareMeGamePlay.pageScript },
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        // the game bridge (players stage 1): on a page of our own games, in its own content world, the app's copy of
        // the game's save before the page's scripts run, and the way to keep the next one
        controller.addUserScript(MainActor.assumeIsolated { PrepareMeGameSaves.shared.script })
        #endif
        #if PREPAREME_APP && os(macOS)
        // News's right-click marks (news plan Task 3.4): here, so red night's re-lay (layScripts) keeps it
        controller.addUserScript(WKUserScript(
            source: MainActor.assumeIsolated { PrepareMeWebView.script },
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        // and the taken-down stories kept from the News page until the library's copy catches up
        if let hidden = MainActor.assumeIsolated({ () -> String? in
            let stories = PrepareMeNewsMarks.shared.takenDown
            return stories.isEmpty ? nil : PrepareMeNewsMarks.hideScript(stories)
        }) {
            controller.addUserScript(WKUserScript(source: hidden, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        #endif
        #if PREPAREME_APP && os(iOS)
        // Tap-to-call (B2-15): on an iPhone only (not an iPad); the Mac and App Store Kiwix keep the plain marked text
        if CallLinks.injectsScript(isPhone: UIDevice.current.userInterfaceIdiom == .phone) {
            controller.addUserScript(WKUserScript(
                source: CallLinks.pageScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
        #endif
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
