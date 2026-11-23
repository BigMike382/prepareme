#!/bin/bash
# Builds "Kiwix (PrepareMe)": Kiwix for Mac 3.17.1 with the household's changes, from app/Kiwix (plan phase 3: Kiwix's
# code exactly as published, then the PrepareMe changes as the next commit; `git log app/Kiwix` shows them). The
# changes make Kiwix open a library file again when it was replaced while Kiwix ran (FINDINGS F-043), instead of
# reading the old copy until it quits. They also add the sidebar's "Refresh conditions now" and "Check conditions
# once", which touch a file in Application Support › PrepareMe › requests for the dashboard job, with the job's status
# line under them; that folder is the one sandbox exception the Mac build gets (Kiwix-macOS.entitlements, made here;
# the App Store would refuse it; this build is for this Mac only, and the iPhone build never carries it).
#
#   kiwix-mac/build.sh              build app/Kiwix and install /Applications/Kiwix (PrepareMe).app (from the PrepareMe
#                                   folder itself on branch main, with app/Kiwix committed; refused anywhere else)
#   kiwix-mac/build.sh --from-app   the same (the plan's name for it)
#   kiwix-mac/build.sh --no-install build and sign app/Kiwix as an install would, check its signature and entitlements,
#                                   and print its path; installs nothing (a session's check before the owner's install)
#   kiwix-mac/build.sh --unchanged  build Kiwix 3.17.1 without the changes and install it IN PLACE of Kiwix (PrepareMe),
#                                   to prove the build itself works (the owner's step; a rebuild puts the changes back)
#   kiwix-mac/build.sh --test       run Kiwix's own unit tests and PrepareMe's on app/Kiwix, on the Mac and on the
#                                   iPhone simulator; install nothing
#   kiwix-mac/build.sh --tsan       the same under Thread Sanitizer, which catches the main thread and search touching
#                                   the open-library list at once (the reopen test swaps a library 100 times during
#                                   searches); install nothing
#   kiwix-mac/build.sh --ios-sim    build the UNCHANGED Kiwix for the iPhone simulator, as the phones run it
#                                   (owner, 2026-10-08), and print the app's path; installs nothing on the Mac
#   kiwix-mac/build.sh --app-sim    build PrepareMe, the household's phone app (build plan phase 4: app/Kiwix's
#                                   PrepareMe target, bundle ID com.bigmike382.prepareme), for the iPhone simulator
#                                   and print its path; installs nothing
#   kiwix-mac/build.sh --app-phone  build PrepareMe for the one iPhone or iPad plugged into this Mac and install it
#                                   there, never one seen only over Wi-Fi (pick_device.py chooses, and says why when it
#                                   can't; the install names the device): the owner's step only, from the PrepareMe
#                                   folder itself on branch main with app/Kiwix and app/Service committed (the device
#                                   unlocked, trusting this Mac, Developer Mode on; signed with the owner's Apple
#                                   Development identity, so it opens until its profile expires, which the app shows).
#                                   Each one starts a new year: PrepareMe's saved profile is set aside first so Xcode
#                                   gets a new one (profiles.py; put back if none came), and the last line says the new
#                                   end and whether it is later than the one set aside
#   kiwix-mac/build.sh --app-mac    build PrepareMe for the Mac (build plan phase 6: the same target, its library from
#                                   the packer's local folder, the phones' service inside it) and install it as
#                                   /Applications/PrepareMe.app: the owner's step only, with PrepareMe quit, from the
#                                   PrepareMe folder itself on branch main with app/Kiwix and app/Service committed. A
#                                   service already running from it is restarted on the new copy, and the app opened.
#                                   Signed with the owner's Developer ID only (of two, the one that ends last), every
#                                   program inside with a secure timestamp, each checked (mac_release.py), then sent to
#                                   Apple's notary service with the sign-in stored as NOTARY_PROFILE, stapled and
#                                   checked; the stapled app is zipped and kept in Application Support › PrepareMe ›
#                                   installers › mac with the source and the two build downloads, which the USB backup
#                                   copies into its locked image (Unlisted plan, phase 2). When notarizing can't be
#                                   done, it installs anyway, keeps the last notarized copy and says why (owner,
#                                   2026-11-22)
#                                   Both installs build in USDA's key for the barcode lookup from Household Private
#                                   › Keys › usda-key.txt (owner, 2026-10-22), else the project's DEMO_KEY, and
#                                   UPC Database's from upcdatabase-key.txt there (2026-10-23), else none. With
#                                   PREPAREME_NO_LOOKUP_KEYS=1 a phone build (--app-phone, --app-testflight,
#                                   --app-installer) builds in neither: an adult's device takes the Mac app's from its
#                                   service (Unlisted plan, phase 4); the Mac app always builds them in
#   kiwix-mac/build.sh --app-testflight
#                                   build PrepareMe for iPhone and iPad as a TestFlight build and upload it to App Store
#                                   Connect for internal testing only (over-the-air plan, phase 2), with Xcode's signed-in
#                                   account: the owner's step only, from the PrepareMe folder itself on branch main with
#                                   the code committed, as --app-phone. The build number is the UTC date and time
#                                   (2026.1114.1530: always higher than the last), and the build's time and channel
#                                   ("testflight") go into the app, which opens 90 days from then; the export-compliance
#                                   answer is EXPORT_NON_EXEMPT, below. The meaning model and the lookup keys go in as
#                                   --app-phone's, and nothing is uploaded unless check_upload.py passes the built app.
#                                   On GitHub's machines (GITHUB_ACTIONS=true; over-the-air plan, phase 4) it refuses
#                                   anything but an unchanged checkout of a family- tag, in place of the main folder,
#                                   and signs in the cloud with the API key the workflow hands it
#                                   (.github/workflows/testflight.yml; docs/kiwix-mac.md, "GitHub's builds")
#   kiwix-mac/build.sh --app-ios-check
#                                   a session's check before any upload: the same iPhone and iPad build, unsigned and
#                                   stamped the same way (the project's DEMO_KEY, no owner's keys), listed and checked by
#                                   check_upload.py (no library content, no Household Private files, no ID numbers or keys
#                                   in its text files); prints the app's path and the listing's; uploads nothing
#   kiwix-mac/build.sh --app-store  the one build that goes to App Review (Unlisted plan, phase 5;
#                                   docs/plans/2026-11-23-unlisted-phase-5-store-build.md): PrepareMe for iPhone and
#                                   iPad, version STORE_VERSION (above every TestFlight and cable build's 3.17.1), the
#                                   build number from the UTC time as --app-testflight's, stamped "appstore", uploaded
#                                   to App Store Connect and NOTHING submitted or released (App Review, the Unlisted
#                                   request and Release are the owner's, in App Store Connect). The owner's step only,
#                                   on this Mac only (never GitHub's machines), from the PrepareMe folder itself on
#                                   branch main with the code committed. No owner's keys (the demo key and nothing),
#                                   English only (decision 10), the family's app ID (decision 12), and the sample the
#                                   owner approved, read only from the committed sample-approved.txt; refused without
#                                   it. Uploaded only after check_upload.py --store passes the built app. App Store
#                                   Connect's Owner group takes it by itself, as every upload: installed through
#                                   TestFlight it is a TestFlight copy, 90 days, as the app tells by how it came
#   kiwix-mac/build.sh --app-store-check
#                                   a session's check of --app-store's build: the same app, unsigned, checked with
#                                   check_upload.py --store; uploads nothing. Before the owner approves the sample it
#                                   carries the one on disk against a scratch list in the tools folder and says it is
#                                   only a rehearsal
#   kiwix-mac/build.sh --app-installer
#                                   the kept cable installer (over-the-air plan, phase 3, layer 6; the scheduler's
#                                   monthly installer job runs it): PrepareMe for iPhone and iPad, signed as --app-phone's
#                                   for every device registered to the team, built without installing anywhere, into
#                                   Application Support › PrepareMe › installers (the USB backup copies it), with
#                                   installer.json naming its build, when it was made and when its profile stops it
#                                   installing (the hourly check warns six months ahead). Only from the PrepareMe folder
#                                   itself on branch main with the code committed, as the installs. A fresh profile
#                                   each time, as --app-phone's, so the kept copy is never more than a month into its year
#   kiwix-mac/build.sh --app-kept   install that kept PrepareMe on the one iPhone or iPad plugged into this Mac, with no
#                                   build (the way back if a device's PrepareMe ever locks; docs/lost-mac.md): the
#                                   owner's step only. Needs Xcode, the cable and Developer Mode on the device
#   kiwix-mac/build.sh --app-mac-release-check
#                                   a session's check of the install's own build: --app-mac's app ID, entitlements,
#                                   signing and checks, and the zip it would send, with the project's DEMO_KEY in place
#                                   of the owner's keys; installs nothing, sends nothing to Apple (that needs the
#                                   owner's notary sign-in), and prints the app's and the zip's paths
#   kiwix-mac/build.sh --dev-sim    PrepareMe Dev (Unlisted plan, phase 3; docs/app.md, "PrepareMe Dev"), the development
#                                   copy that sits beside PrepareMe, for the iPhone simulator: bundle ID
#                                   com.bigmike382.prepareme.dev, named PrepareMe Dev, its own icon, PREPAREME_DEV, and
#                                   its own copy of Info.plist's names (background refresh, link scheme, Bonjour name,
#                                   pins type); the family's files are never edited. Prints its path; installs nothing
#   kiwix-mac/build.sh --dev-phone  PrepareMe Dev on the one iPhone or iPad plugged into this Mac, beside the family's
#                                   PrepareMe and never over it: the owner's step only. From any folder, a worktree
#                                   included (it is for trying a change before it is on main), with the app's code
#                                   committed. The project's demo barcode key only, never the owner's keys
#   kiwix-mac/build.sh --dev-testflight
#                                   PrepareMe Dev uploaded to its own App Store Connect record for internal testing
#                                   only: the owner's step only, from any folder with the code committed, checked by
#                                   check_upload.py as --app-testflight is; never run on GitHub's machines
#   kiwix-mac/build.sh --app-mac-check DIR
#                                   a session's check of the Mac app: the same build under its own bundle ID
#                                   (com.bigmike382.prepareme.check, PREPAREME_CHECK), reading DIR as its home's
#                                   PrepareMe folders (made-up libraries only, never the real ones), registering
#                                   nothing with macOS and looking for a test service on 127.0.0.1:8799; installs
#                                   nothing, keeps its own copy in DIR/app/PrepareMe.app (the shared build folder is
#                                   the next session's) and prints how to open it
#
# The installed app is signed with the owner's Developer ID when the Keychain has one, else their Apple Development
# identity (owner, 2026-10-13, until enrollment), with the hardened runtime and no debugger entitlement, so the
# firewall and the folder picks know it across rebuilds; with neither it is signed ad hoc, as before phase 3, and says
# so. A change of signature asks for the PrepareMe folders once more.
# PrepareMe for the Mac (--app-mac, --app-mac-release-check) takes a Developer ID only, as notarizing requires.
#
# Needs Xcode in /Applications. Everything else is in Application Support › PrepareMe › tools › kiwix-build, checked
# against pinned checksums; the Swift packages are pinned by app/Kiwix/Package.resolved. app/Kiwix is copied there
# (tracked and new files, never ignored ones) and built there, so nothing generated lands in the repository.
set -euo pipefail

TAG=3.17.1
CORE=libkiwix_xcframework-14.2.1-2.tar.gz         # the version Kiwix 3.17.1's Brewfile names
CORE_MD5=78c0398d14228d11d2caf2c888314d04          # download.kiwix.org's published .md5
XCODEGEN_SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806  # XcodeGen 2.46.0 xcodegen.zip
BUNDLE_ID=self.Kiwix.PrepareMe                     # its own ID, so its library list stays apart from the App Store Kiwix
APP_NAME="Kiwix (PrepareMe)"
DEST="/Applications/$APP_NAME.app"
REQUESTS="/Library/Application Support/PrepareMe/requests/"  # the Mac's one sandbox exception, home-relative
SIMULATOR="PrepareMe Kiwix tests"                  # its own simulator, so no other session's is disturbed
SIMULATOR_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-17

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
TOOLS="$HOME/Library/Application Support/PrepareMe/tools/kiwix-build"
# GitHub's machines name the Xcode to use (.github/workflows/testflight.yml); the Mac always uses its one Xcode
export DEVELOPER_DIR="${PREPAREME_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

MAC_APP="/Applications/PrepareMe.app"               # the Mac's PrepareMe (plan phase 6), beside Kiwix (PrepareMe)
SERVICE_LABEL=com.bigmike382.prepareme.service      # its phones' service, registered by the app (SMAppService)
# The owner's notary sign-in, stored once in the login Keychain under this name (`xcrun notarytool store-credentials`,
# owner checks); notarytool reads it, a session never does
NOTARY_PROFILE="PrepareMe notary"
NOTARY_WAIT=15m   # longer and the install goes on without it, so a fix for the phones is never held up by Apple
# The owner's export-compliance answer for TestFlight uploads (over-the-air plan, phase 2): NO when PrepareMe uses no
# encryption that needs export documentation, YES when it does. Info.plist's ITSAppUsesNonExemptEncryption is set from
# it, so App Store Connect never stops an upload on the question. Empty until the owner answers (owner checks, section
# 72): --app-testflight refuses until then. Never a session's call.
EXPORT_NON_EXEMPT="NO"  # the owner's answer, by click, 2026-11-14
# The store build's version (Unlisted plan, phase 5): above every TestFlight and cable build's (project.yml's 3.17.1),
# since App Store Connect refuses a version below one it approved. Raised for each new store version.
STORE_VERSION="4.0"
# A check build's one test folder in iCloud Drive (concept-doc plan, phase A), made-up files only, deleted after
BACKUP_CHECK="$HOME/Library/Mobile Documents/com~apple~CloudDocs/PrepareMe Backup Check"

mode=${1:-}
case "$mode" in ""|--from-app|--no-install|--unchanged|--test|--tsan|--ios-sim|--app-sim|--app-phone|--app-mac|--app-mac-release-check|--app-testflight|--app-ios-check|--app-store|--app-store-check|--app-installer|--app-kept|--dev-sim|--dev-phone|--dev-testflight) ;;
    --app-mac-check)
        # a scratch folder only, by its real path (links followed), under the Mac's temporary folders: never home, a
        # folder holding the real PrepareMe or iCloud folders, or a link to one (whole-branch review, 3)
        CHECK_HOME=$(cd -P "${2:-/nonexistent}" 2>/dev/null && pwd -P) || { echo "--app-mac-check takes a scratch folder" >&2; exit 2; }
        case "$CHECK_HOME/" in /private/tmp/?*|/private/var/folders/?*) ;;
            *) echo "--app-mac-check takes a scratch folder under /private/tmp or the temporary folder, not $CHECK_HOME" >&2; exit 2 ;; esac ;;
    *) echo "unknown option: $mode" >&2; exit 2 ;; esac

# The store build is made on this Mac only (Unlisted plan, phase 5): GitHub's key could release a version
if [ "$mode" = --app-store ] && [ "${GITHUB_ACTIONS:-}" = true ]; then
    echo "Not uploaded: the store build is made on the owner's Mac only, never on GitHub's machines." >&2
    exit 1
fi

INSTALLERS="$HOME/Library/Application Support/PrepareMe/installers"   # the kept cable installer (phase 3, layer 6)
if [ "$mode" = --app-kept ]; then   # no build, so no lock or build tools: Xcode's devicectl and the kept copy only
    [ -d "$INSTALLERS/PrepareMe.app" ] || { echo "No kept installer in $INSTALLERS yet: the monthly installer job makes it." >&2; exit 1; }
    listing="$(mktemp -t prepareme-devices)"
    xcrun devicectl list devices --json-output "$listing" >/dev/null 2>&1 || true
    pick=$(/usr/bin/python3 -I "$HERE/pick_device.py" "$listing") || { rm -f "$listing"; exit 1; }   # it said why
    rm -f "$listing"
    xcrun devicectl device install app --device "${pick%%$'\t'*}" "$INSTALLERS/PrepareMe.app" >/dev/null
    echo "Installed the kept PrepareMe (build $(plutil -extract CFBundleVersion raw "$INSTALLERS/PrepareMe.app/Info.plist")) on ${pick#*$'\t'}."
    echo "Its Downloads screen says how long this install opens."
    exit 0
fi

# One run at a time, from any checkout (FINDINGS F-084): every run shares $TOOLS and starts by deleting the last copy
# there, so a second run would pull the first one's sources out from under its compiler. lockf holds the lock in its
# own process, not this shell's, so nothing the build leaves running (Xcode's build service, a simulator) keeps it.
if [ -z "${PREPAREME_BUILD_LOCKED:-}" ]; then
    LOCK="$TOOLS/build.lock"
    mkdir -p "$TOOLS"
    wait_s=${PREPAREME_BUILD_LOCK_WAIT:-1800}   # the tests shorten it
    if [ "$wait_s" -ge 120 ]; then wait_said="$((wait_s / 60)) minutes"; else wait_said="$wait_s seconds"; fi
    if ! /usr/bin/lockf -k -s -t 0 "$LOCK" true; then
        echo "Another kiwix-mac/build.sh is running (from this folder or another); waiting up to $wait_said for it to finish." >&2
    fi
    status=0
    PREPAREME_BUILD_LOCKED=1 /usr/bin/lockf -k -s -t "$wait_s" "$LOCK" /bin/bash "$HERE/build.sh" "$@" || status=$?
    # lockf's own "timed out" is 75; a build that ended 75 itself leaves the lock free, so it isn't this message
    if [ "$status" = 75 ] && ! /usr/bin/lockf -k -s -t 0 "$LOCK" true; then
        echo "Not built: the other build.sh was still running after $wait_said. Run this again when it has finished." >&2
    fi
    exit "$status"
fi

# An install replaces the live Kiwix (PrepareMe), so it comes only from the PrepareMe folder itself (the main checkout,
# not a worktree) on branch main, with app/Kiwix as committed, as `scheduler install` refuses elsewhere. Checked before
# the tools, so a refusal costs nothing
if [ -z "$mode" ] || [ "$mode" = --from-app ] || [ "$mode" = --app-phone ] || [ "$mode" = --app-mac ] \
        || [ "$mode" = --app-testflight ] || [ "$mode" = --app-store ] || [ "$mode" = --app-installer ]; then
    if [ "${GITHUB_ACTIONS:-}" = true ] && [ "$mode" = --app-testflight ]; then
        # GitHub's build (over-the-air plan, phase 4), in place of the main folder: only a family- tag the owner made,
        # checked out exactly, nothing changed or added (.github/workflows/testflight.yml)
        if [ -z "$(git -C "$REPO" tag --points-at HEAD --list 'family-*' 2>/dev/null)" ] \
                || [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
            echo "Not uploaded: GitHub builds only an unchanged checkout of a family- tag." >&2
            exit 1
        fi
    else
        git_dir=$(git -C "$REPO" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)
        common_dir=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
        branch=$(git -C "$REPO" symbolic-ref --short HEAD 2>/dev/null || true)
        if [ -z "$git_dir" ] || [ "$git_dir" != "$common_dir" ] || [ "$branch" != main ]; then
            echo "Not installed: run this from the PrepareMe folder itself (the main checkout, not a worktree), on branch main; --no-install builds and checks from anywhere." >&2
            exit 1
        fi
        # everything the app copies in as committed, the check's code (below, check_code) included: the paper card's
        # rules and the two packer files it needs too (the audit, 2026-10-22, finding 10)
        if [ -n "$(git -C "$REPO" status --porcelain -- app/Kiwix app/Service app/StreetMapAssets app/Meaning readiness guard inventory \
                packer/__init__.py packer/gitenv.py paper/__init__.py paper/card.py paper/cardtext.py paper/print_style.py \
                paper/card-starter.toml)" ]; then
            echo "Not installed: app/Kiwix, app/Service, app/StreetMapAssets, app/Meaning or the check's code (the inventory's or the card's) has changes that aren't committed; commit them first." >&2
            exit 1
        fi
        if { [ "$mode" = --app-testflight ] || [ "$mode" = --app-store ]; } \
                && [ -n "$(git -C "$REPO" status --porcelain -- kiwix-mac guard)" ]; then
            echo "Not uploaded: kiwix-mac or guard (the upload's own check) has changes that aren't committed." >&2
            exit 1
        fi
    fi
    if [ "$mode" = --app-testflight ] || [ "$mode" = --app-store ]; then
        case "$EXPORT_NON_EXEMPT" in NO|YES) ;;
            *) echo "Not uploaded: the export-compliance answer isn't recorded yet (owner checks, section 72)." >&2; exit 1 ;; esac
    fi
fi

# PrepareMe Dev's device builds (Unlisted plan, phase 3) come from any folder, so a branch is tried before it is on
# main, but with the code committed, so the build names a commit; never on GitHub's machines (its workflow builds the
# family's tags only)
if [ "$mode" = --dev-phone ] || [ "$mode" = --dev-testflight ]; then
    if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "Not built: PrepareMe Dev isn't built on GitHub's machines." >&2; exit 1; fi
    if [ -n "$(git -C "$REPO" status --porcelain -- app/Kiwix app/Service app/StreetMapAssets app/Meaning kiwix-mac guard)" ]; then
        echo "Not built: app/Kiwix, app/Service, app/StreetMapAssets, app/Meaning, kiwix-mac or guard has changes that aren't committed; commit them first." >&2
        exit 1
    fi
fi

xcodebuild -version >/dev/null 2>&1 || { echo "Xcode isn't installed in /Applications (or hasn't been opened once)." >&2; exit 1; }
[ "$(md5 -q "$TOOLS/$CORE")" = "$CORE_MD5" ] || { echo "$CORE doesn't match its checksum." >&2; exit 1; }
[ "$(shasum -a 256 "$TOOLS/xcodegen.zip" | cut -d' ' -f1)" = "$XCODEGEN_SHA256" ] || { echo "xcodegen.zip doesn't match its checksum." >&2; exit 1; }
[ -x "$TOOLS/xcodegen/bin/xcodegen" ] || (cd "$TOOLS" && unzip -q -o xcodegen.zip)

if [ "$mode" = --unchanged ] || [ "$mode" = --ios-sim ]; then   # Kiwix as published, cloned fresh
    SRC="$TOOLS/kiwix-apple-$TAG"
    DERIVED="$TOOLS/derived-unchanged"
    rm -rf "$SRC"
    git clone -q --depth 1 --branch "$TAG" https://github.com/kiwix/kiwix-apple.git "$SRC" 2>/dev/null \
        || { echo "Couldn't download Kiwix $TAG from GitHub (no internet?)." >&2; exit 1; }
    cd "$SRC"
    sed -i '' '/in-app-payments/d' project.yml   # needs Kiwix's own Apple account; their CI removes it the same way
else                                             # app/Kiwix, as it is in this checkout
    SRC="$TOOLS/kiwix-app"
    DERIVED="$TOOLS/derived"
    rm -rf "$SRC"
    mkdir -p "$SRC"
    # app/Service beside it, where project.yml's PrepareMeService package finds it (../Service), and the street map's
    # files (app/StreetMapAssets, plan phase 9), which the PrepareMe target bundles as one folder; app/Meaning's package
    # (meaning search, docs/plans/2026-10-28-meaning-search.md, phase 3) beside them too
    rm -rf "$TOOLS/Service" "$TOOLS/StreetMapAssets" "$TOOLS/Meaning" "$TOOLS/meaning-model"
    mkdir -p "$TOOLS/Service" "$TOOLS/StreetMapAssets" "$TOOLS/Meaning" "$TOOLS/meaning-model/Meaning"
    for part in Kiwix:"$SRC" Service:"$TOOLS/Service" StreetMapAssets:"$TOOLS/StreetMapAssets" Meaning:"$TOOLS/Meaning"; do
        cd "$REPO/app/${part%%:*}"
        git ls-files -z --cached --others --exclude-standard . \
            | while IFS= read -r -d '' f; do if [ -e "$f" ]; then printf '%s\0' "$f"; fi; done \
            | tar --null -T - -cf - | tar -xf - -C "${part#*:}"
    done
    # meaning search's model at full precision (the phone check's pick), bundled as the app's Meaning folder: made by
    # app/Meaning/make_model.sh, never committed. An install refuses without it; any other build leaves the folder empty,
    # and that app searches by words alone. The model's MIT notice goes with it (committed, the street map's way)
    model="${PREPAREME_MEANING_MODEL:-$HOME/Library/Application Support/PrepareMe/tools/meaning/bge-small-en-v1.5-5c38ec7}"
    if [ -f "$model/vocab.txt" ] && [ -d "$model/bge-small-fp32.mlmodelc" ]; then
        cp -R "$model/vocab.txt" "$model/SOURCE.txt" "$model/bge-small-fp32.mlmodelc" \
            "$REPO/app/Meaning/LICENSE-bge-small-en-v1.5.txt" "$TOOLS/meaning-model/Meaning/"
    elif [ "$mode" = --app-phone ] || [ "$mode" = --app-mac ] || [ "$mode" = --app-testflight ] || [ "$mode" = --app-store ] \
            || [ "$mode" = --app-installer ] || [ "$mode" = --app-mac-release-check ]; then
        echo "Not installed: meaning search's model isn't made yet (run app/Meaning/make_model.sh first)." >&2
        exit 1
    else
        echo "Note: no meaning search model at $model; this build searches by words alone." >&2
    fi
    # the sample library (Unlisted plan, phase 4; packer/sample.py), the iPhone and iPad app's Sample folder: its three
    # files only when each is the one the owner read (sample-approved.txt), else an empty folder and no "Try the sample".
    # A simulator build takes an unapproved one, said so, for checking it; GitHub's machines have none.
    rm -rf "$TOOLS/sample-files"
    mkdir -p "$TOOLS/sample-files/Sample"
    sample="${PREPAREME_SAMPLE:-$HOME/Library/Application Support/PrepareMe/sample/built}"
    approved=yes
    for name in sample-library.zim sample-street-map.pmtiles sample-inventory.json; do
        [ -f "$sample/$name" ] || { approved=none; break; }
        grep -qx "$(shasum -a 256 "$sample/$name" | cut -d' ' -f1)  $name" "$HERE/sample-approved.txt" || approved=no
    done
    # The list the store upload is checked against: only the committed one (the lead's review, item 3); the check mode's
    # rehearsal alone makes a scratch one, in the tools folder, outside every checkout
    approved_list="$HERE/sample-approved.txt"
    case "$approved:$mode" in
        yes:*) cp "$sample/sample-library.zim" "$sample/sample-street-map.pmtiles" "$sample/sample-inventory.json" \
                   "$TOOLS/sample-files/Sample/" ;;
        *:--app-store) echo "Not built: the store build needs the sample the owner approved (sample-approved.txt; owner checks 130)." >&2
            exit 1 ;;
        no:--app-store-check)
            cp "$sample/sample-library.zim" "$sample/sample-street-map.pmtiles" "$sample/sample-inventory.json" \
                "$TOOLS/sample-files/Sample/"
            approved_list="$TOOLS/store-check-sample.txt"; (cd "$TOOLS/sample-files/Sample" && shasum -a 256 sample-*) > "$approved_list"
            echo "Note: the sample isn't the approved one; this store check is a rehearsal (--app-store refuses until it is)." >&2 ;;
        none:--app-store-check) echo "Not built: no sample to check with (python -m packer.sample build makes it)." >&2; exit 1 ;;
        no:--dev-sim|no:--app-sim|no:--test|no:--tsan)  # never --app-ios-check: an upload's rehearsal carries what an upload would
            cp "$sample/sample-library.zim" "$sample/sample-street-map.pmtiles" "$sample/sample-inventory.json" \
                "$TOOLS/sample-files/Sample/"
            echo "Note: the sample isn't the approved one; this simulator build carries it for checking only." >&2 ;;
        no:*) echo "Note: the sample isn't the approved one (sample-approved.txt); this build has no sample." >&2 ;;
    esac
    cd "$SRC"
fi

# PrepareMe Dev (Unlisted plan, phase 3): this copy of app/Kiwix only, never the repository's. Its icon put beside the
# family's (make_icon.py keeps it outside PrepareMeApp, so a family build never carries it) and Info.plist's names
# changed to Dev's, matching AppCopy.swift; the build settings below give it its ID, name, icon and PREPAREME_DEV.
DEV_ID=com.bigmike382.prepareme.dev
dev=()
case "$mode" in --dev-*)
    mv PrepareMeDev/PrepareMeDevAppIcon.icon PrepareMeApp/
    /usr/libexec/PlistBuddy -c "Set :BGTaskSchedulerPermittedIdentifiers:0 $DEV_ID.refresh" \
        -c "Set :CFBundleURLTypes:0:CFBundleURLName $DEV_ID.place" \
        -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 prepareme-dev" \
        -c "Set :NSBonjourServices:0 _prepareme-dev._tcp" \
        -c "Set :UTExportedTypeDeclarations:0:UTTypeIdentifier $DEV_ID.pins" \
        -c "Set :UTExportedTypeDeclarations:0:UTTypeDescription PrepareMe Dev pins" PrepareMeApp/Info.plist
    dev=(PRODUCT_BUNDLE_IDENTIFIER="$DEV_ID" INFOPLIST_KEY_CFBundleDisplayName="PrepareMe Dev"
         ASSETCATALOG_COMPILER_APPICON_NAME=PrepareMeDevAppIcon
         "SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) PREPAREME_APP PREPAREME_DEV") ;;
esac
# The built app is PrepareMe Dev through and through, or it isn't installed or uploaded
dev_checked() {
    local plist="$1/Info.plist" pair
    for pair in "CFBundleIdentifier=$DEV_ID" "CFBundleDisplayName=PrepareMe Dev" \
            "BGTaskSchedulerPermittedIdentifiers.0=$DEV_ID.refresh" "CFBundleURLTypes.0.CFBundleURLName=$DEV_ID.place" \
            "CFBundleURLTypes.0.CFBundleURLSchemes.0=prepareme-dev" "NSBonjourServices.0=_prepareme-dev._tcp" \
            "UTExportedTypeDeclarations.0.UTTypeIdentifier=$DEV_ID.pins" "CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName=PrepareMeDevAppIcon"; do
        [ "$(plutil -extract "${pair%%=*}" raw "$plist" 2>/dev/null)" = "${pair#*=}" ] \
            || { echo "The built app isn't PrepareMe Dev throughout (${pair%%=*}); not installed or uploaded." >&2; exit 1; }
    done
}

# What Kiwix's Brewfile does after `brew bundle`, without Homebrew.
tar -xzf "$TOOLS/$CORE" --strip-components 2
for platform in ios-arm64 ios-arm64_x86_64-simulator macos-arm64_x86_64; do
    cp Support/CoreKiwix.modulemap "CoreKiwix.xcframework/$platform/Headers/module.modulemap"
done
"$HOME/.venvs/prepareme-app/bin/python" localizations.py generate   # needs Python 3.10+; the Mac's python3 is 3.9
case "$mode" in --app-store|--app-store-check)   # English only (Unlisted plan, decision 10): the store lists the
    find Support -maxdepth 1 -name '*.lproj' ! -name en.lproj -exec rm -rf {} +   # app's languages from these folders
    [ "$(find Support -maxdepth 1 -name '*.lproj' | wc -l | tr -d ' ')" = 1 ] || { echo "Kiwix's translations are still in the copy." >&2; exit 1; } ;;
esac
if [ "$mode" = --test ] || [ "$mode" = --tsan ]; then   # the reopen test's libraries, made fresh, never committed
    "$HOME/.venvs/prepareme-app/bin/python" "$HERE/make_fixtures.py" Tests >/dev/null
fi
"$TOOLS/xcodegen/bin/xcodegen" generate --quiet

resolved=()
if [ "$SRC" = "$TOOLS/kiwix-app" ]; then   # app/Kiwix pins its packages; the clone has no Package.resolved of its own
    mkdir -p Kiwix.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
    cp Package.resolved Kiwix.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
    resolved=(-onlyUsePackageVersionsFromResolvedFile)
    # The Mac's entitlements: the shared ones plus the requests folder (project.yml, CODE_SIGN_ENTITLEMENTS)
    cp Support/Kiwix.entitlements Support/Kiwix-macOS.entitlements
    key=com.apple.security.temporary-exception.files.home-relative-path.read-write
    /usr/libexec/PlistBuddy -c "Add :$key array" -c "Add :$key:0 string $REQUESTS" Support/Kiwix-macOS.entitlements
fi

# The test simulator, made once (an iPhone on the newest iOS this Xcode has)
simulator() {
    local udid
    udid=$(xcrun simctl list devices available | sed -n "s/^ *$SIMULATOR (\([0-9A-F-]*\)).*/\1/p" | head -1)
    if [ -z "$udid" ]; then
        local runtime
        runtime=$(xcrun simctl list runtimes available | sed -n 's/^iOS .* - \(com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]*\)$/\1/p' | tail -1)
        [ -n "$runtime" ] || { echo "no iOS simulator runtime is installed (Xcode › Settings › Components)." >&2; exit 1; }
        udid=$(xcrun simctl create "$SIMULATOR" "$SIMULATOR_TYPE" "$runtime")
    fi
    echo "$udid"
}

# The newest test run's counts in $1's results, e.g. "69 tests, 69 passed, 0 failed, 0 skipped, 0 runtime warnings";
# fails when there is a runtime warning (Thread Sanitizer's race reports are runtime warnings, not failed tests)
counts() {
    local result
    result=$(ls -td "$1"/Logs/Test/*.xcresult | head -1)
    xcrun xcresulttool get test-results summary --path "$result" | /usr/bin/python3 -I -c '
import json, sys
d = json.load(sys.stdin)
warnings = len(d["runtimeWarnings"])
print("%(totalTestCount)s tests, %(passedTests)s passed, %(failedTests)s failed, %(skippedTests)s skipped" % d
      + ", %d runtime warnings" % warnings)
sys.exit(1 if warnings else 0)'
}

if [ "$mode" = --test ] || [ "$mode" = --tsan ]; then   # as Kiwix's CI runs them (.github/workflows/ci.yml)
    sanitizer=()
    [ "$mode" = --tsan ] && sanitizer=(-enableThreadSanitizer YES)
    flags=(${resolved[@]+"${resolved[@]}"} ${sanitizer[@]+"${sanitizer[@]}"} -only-testing:UnitTests CODE_SIGNING_ALLOWED=NO)
    xcodebuild test -quiet -scheme Kiwix -configuration Debug -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED" "${flags[@]}"
    line=$(counts "$DERIVED") || { echo "Mac: $line; see the results in $DERIVED/Logs/Test." >&2; exit 1; }
    echo "Mac: $line."
    sim=$(simulator)   # on its own line, so a failure to make it stops here
    xcodebuild test -quiet -scheme Kiwix -configuration Debug -destination "platform=iOS Simulator,id=$sim" \
        -derivedDataPath "$TOOLS/derived-ios" "${flags[@]}"
    line=$(counts "$TOOLS/derived-ios") || {
        echo "iPhone simulator: $line; see the results in $TOOLS/derived-ios/Logs/Test." >&2; exit 1; }
    echo "iPhone simulator: $line."
    xcodebuild build -quiet -scheme PrepareMe -configuration Debug -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$TOOLS/derived-app" ${resolved[@]+"${resolved[@]}"} CODE_SIGNING_ALLOWED=NO
    echo "PrepareMe (the phone app) builds for the simulator."
    xcodebuild build -quiet -scheme PrepareMe -configuration Debug -destination 'platform=macOS' \
        -derivedDataPath "$TOOLS/derived-app-mac-test" ${resolved[@]+"${resolved[@]}"} CODE_SIGNING_ALLOWED=NO
    echo "PrepareMe for the Mac builds."
    exit 0
fi
# USDA's key for the barcode lookup (owner, 2026-10-22, by click): read only by an install (a session's builds keep the
# project's DEMO_KEY, 50 lookups a day), from the file the owner saved in Household Private outside its Library, and
# handed to xcodebuild in a file only this account can read, never on its command line; deleted when the build ends
# (GitHub's build names its own files, written from the owner's secrets: .github/workflows/testflight.yml)
USDA_KEY_FILE="${PREPAREME_USDA_KEY_FILE:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Household Private/Keys/usda-key.txt}"
USDA_CONFIG="$TOOLS/usda-key.xcconfig"
usda=()
usda_key() {
    rm -f "$USDA_CONFIG"
    trap 'rm -f "$USDA_CONFIG"' EXIT
    if [ ! -f "$USDA_KEY_FILE" ]; then
        echo "No USDA key at iCloud Drive › Household Private › Keys › usda-key.txt (if it's there, open the folder in Finder so iCloud downloads it): the barcode lookup uses USDA's demo key, 50 lookups a day." >&2
        return 0
    fi
    local key
    key=$(tr -d '[:space:]' < "$USDA_KEY_FILE")
    case "$key" in
        '' | *[!A-Za-z0-9]*)
            echo "Household Private › Keys › usda-key.txt doesn't hold a key (letters and digits only): the barcode lookup uses USDA's demo key." >&2
            return 0 ;;
    esac
    (umask 077 && printf 'PREPAREME_USDA_KEY = %s\n' "$key" >> "$USDA_CONFIG")
    usda=(-xcconfig "$USDA_CONFIG")
    echo "USDA's key from Household Private is built in."
}
# UPC Database's key (owner, 2026-10-23), the same way into the same file: without it that source isn't asked
UPCDB_KEY_FILE="${PREPAREME_UPCDB_KEY_FILE:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Household Private/Keys/upcdatabase-key.txt}"
lookup_keys() {
    usda_key
    if [ ! -f "$UPCDB_KEY_FILE" ]; then
        echo "No UPC Database key at iCloud Drive › Household Private › Keys › upcdatabase-key.txt: the barcode lookup doesn't ask UPC Database." >&2
        return 0
    fi
    local key
    key=$(tr -d '[:space:]' < "$UPCDB_KEY_FILE")
    case "$key" in
        '' | *[!A-Za-z0-9]*)
            echo "Household Private › Keys › upcdatabase-key.txt doesn't hold a key (letters and digits only): the barcode lookup doesn't ask UPC Database." >&2
            return 0 ;;
    esac
    (umask 077 && printf 'PREPAREME_UPCDB_KEY = %s\n' "$key" >> "$USDA_CONFIG")
    usda=(-xcconfig "$USDA_CONFIG")
    echo "UPC Database's key from Household Private is built in."
}
# A phone build with none (Unlisted plan, phase 4): PREPAREME_NO_LOOKUP_KEYS=1 builds the keys in only for the Mac app,
# whose service hands them to adults' paired devices (/lookup-keys.json); a phone then uses those, else USDA's demo key
phone_lookup_keys() {
    if [ "${PREPAREME_NO_LOOKUP_KEYS:-}" = 1 ]; then
        echo "No barcode keys built in (PREPAREME_NO_LOOKUP_KEYS=1): an adult's device takes the Mac's."
        return 0
    fi
    lookup_keys
}
if [ "$mode" = --app-sim ] || [ "$mode" = --dev-sim ]; then   # the household's phone app (or PrepareMe Dev), in its own build folder, signed ad hoc for its Keychain
    derived="$TOOLS/derived-app"
    [ "$mode" = --dev-sim ] && derived="$TOOLS/derived-dev-sim"
    xcodebuild build -quiet -scheme PrepareMe -configuration Debug -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$derived" ${resolved[@]+"${resolved[@]}"} CODE_SIGN_IDENTITY=- \
        CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= ${dev[@]+"${dev[@]}"}
    [ "$mode" = --app-sim ] || dev_checked "$derived/Build/Products/Debug-iphonesimulator/PrepareMe.app"
    echo "$derived/Build/Products/Debug-iphonesimulator/PrepareMe.app"
    exit 0
fi
# The paid team once enrolled (a year's install, not 7 days): the team a Developer ID certificate belongs to, as only
# a paid team has one; else the first Apple Development certificate's (a personal team's, until then)
# The cable clock (docs/plans/2026-11-22-cable-clock.md): a cable install's date is its profile's, and Xcode reuses a
# saved one while it fits, so PrepareMe's own is set aside (only its, never another app's) and Xcode asks Apple for a
# new one. When the build ends, for any reason, profiles.py puts it back if no new one came.
set_aside=""
old_end=""
fresh_profile() {   # $1: the app ID whose profile is set aside (PrepareMe Dev passes its own, never the family's)
    profile_id=${1:-com.bigmike382.prepareme}
    set_aside=$(/usr/bin/python3 -I "$HERE/profiles.py" aside "$team" "$profile_id") || exit 1
    old_end=${set_aside#*$'\t'}
    set_aside=${set_aside%%$'\t'*}
    [ -z "$set_aside" ] \
        || trap 'rm -f "$USDA_CONFIG"; /usr/bin/python3 -I "$HERE/profiles.py" settle "$set_aside" "$team" "$profile_id" >/dev/null' EXIT
}
# The built app's end, and whether it is a fresh year: one sentence, after the line's first
fresh_said() {
    local said ends verdict
    said=$(/usr/bin/python3 -I "$HERE/profiles.py" report "$1" "$old_end") || return 1
    ends=${said%%$'\t'*}
    verdict=${said#*$'\t'}
    case "$verdict" in
        fresh) echo "It opens until $ends, a fresh year (later than the profile set aside)." ;;
        not-later) echo "But it opens until $ends, no later than before: Xcode reused the old profile. Tell a session." ;;
        *) echo "It opens until $ends (no saved PrepareMe profile was found to set aside)." ;;
    esac
}
team_id() {
    team=$(security find-certificate -c "Developer ID Application" -p 2>/dev/null | openssl x509 -noout -subject \
           2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1 || true)
    [ -n "$team" ] || team=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
           | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1 || true)
    [ -n "$team" ] || { echo "No Apple Development certificate: add your Apple Account in Xcode › Settings › Accounts, then run this again." >&2; exit 1; }
}
if [ "$mode" = --app-testflight ] || [ "$mode" = --app-ios-check ] || [ "$mode" = --dev-testflight ] \
        || [ "$mode" = --app-store ] || [ "$mode" = --app-store-check ]; then   # over-the-air plan, phase 2; Dev's, Unlisted plan phase 3; the store's, phase 5
    # one moment for all three: the build number from the UTC date and time (no leading zeros), the time stamped in
    now=$(date -u +%s)
    stamp=$(date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ)
    version="$(date -u -r "$now" +%Y).$((10#$(date -u -r "$now" +%m%d))).$((10#$(date -u -r "$now" +%H%M)))"
    channel=testflight
    case "$mode" in --app-store|--app-store-check) channel=appstore ;; esac
    stamps=(CURRENT_PROJECT_VERSION="$version" PREPAREME_BUILT="$stamp" PREPAREME_CHANNEL=$channel)
    check_upload=("$HOME/.venvs/prepareme-app/bin/python" -I -B "$HERE/check_upload.py" --cleared "$HERE/upload-cleared.txt"
                  --sample-approved "$approved_list")
    if [ "$channel" = appstore ]; then   # version 4.0 for every target; the store's own rules in the check
        stamps+=(MARKETING_VERSION="$STORE_VERSION")
        check_upload+=(--store)
    fi
    stamped() {   # the built app says what was stamped, and the export answer when one was set
        [ "$(plutil -extract CFBundleVersion raw "$1/Info.plist" 2>/dev/null)" = "$version" ] \
            && [ "$(plutil -extract PrepareMeChannel raw "$1/Info.plist" 2>/dev/null)" = "$channel" ] \
            && [ "$(plutil -extract PrepareMeBuilt raw "$1/Info.plist" 2>/dev/null)" = "$stamp" ] \
            && [ "$(plutil -extract UIDeviceFamily json -o - "$1/Info.plist" 2>/dev/null | tr -d ' ')" = "[1,2]" ] \
            || { echo "The built app doesn't carry its build number, time, channel or iPhone and iPad; not uploaded." >&2; exit 1; }
        if [ "$channel" = appstore ]; then   # decision 12's ID and the store version, read back from the built app
            [ "$(plutil -extract CFBundleShortVersionString raw "$1/Info.plist" 2>/dev/null)" = "$STORE_VERSION" ] \
                && [ "$(plutil -extract CFBundleIdentifier raw "$1/Info.plist" 2>/dev/null)" = com.bigmike382.prepareme ] \
                || { echo "The built app isn't version $STORE_VERSION of com.bigmike382.prepareme; not uploaded." >&2; exit 1; }
        fi
    }
    if [ "$mode" = --app-ios-check ]; then
        derived="$TOOLS/derived-app-ios-check"
        xcodebuild build -quiet -scheme PrepareMe -configuration Release -destination 'generic/platform=iOS' \
            -derivedDataPath "$derived" ${resolved[@]+"${resolved[@]}"} CODE_SIGNING_ALLOWED=NO "${stamps[@]}"
        app="$derived/Build/Products/Release-iphoneos/PrepareMe.app"
        stamped "$app"
        "${check_upload[@]}" "$app" --listing "$TOOLS/ios-check-files.txt"
        echo "Built (unsigned, not uploaded) as build $version: $app"
        echo "Every file in it, with its size: $TOOLS/ios-check-files.txt"
        exit 0
    fi
    if [ "$mode" = --app-store-check ]; then   # a session's: unsigned, the store's check, nothing uploaded
        derived="$TOOLS/derived-app-store-check"
        xcodebuild build -quiet -scheme PrepareMe -configuration Release -destination 'generic/platform=iOS' \
            -derivedDataPath "$derived" ${resolved[@]+"${resolved[@]}"} CODE_SIGNING_ALLOWED=NO "${stamps[@]}"
        app="$derived/Build/Products/Release-iphoneos/PrepareMe.app"
        stamped "$app"
        "${check_upload[@]}" "$app" --listing "$TOOLS/store-check-files.txt" || { echo "The store check failed (above)." >&2; exit 1; }
        echo "Built (unsigned, not uploaded) as version $STORE_VERSION, build $version: $app"
        echo "Every file in it, with its size: $TOOLS/store-check-files.txt"
        [ "$approved_list" = "$HERE/sample-approved.txt" ] \
            || echo "Rehearsal only: the sample isn't the approved one; --app-store refuses until it is."
        exit 0
    fi
    auth=()
    if [ "${GITHUB_ACTIONS:-}" = true ]; then
        # GitHub's machines (phase 4, decision 4 (a)): no Keychain and no signed-in Xcode, so the workflow names the
        # owner's team (never app/Kiwix/project.yml's, which is Kiwix's own: the first release failed on it) and Xcode
        # signs in the cloud with the owner's App Store Connect API key, from the workflow's secrets
        team=${PREPAREME_TEAM_ID:-}
        case "$team" in [A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) ;;
            *) echo "Not uploaded: the workflow names no team (PREPAREME_TEAM_ID, ten letters and digits)." >&2; exit 1 ;; esac
        if [ ! -s "${PREPAREME_ASC_KEY_FILE:-}" ] || [ -z "${PREPAREME_ASC_KEY_ID:-}" ] || [ -z "${PREPAREME_ASC_ISSUER_ID:-}" ]; then
            echo "Not uploaded: the App Store Connect API key's three secrets aren't all set (owner checks, section 78)." >&2
            exit 1
        fi
        auth=(-authenticationKeyPath "$PREPAREME_ASC_KEY_FILE" -authenticationKeyID "$PREPAREME_ASC_KEY_ID"
              -authenticationKeyIssuerID "$PREPAREME_ASC_ISSUER_ID")
    else
        team_id
    fi
    flag=false
    [ "$EXPORT_NON_EXEMPT" = YES ] && flag=true
    /usr/libexec/PlistBuddy -c "Set :ITSAppUsesNonExemptEncryption $flag" PrepareMeApp/Info.plist
    out="$TOOLS/testflight"
    if [ "$mode" = --dev-testflight ]; then out="$TOOLS/dev-testflight"   # Dev: the demo key only
    elif [ "$mode" = --app-store ]; then out="$TOOLS/appstore"   # the store: the demo key only, never the owner's
    else phone_lookup_keys; fi
    rm -rf "$out"
    mkdir -p "$out"
    xcodebuild archive -quiet -scheme PrepareMe -configuration Release -destination 'generic/platform=iOS' \
        -archivePath "$out/PrepareMe.xcarchive" -derivedDataPath "$TOOLS/derived-${out##*/}" \
        ${resolved[@]+"${resolved[@]}"} -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} DEVELOPMENT_TEAM="$team" \
        "${stamps[@]}" ${usda[@]+"${usda[@]}"} ${dev[@]+"${dev[@]}"}
    rm -f "$USDA_CONFIG"
    app="$out/PrepareMe.xcarchive/Products/Applications/PrepareMe.app"
    stamped "$app"
    [ "$mode" = --dev-testflight ] && dev_checked "$app"
    [ "$(plutil -extract ITSAppUsesNonExemptEncryption raw "$app/Info.plist" 2>/dev/null)" = "$flag" ] \
        || { echo "The built app doesn't carry the export answer; not uploaded." >&2; exit 1; }
    "${check_upload[@]}" "$app" --listing "$out/files.txt" \
        || { echo "Not uploaded: the built app failed its check (above)." >&2; exit 1; }
    # internal testing only: App Store Connect then never offers this build to external testers or the App Store. The
    # store build leaves that out (App Review could never take it) and only uploads: nothing here submits or releases.
    # Apple never renumbers either (manageAppVersionAndBuildNumber false): the Mac reads the build number as a date
    internal=(-c "Add :testFlightInternalTestingOnly bool true")
    [ "$mode" = --app-store ] && internal=()
    /usr/libexec/PlistBuddy -c "Add :method string app-store-connect" -c "Add :destination string upload" \
        -c "Add :teamID string $team" -c "Add :signingStyle string automatic" \
        ${internal[@]+"${internal[@]}"} -c "Add :manageAppVersionAndBuildNumber bool false" \
        -c "Add :uploadSymbols bool true" "$out/ExportOptions.plist" >/dev/null
    xcodebuild -exportArchive -archivePath "$out/PrepareMe.xcarchive" -exportOptionsPlist "$out/ExportOptions.plist" \
        -exportPath "$out/export" -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} \
        || { echo "Not uploaded (above). If it asks for an account, sign in to Xcode › Settings › Accounts and run this again." >&2; exit 1; }
    ends=$(date -r "$((now + 90 * 86400))" '+%B %-d, %Y')
    if [ "$mode" = --app-store ]; then
        echo "Uploaded PrepareMe $STORE_VERSION (build $version) to App Store Connect. Nothing was submitted or released:"
        echo "App Review, the Unlisted request and Release are yours, in App Store Connect. Once Apple has processed it,"
        echo "it also reaches the Owner group in TestFlight by itself; installed that way it opens until $ends."
        exit 0
    fi
    if [ "$mode" = --dev-testflight ]; then
        echo "Uploaded PrepareMe Dev build $version to its own TestFlight record (internal testing only). Once Apple has"
        echo "processed it, it reaches PrepareMe Dev's testing group (if that group takes builds by itself) and opens until $ends."
        exit 0
    fi
    printf '%s\n' "$version" > "$out/version.txt"   # GitHub's run reads it to add this build to the Family group
    echo "Uploaded PrepareMe build $version to TestFlight (internal testing only). Once Apple has processed it, it"
    echo "reaches the Owner group by itself and opens until $ends."
    exit 0
fi
if [ "$mode" = --app-phone ]; then   # the owner's step: the device on the cable, as app/Probe/build.sh --phone finds it
    team_id
    listing="$(mktemp -t prepareme-devices)"
    xcrun devicectl list devices --json-output "$listing" >/dev/null 2>&1 || true
    pick=$(/usr/bin/python3 -I "$HERE/pick_device.py" "$listing") \
        || { rm -f "$listing"; exit 1; }   # it said why
    rm -f "$listing"
    phone=${pick%%$'\t'*}   # the UDID; the rest of the line is the device's name and model
    label=${pick#*$'\t'}
    phone_lookup_keys
    fresh_profile
    xcodebuild build -quiet -scheme PrepareMe -configuration Release -destination "platform=iOS,id=$phone" \
        -derivedDataPath "$TOOLS/derived-app-phone" ${resolved[@]+"${resolved[@]}"} -allowProvisioningUpdates \
        -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM="$team" ${usda[@]+"${usda[@]}"}
    rm -f "$USDA_CONFIG"
    app="$TOOLS/derived-app-phone/Build/Products/Release-iphoneos/PrepareMe.app"
    xcrun devicectl device install app --device "$phone" "$app" >/dev/null
    echo "Installed PrepareMe on $label. $(fresh_said "$app/embedded.mobileprovision" \
        || echo "Its Downloads screen says how long this install opens.")"
    exit 0
fi
if [ "$mode" = --dev-phone ]; then   # PrepareMe Dev beside PrepareMe on the device on the cable (Unlisted plan, phase 3)
    team_id
    listing="$(mktemp -t prepareme-devices)"
    xcrun devicectl list devices --json-output "$listing" >/dev/null 2>&1 || true
    pick=$(/usr/bin/python3 -I "$HERE/pick_device.py" "$listing") \
        || { rm -f "$listing"; exit 1; }   # it said why
    rm -f "$listing"
    phone=${pick%%$'\t'*}
    label=${pick#*$'\t'}
    fresh_profile "$DEV_ID"   # Dev's own profile renews; the family's is never touched by a Dev build
    xcodebuild build -quiet -scheme PrepareMe -configuration Release -destination "platform=iOS,id=$phone" \
        -derivedDataPath "$TOOLS/derived-dev-phone" ${resolved[@]+"${resolved[@]}"} -allowProvisioningUpdates \
        -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM="$team" "${dev[@]}"
    app="$TOOLS/derived-dev-phone/Build/Products/Release-iphoneos/PrepareMe.app"
    dev_checked "$app"
    xcrun devicectl device install app --device "$phone" "$app" >/dev/null
    echo "Installed PrepareMe Dev on $label, beside PrepareMe (which is untouched). It pairs only with a session's test service. $(fresh_said "$app/embedded.mobileprovision" || true)"
    exit 0
fi
if [ "$mode" = --app-installer ]; then   # the monthly job's kept cable installer, never installed here (phase 3, layer 6)
    team_id
    phone_lookup_keys
    fresh_profile
    now=$(date -u +%s)
    version="$(date -u -r "$now" +%Y).$((10#$(date -u -r "$now" +%m%d))).$((10#$(date -u -r "$now" +%H%M)))"
    out="$TOOLS/derived-app-installer"
    # a generic iOS build: its development profile names every device registered to the team (each cable device was
    # registered by its first --app-phone), so it installs on any of them
    xcodebuild build -quiet -scheme PrepareMe -configuration Release -destination 'generic/platform=iOS' \
        -derivedDataPath "$out" ${resolved[@]+"${resolved[@]}"} -allowProvisioningUpdates DEVELOPMENT_TEAM="$team" \
        CURRENT_PROJECT_VERSION="$version" ${usda[@]+"${usda[@]}"}
    rm -f "$USDA_CONFIG"
    app="$out/Build/Products/Release-iphoneos/PrepareMe.app"
    ends=$(security cms -D -i "$app/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null) \
        || { echo "Not kept: the built app has no profile end date to read." >&2; exit 1; }
    # swapped in whole: the new copy beside the old, then each moved into place, so a stop midway leaves one that works
    new="$INSTALLERS/.new"
    rm -rf "${new:?}" && mkdir -p "$new"
    cp -R "$app" "$new/PrepareMe.app"
    printf '{"build": "%s", "built": "%s", "profile_ends": "%s"}\n' "$version" \
        "$(date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ)" "$ends" > "$new/installer.json"
    rm -rf "${INSTALLERS:?}/PrepareMe.app.old"
    [ ! -d "$INSTALLERS/PrepareMe.app" ] || mv "$INSTALLERS/PrepareMe.app" "$INSTALLERS/PrepareMe.app.old"
    mv "$new/PrepareMe.app" "$INSTALLERS/PrepareMe.app"
    mv "$new/installer.json" "$INSTALLERS/installer.json"
    rm -rf "${INSTALLERS:?}/PrepareMe.app.old" "${new:?}"
    echo "Kept PrepareMe build $version in $INSTALLERS (kiwix-mac/build.sh --app-kept). $(fresh_said \
        "$INSTALLERS/PrepareMe.app/embedded.mobileprovision")"
    exit 0
fi
if [ "$mode" = --app-mac ] || [ "$mode" = --app-mac-check ] || [ "$mode" = --app-mac-release-check ]; then   # (plan phase 6)
    app_id=com.bigmike382.prepareme
    service_id=$SERVICE_LABEL
    entitlements=PrepareMeApp/PrepareMe-macOS.entitlements   # project.yml's, in this copy of app/Kiwix
    settings=()
    derived="$TOOLS/derived-app-mac"
    service_build="$TOOLS/service-build"   # each mode its own, so a check never shares a file with an install
    if [ "$mode" = --app-mac-check ]; then   # its own ID, flag and exceptions: the scratch folder in place of home's
        app_id=com.bigmike382.prepareme.check
        service_id=com.bigmike382.prepareme.check.service
        derived="$TOOLS/derived-app-mac-check"
        service_build="$TOOLS/service-build-check"
        for kind in home-relative-path.read-only home-relative-path.read-write; do
            /usr/libexec/PlistBuddy -c "Delete :com.apple.security.temporary-exception.files.$kind" "$entitlements"
        done
        key=com.apple.security.temporary-exception.files.absolute-path.read-write
        /usr/libexec/PlistBuddy -c "Add :$key array" -c "Add :$key:0 string $CHECK_HOME/" "$entitlements"
        # the iCloud backup (concept-doc plan, phase A): the one test folder in iCloud Drive a check may write, with
        # made-up files only (PREPAREME_CHECK_BACKUP), so the sandbox's way into iCloud is proved before an install
        /usr/libexec/PlistBuddy -c "Add :$key:1 string $BACKUP_CHECK/" "$entitlements"
        # the inventory editor's ID check (plan phase 7): the venv's Python, read-only, by its absolute path
        key=com.apple.security.temporary-exception.files.absolute-path.read-only
        /usr/libexec/PlistBuddy -c "Add :$key array" -c "Add :$key:0 string $HOME/.venvs/prepareme-app/" \
            -c "Add :$key:1 string $HOME/.local/share/uv/python/" "$entitlements"
        settings=(INFOPLIST_KEY_CFBundleDisplayName="PrepareMe Check"
                  "SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) PREPAREME_APP PREPAREME_CHECK")
    elif [ "$mode" = --app-mac-release-check ]; then   # the install's build in its own folders, the project's DEMO_KEY
        derived="$TOOLS/derived-app-mac-release"
        service_build="$TOOLS/service-build-release"
    else
        lookup_keys
    fi
    xcodebuild build -quiet -scheme PrepareMe -configuration Release -destination 'platform=macOS' \
        -derivedDataPath "$derived" ${resolved[@]+"${resolved[@]}"} \
        PRODUCT_BUNDLE_IDENTIFIER="$app_id" \
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
        ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ${settings[@]+"${settings[@]}"} \
        ${usda[@]+"${usda[@]}"}
    rm -f "$USDA_CONFIG"
    built="$derived/Build/Products/Release/PrepareMe.app"
    # The phones' service inside it: macOS runs a sandboxed app's part only when it is sandboxed too, and a sandboxed
    # program needs its own Info.plist in its binary (FINDINGS F-067)
    mkdir -p "$service_build"
    service_plist="$service_build/Info.plist"
    rm -f "$service_plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $service_id" \
        -c "Add :CFBundleName string prepareme-service" "$service_plist" >/dev/null
    swift build -c release --package-path "$TOOLS/Service" --scratch-path "$service_build" \
        --product prepareme-service -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
        -Xlinker "$service_plist" >/dev/null
    cp "$(swift build -c release --package-path "$TOOLS/Service" --scratch-path "$service_build" \
        --show-bin-path)/prepareme-service" "$built/Contents/MacOS/prepareme-service"
    case "$(launchctl plist __TEXT,__info_plist "$built/Contents/MacOS/prepareme-service" 2>/dev/null)" in
        *"\"$service_id\""*) ;;
        *) echo "The service was built without its own Info.plist ($service_id); not installed." >&2; exit 1 ;; esac
    if [ "$mode" != --app-mac-check ]; then
        mkdir -p "$built/Contents/Library/LaunchAgents"
        cp PrepareMeApp/$SERVICE_LABEL.plist "$built/Contents/Library/LaunchAgents/"
    fi
    # The inventory editor's check (plan phase 7): the lists job's own code (readiness, guard, inventory's layout and
    # the two packer files they import, never their tests or scripts), carried inside the app so its rules are this
    # commit's, run by the venv's Python: the ID check of each row and the whole reader on a changed copy
    check_code="$built/Contents/Resources/check"
    rm -rf "$check_code"
    mkdir -p "$check_code/packer"
    (cd "$REPO" && git ls-files -z --cached --others --exclude-standard -- readiness guard inventory \
        | while IFS= read -r -d '' f; do case "$f" in */tests/*|inventory/test_*|inventory/make_*) ;;
            *.py) if [ -e "$f" ]; then printf '%s\0' "$f"; fi ;; esac; done \
        | tar --null -T - -cf -) | tar -xf - -C "$check_code"
    cp "$REPO/packer/__init__.py" "$REPO/packer/gitenv.py" "$check_code/packer/"
    # Printable References (2026-10-21): the card's own rules and page (paper/card.py through paper/cardtext.py, its
    # starter and its own frozen copy of the styles, paper/print_style.py, look 3's Task 1.2), never the print steps,
    # which run in the paper job
    mkdir -p "$check_code/paper"
    cp "$REPO/paper/__init__.py" "$REPO/paper/card.py" "$REPO/paper/cardtext.py" "$REPO/paper/print_style.py" \
        "$REPO/paper/card-starter.toml" "$check_code/paper/"
    made_up="$((200 + 19))-0$((4 + 5))-$((9000 + 999))"   # a made-up SSN's shape, assembled so no line holds one
    check_python=("$HOME/.venvs/prepareme-app/bin/python" -I -B -c \
        'import sys; sys.path.insert(0, sys.argv[1]); from readiness import checktext; sys.exit(checktext.main([]))' \
        "$check_code")
    if ! printf 'Drinking water jugs' | "${check_python[@]}" 2>/dev/null \
        || printf 'x %s' "$made_up" | "${check_python[@]}" 2>/dev/null; then
        echo "The inventory's ID check didn't work from the copy inside the app; not installed." >&2
        exit 1
    fi
    # and the whole-file check, on a copy of the made-up rehearsal inventory: every module it needs is in the app
    trial=$(mktemp -d)
    cp "$REPO/readiness/tests/fixtures/rehearsal.grist" "$trial/PrepareMe Inventory.grist"
    if ! printf '{"rows": []}' | "$HOME/.venvs/prepareme-app/bin/python" -I -B -c \
        'import sys; sys.path.insert(0, sys.argv[1]); from readiness import checktext; sys.exit(checktext.main(sys.argv[2:]))' \
        "$check_code" --rows --file "$trial/PrepareMe Inventory.grist" >/dev/null 2>&1; then
        rm -rf "$trial"
        echo "The inventory's whole-file check didn't work from the copy inside the app; not installed." >&2
        exit 1
    fi
    rm -rf "$trial"
    # and the card's read and check, on the made-up sample card: a clean card answers 0, and the app's own script line
    card_python=("$HOME/.venvs/prepareme-app/bin/python" -I -B -c \
        'import sys; sys.path.insert(0, sys.argv[1]); from paper import cardtext; sys.exit(cardtext.main(sys.argv[2:]))' \
        "$check_code")
    refused=0   # a code in a box is refused (exit 1), never taken for bad input (2)
    printf '{"fields": {"radio.repeater": "Wi-Fi password x"}, "numbers": []}' | "${card_python[@]}" check \
        >/dev/null 2>&1 || refused=$?
    if ! "${card_python[@]}" read < "$REPO/paper/tests/fixtures/card-sample.toml" >/dev/null 2>&1 \
        || ! printf '{"fields": {}, "numbers": [], "printed": "2026-10-21"}' | "${card_python[@]}" check >/dev/null 2>&1 \
        || [ "$refused" != 1 ]; then
        echo "The card's check didn't work from the copy inside the app; not installed." >&2
        exit 1
    fi
    release=()   # the install and its check: notarizing takes a secure timestamp on every signature
    if [ "$mode" = --app-mac-check ]; then
        identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
        identity=$(echo "$identities" | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Developer ID Application: .*/\1/p' | head -1)
        how="your Developer ID"
        if [ -z "$identity" ]; then
            identity=$(echo "$identities" | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Apple Development: .*/\1/p' | head -1)
            how="your Apple Development identity (Developer ID once it is in the Keychain)"
        fi
        if [ -z "$identity" ]; then
            identity=-
            how="ad hoc (a check only)"
        fi
    else   # Developer ID only, never the fallback: notarizing refuses any other (it said why)
        identity=$(/usr/bin/python3 -I "$HERE/mac_release.py" identity) || exit 1
        how="your Developer ID"
        release=(--timestamp)
        # every other program inside the app first, each on its own (none today but the service, signed below)
        loose=$(mktemp)
        /usr/bin/python3 -I "$HERE/mac_release.py" programs "$built" --skip Contents/MacOS/prepareme-service > "$loose" \
            || { rm -f "$loose"; exit 1; }   # it said why
        while IFS= read -r -d '' part; do
            codesign --force --options runtime --timestamp --sign "$identity" "$built/$part" \
                || { rm -f "$loose"; echo "Signing $part with $how failed (above); not installed." >&2; exit 1; }
        done < "$loose"
        rm -f "$loose"
    fi
    codesign --force --options runtime ${release[@]+"${release[@]}"} --identifier "$service_id" \
        --entitlements PrepareMeApp/PrepareMeService.entitlements --sign "$identity" "$built/Contents/MacOS/prepareme-service" \
        || { echo "Signing the service with $how failed (above); not installed. Unlock the login Keychain and run this again." >&2; exit 1; }
    codesign --force ${release[@]+"${release[@]}"} --sign "$identity" --preserve-metadata=entitlements,flags "$built" \
        || { echo "Signing PrepareMe with $how failed (above); not installed." >&2; exit 1; }
    codesign --verify --strict --deep "$built"
    if [ "$mode" != --app-mac-check ]; then   # each program: Developer ID, secure timestamp, hardened runtime
        /usr/bin/python3 -I "$HERE/mac_release.py" check "$built" \
            || { echo "Not installed: notarizing would refuse the app as signed (above)." >&2; exit 1; }
    fi
    for part in "$built" "$built/Contents/MacOS/prepareme-service"; do
        case "$(codesign -dv "$part" 2>&1)" in *"flags="*"(runtime)"*) ;;
            *) echo "$part was built without the hardened runtime; not installed." >&2; exit 1 ;; esac
    done
    app_entitlements=$(codesign -d --entitlements - --xml "$built" 2>/dev/null)
    service_entitlements=$(codesign -d --entitlements - --xml "$built/Contents/MacOS/prepareme-service" 2>/dev/null)
    case "$app_entitlements" in *get-task-allow*) echo "Built with the debugger entitlement; not installed." >&2; exit 1 ;; esac
    case "$app_entitlements" in *network.server*) echo "The app itself would serve the network; not installed." >&2; exit 1 ;; esac
    case "$app_entitlements" in *personal-information.location*) ;;   # the street map's Where am I (task 12)
        *) echo "Built without the location entitlement; not installed." >&2; exit 1 ;; esac
    case "$(plutil -extract NSLocationWhenInUseUsageDescription raw "$built/Contents/Info.plist" 2>/dev/null)" in
        *"this Mac"*) ;;   # without it macOS never asks, and the Mac never finds where it is
        *) echo "Built without the Mac's own location words; not installed." >&2; exit 1 ;; esac
    case "$service_entitlements" in *app-sandbox*network.server*) ;;
        *) echo "The service was signed without its sandbox; not installed." >&2; exit 1 ;; esac
    if [ "$mode" = --app-mac-check ]; then
        case "$app_entitlements" in *"$CHECK_HOME/"*) ;; *) echo "Built without the check folder's exception." >&2; exit 1 ;; esac
        case "$app_entitlements" in *home-relative-path*) echo "The check build kept the real folders' exceptions." >&2; exit 1 ;; esac
        case "$app_entitlements" in *"PrepareMe Backup/"*) echo "The check build kept the real backup folder's exception." >&2; exit 1 ;; esac
        if [ "$(printf '%s' "$app_entitlements" | grep -o 'Mobile Documents[^<]*' | grep -vc 'PrepareMe Backup Check/$')" != 0 ]; then
            echo "The check build reaches more of iCloud Drive than its one test folder." >&2; exit 1
        fi
        # every session's check build lands in the one derived folder, so the next build replaced this one mid-check
        # (2026-11-17), and its sandbox only reaches the check folder it was built for: the session keeps its own copy
        kept="$CHECK_HOME/app/PrepareMe.app"
        rm -rf "$kept"
        mkdir -p "$CHECK_HOME/app"
        ditto "$built" "$kept"
        codesign --verify --deep --strict "$kept" || { echo "The kept copy's signature didn't hold: $kept" >&2; exit 1; }
        echo "Built and signed with $how, not installed: $kept (copied from $built, which the next build replaces)"
        echo "Open it with: open -n --env PREPAREME_CHECK_HOME=\"$CHECK_HOME\" \"$kept\""
        echo "For the iCloud backup's test folder (made-up files only), add: --env PREPAREME_CHECK_BACKUP=\"$BACKUP_CHECK\""
        exit 0
    fi
    case "$app_entitlements" in *"/Library/Application Support/PrepareMe/delivery/"*) ;;
        *) echo "Built without the library folder's exception; not installed." >&2; exit 1 ;; esac
    case "$app_entitlements" in *"/Library/Application Support/PrepareMe/inventory/"*) ;;
        *) echo "Built without the inventory folder's exception; not installed." >&2; exit 1 ;; esac
    case "$app_entitlements" in *"/Library/Application Support/PrepareMe/downloads/"*) ;;
        *) echo "Built without the downloads folder's exception; not installed." >&2; exit 1 ;; esac
    # the equipment manuals (top-ten plan, phase 7): their folder, and the packer's report beside it
    case "$app_entitlements" in *"/Library/Application Support/PrepareMe/item-manuals/"*) ;;
        *) echo "Built without the equipment manuals folder's exception; not installed." >&2; exit 1 ;; esac
    case "$app_entitlements" in *"/Library/Application Support/PrepareMe/item-manuals-report.json"*) ;;
        *) echo "Built without the equipment manuals report's exception; not installed." >&2; exit 1 ;; esac
    # the iCloud backup (concept-doc plan, phase A): its folder in iCloud Drive and its local status folder, no more
    case "$app_entitlements" in *"/Library/Mobile Documents/com~apple~CloudDocs/PrepareMe Backup/"*) ;;
        *) echo "Built without the iCloud backup folder's exception; not installed." >&2; exit 1 ;; esac
    case "$app_entitlements" in *"/Library/Application Support/PrepareMe/backup/"*) ;;
        *) echo "Built without the backup status folder's exception; not installed." >&2; exit 1 ;; esac
    # ... and Household pages (concept-doc plan, phase C): exactly its three folders in Household Private, never the
    # whole of it (its settings.toml and equipment.md stay out of reach); and Printable References (2026-10-21): Plans
    # (the card file) and Print (read-only: the PDFs the paper job makes); Essential Documents' iCloud copy (phase 4)
    icloud_expected="Mobile Documents/com~apple~CloudDocs/Household Private/Backups/Documents/
Mobile Documents/com~apple~CloudDocs/Household Private/Backups/Household pages/
Mobile Documents/com~apple~CloudDocs/Household Private/Library/daily/
Mobile Documents/com~apple~CloudDocs/Household Private/Library/media/
Mobile Documents/com~apple~CloudDocs/Household Private/Plans/
Mobile Documents/com~apple~CloudDocs/Household Private/Print/
Mobile Documents/com~apple~CloudDocs/PrepareMe Backup/"
    if [ "$(printf '%s' "$app_entitlements" | grep -o 'Mobile Documents[^<]*' | LC_ALL=C sort)" != "$icloud_expected" ] \
        || case "$app_entitlements" in *"PrepareMe Backup Check"*) true ;; *) false ;; esac; then
        echo "Built with more of iCloud Drive than the backup and household pages folders; not installed." >&2; exit 1
    fi
    # Printable References: Print is read-only (the app only opens the paper job's PDFs), never in the read-write list
    written=$(mktemp)
    printf '%s' "$app_entitlements" > "$written"
    if /usr/libexec/PlistBuddy -c "Print :com.apple.security.temporary-exception.files.home-relative-path.read-write" \
        "$written" 2>/dev/null | grep -q "Household Private/Print/"; then
        rm -f "$written"
        echo "Built with write access to Household Private › Print; not installed." >&2; exit 1
    fi
    rm -f "$written"
    for part in "$app_entitlements" "$service_entitlements"; do   # plan phase 10: pairing from the app
        case "$part" in *"/Library/Application Support/PrepareMe/pairing/"*) ;;
            *) echo "Built without the pairing folder's exception; not installed." >&2; exit 1 ;; esac
    done
    notary="$TOOLS/notary"   # what is sent to Apple's notary service, and its answers
    rm -rf "$notary" && mkdir -p "$notary"
    ditto -c -k --keepParent "$built" "$notary/PrepareMe.zip"   # notarytool takes a zip; the ticket goes on the app
    if [ "$mode" = --app-mac-release-check ]; then
        echo "Built, signed with $how and checked (each program: Developer ID, secure timestamp, hardened runtime), not installed: $built"
        echo "The zip an install sends to Apple's notary service (nothing was sent): $notary/PrepareMe.zip"
        exit 0
    fi
    # ps's whole list read first, then searched: piped into grep -q, ps was cut off once grep had its match, and under
    # pipefail that read as "not running", so an install replaced PrepareMe while it was open (2026-10-18)
    if pgrep -x PrepareMe >/dev/null && grep -q "^$MAC_APP/" <<<"$(ps -ax -o args=)"; then
        echo "Built, but PrepareMe is running: quit it (PrepareMe › Quit PrepareMe) and run this again to install." >&2
        exit 1
    fi
    # Notarized, then stapled, so it opens on a Mac that has never been online (Unlisted plan, phase 2). When that
    # can't be done it installs anyway and says why: a fix for the phones is never held up by Apple (owner, 2026-11-22)
    echo "Sending PrepareMe to Apple's notary service and waiting up to ${NOTARY_WAIT%m} minutes for its answer..."
    why=""
    answer=$(xcrun notarytool submit "$notary/PrepareMe.zip" --keychain-profile "$NOTARY_PROFILE" --wait --timeout "$NOTARY_WAIT" \
        --output-format json 2>"$notary/said.txt") || true
    status=$(printf '%s' "$answer" | plutil -extract status raw -o - - 2>/dev/null || true)
    if [ "$status" = Accepted ]; then
        if ! xcrun stapler staple "$built" >"$notary/staple.txt" 2>&1; then
            why="stapling Apple's ticket to the app failed ($notary/staple.txt)"
        elif ! xcrun stapler validate "$built" >/dev/null 2>&1; then
            why="the stapled ticket didn't validate"
        else
            case "$(spctl -a -vv -t exec "$built" 2>&1)" in *"source=Notarized Developer ID"*) ;;
                *) why="Gatekeeper didn't call the stapled app Notarized Developer ID" ;; esac
        fi
    elif [ "$status" = "In Progress" ]; then   # --timeout ended the wait (or, below, an answer with no status)
        why="Apple's notary service hadn't answered within ${NOTARY_WAIT%m} minutes; the next install tries again"
    elif [ -n "$status" ]; then
        id=$(printf '%s' "$answer" | plutil -extract id raw -o - - 2>/dev/null || true)
        xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" "$notary/log.json" >/dev/null 2>&1 || true
        why="Apple's notary service answered $status (its reasons: $notary/log.json)"
    elif grep -q "No Keychain password item found" "$notary/said.txt"; then
        why="the notary sign-in isn't stored yet (owner checks)"
    else
        why="Apple's notary service couldn't be reached or hadn't answered within ${NOTARY_WAIT%m} minutes; the next install tries again ($notary/said.txt)"
    fi
    rm -rf "$MAC_APP"
    ditto "$built" "$MAC_APP"
    # macOS keeps the icon it saw at this path before and showed Kiwix's kiwi at small sizes after the first install
    # with PrepareMe's own icon (2026-10-15); a new date and registering the copy again make it read the new one
    touch "$MAC_APP"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f \
        "$MAC_APP" || true
    if launchctl print "gui/$(id -u)/$SERVICE_LABEL" >/dev/null 2>&1; then   # the phones' service, on the new copy
        launchctl kickstart -k "gui/$(id -u)/$SERVICE_LABEL" >/dev/null 2>&1 || true
        restarted=" The phones' service was restarted on the new copy, but isn't answering yet:"
        restarted+=" PrepareMe's Settings, on its Phones tab, says more."
        for _ in $(seq 1 30); do   # a plain connection, no request: is it listening on 8744 again (a new signature
                                   # can take macOS 10 s or more to look over first, 2026-10-14)
            if (exec 3<>/dev/tcp/127.0.0.1/8744) 2>/dev/null; then
                restarted=" The phones' service was restarted on the new copy and answers."
                break
            fi
            sleep 1
        done
    fi
    open "$MAC_APP"   # its checks and the service's registration run while it is open (window or not)
    echo "Installed and opened $MAC_APP (Kiwix $TAG with PrepareMe's changes), signed with $how.${restarted:-}"
    if [ -n "$why" ]; then
        echo "Not notarized: $why. The USB drive keeps the last notarized copy."
        exit 0
    fi
    # The stapled app zipped (stapled first, then zipped) and kept for the USB backup's locked image, in its own folder
    # beside the iPhone and iPad kept installer, with what a rebuild needs if GitHub is out of reach (audit R6): the
    # source as one file and the two build downloads (APFS clones: no extra room). Swapped in whole; only notarized
    # copies are kept. Chained with &&, as errexit doesn't stop a command list that is tested
    new="$INSTALLERS/.mac-new"
    info="$built/Contents/Info.plist"
    if rm -rf "${new:?}" && mkdir -p "$new" \
            && ditto -c -k --keepParent "$built" "$new/PrepareMe for Mac.zip" \
            && git -C "$REPO" bundle create -q "$new/prepareme-source.bundle" main \
            && { cp -c "$TOOLS/$CORE" "$TOOLS/xcodegen.zip" "$new/" 2>/dev/null \
                 || cp "$TOOLS/$CORE" "$TOOLS/xcodegen.zip" "$new/"; } \
            && printf '{"version": "%s", "build": "%s", "commit": "%s", "made": "%s"}\n' \
                "$(plutil -extract CFBundleShortVersionString raw "$info")" "$(plutil -extract CFBundleVersion raw "$info")" \
                "$(git -C "$REPO" rev-parse --short HEAD)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$new/mac.json" \
            && rm -rf "${INSTALLERS:?}/mac.old" \
            && { [ ! -d "$INSTALLERS/mac" ] || mv "$INSTALLERS/mac" "$INSTALLERS/mac.old"; } \
            && mv "$new" "$INSTALLERS/mac" && rm -rf "${INSTALLERS:?}/mac.old"; then
        echo "Notarized and stapled. A zipped copy, the source and the two build downloads are kept in $INSTALLERS/mac for the USB drive."
    else
        echo "Notarized and stapled, but the copy for the USB drive couldn't be kept (above); the drive keeps its last one."
    fi
    exit 0
fi
if [ "$mode" = --ios-sim ]; then   # the phones' Kiwix, never changed, in its own build folder
    xcodebuild build -quiet -scheme Kiwix -configuration Debug -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$TOOLS/derived-sim" CODE_SIGNING_ALLOWED=NO
    echo "$TOOLS/derived-sim/Build/Products/Debug-iphonesimulator/Kiwix.app"
    exit 0
fi

xcodebuild build -quiet -scheme Kiwix -configuration Release -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" ${resolved[@]+"${resolved[@]}"} \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" INFOPLIST_KEY_CFBundleDisplayName="$APP_NAME" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
    ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
built="$DERIVED/Build/Products/Release/Kiwix.app"

# Signed again with the owner's identity, keeping the entitlements and the hardened runtime the build gave it
identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
identity=$(echo "$identities" | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Developer ID Application: .*/\1/p' | head -1)
how="your Developer ID"
if [ -z "$identity" ]; then
    identity=$(echo "$identities" | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Apple Development: .*/\1/p' | head -1)
    how="your Apple Development identity (Developer ID once it is in the Keychain)"
fi
if [ -z "$identity" ]; then
    how="ad hoc (no identity of yours in the Keychain), so the firewall and the folder picks ask again after a rebuild"
elif ! codesign --force --sign "$identity" --preserve-metadata=entitlements,flags "$built"; then
    # never an ad hoc install in its place: that would lose the folder picks and the firewall's answer
    echo "Signing with $how failed (above); not installed. Unlock the login Keychain and run this again." >&2
    exit 1
fi
codesign --verify --strict "$built"
case "$(codesign -dv "$built" 2>&1)" in   # captured whole: grep -q stopping early would fail the pipe
    *"flags="*"(runtime)"*) ;;
    *) echo "Built without the hardened runtime; not installed." >&2; exit 1 ;;
esac
entitlements=$(codesign -d --entitlements - --xml "$built" 2>/dev/null)
if [ "$mode" != --unchanged ]; then
    case "$entitlements" in *"$REQUESTS"*) ;; *) echo "Built without the requests folder's exception; not installed." >&2; exit 1 ;; esac
fi
case "$entitlements" in *get-task-allow*) echo "Built with the debugger entitlement; not installed." >&2; exit 1 ;; esac
if [ "$mode" = --no-install ]; then
    echo "Built and signed with $how, not installed: $built"
    exit 0
fi

if pgrep -x Kiwix >/dev/null && grep -q "^$DEST/" <<<"$(ps -ax -o args=)"; then   # read whole first (see above)
    echo "Built, but $APP_NAME is running: quit it and run this again to install." >&2
    exit 1
fi
rm -rf "$DEST"
ditto "$built" "$DEST"
echo "Installed $DEST ($([ "$mode" = --unchanged ] && echo "unchanged" || echo "from app/Kiwix"), Kiwix $TAG), signed with $how."
