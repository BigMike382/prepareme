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

#if os(macOS)
import Foundation
import SwiftUI

struct ContentSearchBar: View {

    @ObservedObject private var viewModel: ContentSearchViewModel

    @State private var isActivated: Bool = false
    @FocusState private var focusedState: Bool

    init(model: ContentSearchViewModel) {
        viewModel = model
    }

    var body: some View {
        #if PREPAREME_APP
        findCommands(bar)
        #else
        bar
        #endif
    }

    @ViewBuilder private var bar: some View {
        if isActivated {
            field
                .focused($focusedState)
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }
        } else {
            button
                #if !PREPAREME_APP  // PrepareMe's ⌘F is Edit › Find's, which posts .prepareMeFind (below)
                .keyboardShortcut("f", modifiers: .command)
                #endif
            #if !PREPAREME_APP  // PrepareMe's ⇧⌘F is Edit › Search the Library's own (Task 13.5; F50)
            /// special hidden button to trigger the top bar zim file search with cmd+shift+F
            Button {
                NotificationCenter.default.post(name: .zimSearch, object: nil)
            } label: {
                Text("")
            }
            .hidden()
            .keyboardShortcut("f", modifiers: [.command, .shift])
            #endif
        }
    }
    
    #if PREPAREME_APP
    /// Edit › Find, Find Next and Find Previous (the Apple guidelines plan, phase 2), in the window in front
    private func findCommands(_ content: some View) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .prepareMeFind)) { _ in
                isActivated = true
                focusedState = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .prepareMeFindNext)) { _ in
                if isActivated { Task { await viewModel.findNext() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .prepareMeFindPrevious)) { _ in
                if isActivated { Task { await viewModel.findPrevious() } }
            }
    }
    #endif

    private func dismiss() {
        viewModel.reset()
        isActivated = false
    }

    private var button: some View {
        Button {
            isActivated = true
            focusedState = true
        } label: {
            Image(systemName: "text.page.badge.magnifyingglass")
                .font(.system(size: 18))
        }
        .accessibilityLabel(LocalString.common_search_inpage)
        .buttonStyle(PlainButtonStyle())
        .padding(24)
    }

    private var field: some View {
        HStack {
            searchImage
            TextField(LocalString.common_search_inpage, text: $viewModel.contentSearchText)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 2) {
                leftButton
                rightButton
            }
            closeButton
        }
        .padding(8)
        .background(Color.background)
        .padding(16)
        .cornerRadius(16)
        .frame(maxWidth: 320)
    }

    private var searchImage: some View {
        Image(systemName: "magnifyingglass")
            .foregroundColor(.primary)
            .accessibilityHidden(true)
    }

    private var leftButton: some View {
        Button {
            Task { await viewModel.findPrevious() }
        } label: {
            Image(systemName: "arrowshape.left").foregroundColor(.primary)
        }
        .accessibilityLabel(LocalString.common_find_previous)
        #if !PREPAREME_APP  // PrepareMe's are Edit › Find's
        .keyboardShortcut("g", modifiers: EventModifiers(arrayLiteral: .command, .shift))
        #endif
    }

    private var rightButton: some View {
        Button {
            Task { await viewModel.findNext() }
        } label: {
            Image(systemName: "arrowshape.right").foregroundColor(.primary)
        }
        .accessibilityLabel(LocalString.common_find_next)
        #if !PREPAREME_APP  // PrepareMe's are Edit › Find's
        .keyboardShortcut("g")
        #endif
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill").foregroundColor(.primary)
        }
    }

}
#endif
