"""Sets PrepareMe's saved signing profile aside so a cable build gets a fresh one (Unlisted plan, phase 2, the cable
clock: docs/plans/2026-11-22-cable-clock.md).

    /usr/bin/python3 -I kiwix-mac/profiles.py aside TEAM APP_ID
    /usr/bin/python3 -I kiwix-mac/profiles.py settle FOLDER TEAM APP_ID
    /usr/bin/python3 -I kiwix-mac/profiles.py report PROFILE [OLD_END]

A cable install's "opens until" date is its signing profile's end, and Xcode reuses a saved profile while one fits
(the owner's check, 2026-11-22: a reinstall kept November 14, 2027; with the saved profiles moved aside, the next one
got a new year). `aside` moves out of Xcode's folders only the profiles that are for iOS, for development
(get-task-allow) and for exactly TEAM.APP_ID, into a new dated folder beside them, never inside, and prints that folder,
a tab, and the latest end date among them (ISO; empty when none had one). It prints nothing when none matched.
`settle` runs when the build ends: if no profile for the app is back in Xcode's folders, it puts the set-aside ones back
where they were; otherwise it leaves them in the dated folder. Nothing here deletes a profile. `report` prints the built
app's profile end in the Mac's local time (as the app shows it), a tab, and "fresh" (later than OLD_END), "not-later", or "first" (no OLD_END).

Standard library only, and Python 3.9 (macOS's own /usr/bin/python3): no `match`, no `X | Y` types.
"""

import os
import plistlib
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
DIRS = [os.path.join(HOME, "Library/Developer/Xcode/UserData/Provisioning Profiles"),
        os.path.join(HOME, "Library/MobileDevice/Provisioning Profiles")]  # the second is older Xcodes'
ASIDE = os.path.join(HOME, "Library/Developer/Xcode/UserData/Provisioning Profiles (PrepareMe set aside)")
ORIGINS = "moved-from.txt"  # in each dated folder: one "file name<TAB>folder it came from" line per profile


def read(path):
    """A profile's property list: `security cms -D` for a real (signed) one; a plain property list as it is (tests)."""
    with open(path, "rb") as handle:
        raw = handle.read()
    try:
        return plistlib.loads(raw)
    except Exception:
        pass
    done = subprocess.run(["/usr/bin/security", "cms", "-D", "-i", path], capture_output=True)
    if done.returncode != 0:
        return None
    try:
        return plistlib.loads(done.stdout)
    except Exception:
        return None


def is_ours(info, team, app_id):
    if not isinstance(info, dict):
        return False
    rights = info.get("Entitlements") or {}
    return (rights.get("application-identifier") == team + "." + app_id
            and "iOS" in (info.get("Platform") or []) and rights.get("get-task-allow") is True)


def ours(dirs, team, app_id):
    """(folder, file name, end date or None) for each of the app's development profiles in `dirs`."""
    found = []
    for folder in dirs:
        try:
            names = sorted(os.listdir(folder))
        except OSError:
            continue
        for name in names:
            if not name.endswith(".mobileprovision"):
                continue
            info = read(os.path.join(folder, name))
            if is_ours(info, team, app_id):
                found.append((folder, name, info.get("ExpirationDate")))
    return found


def iso(when):
    return when.replace(tzinfo=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if when else ""


def aside(team, app_id, dirs=None, root=ASIDE):
    found = ours(dirs or DIRS, team, app_id)
    if not found:
        return None
    stamp = time.strftime("%Y-%m-%d-%H%M%S")
    folder = os.path.join(root, stamp)
    n = 1
    while os.path.exists(folder):
        n += 1
        folder = os.path.join(root, "%s-%d" % (stamp, n))
    os.makedirs(folder)
    # the record first, on the disk before any move, so a stop midway still says where each one goes back
    with open(os.path.join(folder, ORIGINS), "w") as record:
        record.writelines("%s\t%s\n" % (name, origin) for origin, name, _ in found)
        record.flush()
        os.fsync(record.fileno())
    for origin, name, _ in found:
        shutil.move(os.path.join(origin, name), os.path.join(folder, name))
    ends = [end for _, _, end in found if end]
    return folder, iso(max(ends)) if ends else ""


def settle(folder, team, app_id, dirs=None):
    """"kept aside" when a profile for the app is back in Xcode's folders, else "put back" (each to where it was)."""
    if ours(dirs or DIRS, team, app_id):
        return "kept aside"
    with open(os.path.join(folder, ORIGINS)) as record:
        lines = [line.rstrip("\n").split("\t", 1) for line in record if "\t" in line]
    for name, origin in lines:
        source, target = os.path.join(folder, name), os.path.join(origin, name)
        if os.path.exists(source) and not os.path.exists(target):
            os.makedirs(origin, exist_ok=True)
            shutil.move(source, target)
    if all(not os.path.exists(os.path.join(folder, name)) for name, _ in lines):
        os.remove(os.path.join(folder, ORIGINS))
        os.rmdir(folder)  # empty now: every profile is back
    return "put back"


def report(profile, old_end=""):
    try:
        info = read(profile)
    except OSError:
        info = None
    end = info.get("ExpirationDate") if isinstance(info, dict) else None
    if not end:
        return None
    # the plist's moment is UTC with no zone; the app shows it in the device's local time, so say it that way
    local = end.replace(tzinfo=timezone.utc).astimezone()
    said = "%s %d, %d" % (local.strftime("%B"), local.day, local.year)
    if not old_end:
        return said, "first"
    old = datetime.strptime(old_end, "%Y-%m-%dT%H:%M:%SZ")
    return said, "fresh" if end > old else "not-later"


def main(argv):
    if len(argv) == 3 and argv[0] == "aside":
        done = aside(argv[1], argv[2])
        if done:
            print("%s\t%s" % done)
        return 0
    if len(argv) == 4 and argv[0] == "settle":
        print(settle(argv[1], argv[2], argv[3]))
        return 0
    if len(argv) in (2, 3) and argv[0] == "report":
        done = report(argv[1], argv[2] if len(argv) == 3 else "")
        if not done:
            print("The built app has no profile end date to read.", file=sys.stderr)
            return 1
        print("%s\t%s" % done)
        return 0
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
