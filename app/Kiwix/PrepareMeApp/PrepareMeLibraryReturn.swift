// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (Library plan, phase 2).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

/// Back from a collection's front page to the Library list it was opened from (owner, 2026-11-12: "familiar", as
/// Back from a guide returns to its category). Set when a list opens a collection, cleared when anything else is
/// picked; the reading tab's Back asks `goBack(at:)` first, and its button stays on while `applies(_:)`.
@MainActor
final class PrepareMeLibraryReturn: ObservableObject {
    static let shared = PrepareMeLibraryReturn()

    @Published private(set) var front: URL?
    private var action: (() -> Void)?

    func set(front: URL, back: @escaping () -> Void) {
        self.front = front
        action = back
    }

    func clear() {
        front = nil
        action = nil
    }

    /// Whether the page on screen is the collection's front page, so Back leads to the list.
    func applies(_ url: URL?) -> Bool {
        guard let url, let front else { return false }
        return url.zimFileID == front.zimFileID && url.contentPath == front.contentPath
    }

    /// Back at the collection's front page: the list again, and true; false anywhere else (the page's own Back).
    func goBack(at url: URL?) -> Bool {
        guard applies(url), let action else { return false }
        action()
        return true
    }
}
