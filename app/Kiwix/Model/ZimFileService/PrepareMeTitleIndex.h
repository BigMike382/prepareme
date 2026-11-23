// This file is part of Kiwix (PrepareMe), a local build of Kiwix for one household's Mac.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#pragma once
#include <memory>
#include <mutex>
#include "zim/archive.h"
#include "zim/suggestion.h"

/// PrepareMe: an open archive's title searcher, kept with it so its index reads the file the archive was opened from
/// (ZimService.mm, openSearchIndexes). Xapian isn't safe to use from two threads at once, so every use of the
/// searcher, and of the results it hands back, holds `lock`.
struct PrepareMeTitleIndex {
    std::mutex lock;
    zim::SuggestionSearcher searcher;
    explicit PrepareMeTitleIndex(const zim::Archive &archive) : searcher(archive) {}
};
