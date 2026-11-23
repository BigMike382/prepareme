// This file is part of Kiwix (PrepareMe), a local build of Kiwix for one household.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

/// PrepareMe: facts about the household's libraries that the Mac's Kiwix (PrepareMe) and the phone app share.
enum PrepareMeLibraries {
    /// The vehicles library opens left out of search (owner, 2026-10-07; FINDINGS F-019), and so does the equipment
    /// manuals library (top-ten plan, phase 7), for the same reason: a manual's many text pages would crowd every
    /// search. Its manuals are reached by an item's "Read the manual" and the library's own index page. The games
    /// library too (games plan phase 2): a game's pages and scripts are no answer to a guide search.
    static let leftOutOfSearch: Set<UUID> = [UUID(uuidString: "23249f81-3d36-41fd-9d9d-f4b43bd8d3ad")!,
                                             UUID(uuidString: "22a5a8ba-c510-4af3-a781-5f93fd1acddd")!,
                                             UUID(uuidString: "99b4cd15-4ca9-481e-8f20-7f3e3d3acc1b")!]
}
