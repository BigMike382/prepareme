// This file is part of PrepareMe, a local build of Kiwix for one household's phones (build plan phase 4).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

/// Which copy of the app this is (Unlisted plan, phase 3): the family's PrepareMe, or PrepareMe Dev
/// (com.bigmike382.prepareme.dev), the development copy that sits beside it, built with PREPAREME_DEV by
/// kiwix-mac/build.sh's Dev modes only. The names the system knows the app by come from here, so the two never share
/// one; the Dev modes change their own copy of Info.plist to match (the family's file is never edited). PrepareMe Dev
/// pairs only with a test service (a version 2 PairingCode) and says it is the Dev copy on every request (DevCopy), which
/// the family's Mac refuses.
enum AppCopy {
    #if PREPAREME_DEV
    static let isDev = true
    #else
    static let isDev = false
    #endif
    static let id = isDev ? "com.bigmike382.prepareme.dev" : "com.bigmike382.prepareme"
    /// Only for the local-network question: the phones reach the Mac by the code's name and address, never by Bonjour.
    static let bonjour = isDev ? "_prepareme-dev._tcp" : "_prepareme._tcp"
    /// The pins file's type, which Info.plist declares (two apps may not both declare one).
    static let pinsType = id + ".pins"
}
