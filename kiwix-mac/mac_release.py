"""The Mac app's release signing for build.sh --app-mac and --app-mac-release-check (Unlisted plan, phase 2;
docs/plans/2026-11-22-unlisted-phase-2-mac.md): Apple's notary service accepts only Developer ID signatures with a
secure timestamp and the hardened runtime on every program inside the app.

    /usr/bin/python3 -I kiwix-mac/mac_release.py identity
        the Developer ID Application identity to sign with: of several, the certificate that ends last, so a new one
        takes over on the day it is added (over-the-air plan, phase 6). Prints its SHA-1; never the Apple Development
        fallback the check build may use. Exit 1, with a sentence for the owner, when there is none.
    /usr/bin/python3 -I kiwix-mac/mac_release.py programs APP [--skip RELATIVE]...
        the loose programs inside APP that build.sh signs one by one before the app itself (every Mach-O file but the
        app's own executable and each --skip), NUL-separated. Exit 1 for a program inside a nested bundle.
    /usr/bin/python3 -I kiwix-mac/mac_release.py check APP
        every program in APP and APP itself, each read with `codesign -dvv`: signed by a Developer ID Application
        certificate, with a secure timestamp, under the hardened runtime. Prints each fault; exit 1 with any.

Standard library only, and Python 3.9 (macOS's own /usr/bin/python3): no `match`, no `X | Y` types.
"""

import calendar
import os
import plistlib
import subprocess
import sys
import time

DEVELOPER_ID = "Developer ID Application: "
# Mach-O and universal binaries, in either byte order
MAGIC = {b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe",
         b"\xbe\xba\xfe\xca"}
NESTED = (".app", ".appex", ".bundle", ".framework", ".xpc", ".plugin")
NONE = ("No Developer ID Application certificate in the login Keychain, so the Mac app can't be notarized; not "
        "installed. Add it in Xcode › Settings › Accounts › Manage Certificates, then run this again.")


def latest(identities, ends):
    """The SHA-1 among `identities` (`security find-identity -v -p codesigning`'s text) naming a Developer ID
    Application certificate whose end (`ends`: SHA-1 -> seconds since 1970) is last; None when there is none."""
    found = []
    for line in identities.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[2].startswith('"' + DEVELOPER_ID) and parts[1] in ends:
            found.append((ends[parts[1]], parts[1]))
    return max(found)[1] if found else None


def cert_ends(certificates):
    """`security find-certificate -a -Z -p` output -> {SHA-1: the certificate's end, seconds since 1970}, each end
    read by /usr/bin/openssl."""
    ends, sha1, pem = {}, None, None
    for line in certificates.splitlines():
        if line.startswith("SHA-1 hash: "):
            sha1 = line.split(": ", 1)[1].strip()
        elif line.startswith("-----BEGIN CERTIFICATE-----"):
            pem = [line]
        elif pem is not None:
            pem.append(line)
            if line.startswith("-----END CERTIFICATE-----"):
                said = subprocess.run(["/usr/bin/openssl", "x509", "-noout", "-enddate"], input="\n".join(pem) + "\n",
                                      capture_output=True, text=True).stdout
                if sha1 and said.startswith("notAfter="):
                    ends[sha1] = end_seconds(said)
                sha1, pem = None, None
    return ends


def end_seconds(said):
    """openssl's "notAfter=Feb  1 12:00:00 2031 GMT" -> seconds since 1970"""
    return calendar.timegm(time.strptime(" ".join(said.split("=", 1)[1].split()), "%b %d %H:%M:%S %Y %Z"))


def is_program(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) in MAGIC
    except OSError:
        return False


def all_programs(app):
    """Every Mach-O file under `app`, relative to it, in a fixed order."""
    found = []
    for root, dirs, files in os.walk(app):
        dirs.sort()
        for name in sorted(files):
            path = os.path.join(root, name)
            if not os.path.islink(path) and is_program(path):
                found.append(os.path.relpath(path, app))
    return found


def programs(app, skip=()):
    """The loose programs build.sh signs one by one; ValueError for one inside a nested bundle."""
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
        main = os.path.join("Contents", "MacOS", plistlib.load(f)["CFBundleExecutable"])
    loose = []
    for rel in all_programs(app):
        # shortcut: a nested bundle's program would need its bundle signed, not the file; none exists today, so it is
        # refused rather than signed wrongly. Sign the bundle here if one is ever added
        if any(part.endswith(NESTED) for part in rel.split(os.sep)[:-1]):
            raise ValueError(rel)
        if rel != main and rel not in skip:
            loose.append(rel)
    return loose


def faults(name, said):
    """What `codesign -dvv`'s text `said` for `name` lacks for notarizing."""
    found = []
    if ("Authority=" + DEVELOPER_ID) not in said:
        found.append(name + " isn't signed with a Developer ID")
    if "\nTimestamp=" not in "\n" + said:   # "Signed Time=" is the Mac's own clock, which notarizing refuses
        found.append(name + " has no secure timestamp")
    if not any(line.startswith("CodeDirectory") and "(runtime)" in line for line in said.splitlines()):
        found.append(name + " isn't under the hardened runtime")
    return found


def check(app):
    found = []
    for rel in [""] + all_programs(app):
        path = os.path.join(app, rel) if rel else app
        said = subprocess.run(["/usr/bin/codesign", "-dvv", path], capture_output=True, text=True).stderr
        found += faults(rel or os.path.basename(app), said)
    return found


def main(argv):
    if argv[:1] == ["identity"] and len(argv) == 1:
        run = lambda *a: subprocess.run(["/usr/bin/security", *a], capture_output=True, text=True).stdout
        pick = latest(run("find-identity", "-v", "-p", "codesigning"),
                      cert_ends(run("find-certificate", "-a", "-Z", "-p", "-c", DEVELOPER_ID.rstrip(": "))))
        if pick is None:
            print(NONE, file=sys.stderr)
            return 1
        print(pick)
        return 0
    if argv[:1] == ["programs"] and len(argv) >= 2 and len(argv) % 2 == 0 and set(argv[2::2]) <= {"--skip"}:
        try:
            loose = programs(argv[1], tuple(argv[3::2]))
        except ValueError as e:
            print(f"{e} is a program inside a nested bundle, which build.sh doesn't sign yet; not installed.",
                  file=sys.stderr)
            return 1
        sys.stdout.write("".join(rel + "\0" for rel in loose))
        return 0
    if argv[:1] == ["check"] and len(argv) == 2:
        found = check(argv[1])
        for line in found:
            print(line, file=sys.stderr)
        return 1 if found else 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
