"""What goes to Apple: every file in a built PrepareMe.app, checked before any TestFlight upload (over-the-air plan,
phase 2). Nothing from Household Private and no library content may be in it, only the app, the meaning model, the
street map's engine and the two lookup keys already built in.

    check_upload.py APP [--listing FILE] [--cleared FILE] [--sample-approved FILE] [--store]

Lists every file with its size (into FILE when given), then refuses (exit 1) a library or household file by its kind
or name, and runs the ID check (guard) over every text file and every property list, binary ones read as text.
Prints file, line and kind only, never a value, as guard does. A file whose whole SHA-256 is in the --cleared list (the
owner ruled its hits false, never a session: upload-cleared.txt) skips the ID check; any change to it checks it again.
The one library content allowed is the sample library the owner read (Unlisted plan, phase 4): each of its three files
in the app's Sample folder, by its name and its whole SHA-256 in the --sample-approved list (sample-approved.txt); the
same name with any other content, or in any other place, and any other file in the Sample folder, is refused.
--store (Unlisted plan, phase 5: `build.sh --app-store` and `--app-store-check`) also refuses any app that isn't the store
build: its stamp `appstore`; the lookup keys only the project's demo key and nothing (never the owner's); the family's
app ID; a version of at least 4.0; English only, as the store reads languages (the app's own top-level .lproj folders
and its Info.plist's CFBundleLocalizations, not a package's resource bundle); and all three sample files present. It
names what is wrong, never a key's value.
Standard library and guard only.
"""

from __future__ import annotations

import argparse
import hashlib
import plistlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # the checkout's guard, run with -I
from guard.scan import HIT_LINE, a_kind, is_text, scan_name, scan_text, shown  # noqa: E402

# Library files (ZIM, map tiles, the inventory and its databases) and owner's documents never go in the app
REFUSED_SUFFIXES = {".zim", ".zimaa", ".pmtiles", ".mbtiles", ".grist", ".sqlite", ".sqlite3", ".db", ".pdf",
                    ".docx", ".xlsx", ".numbers", ".pages", ".heic", ".mov", ".mp4", ".sparsebundle"}
# Household Private's own files by name (CLAUDE.md, Privacy), and the dashboard's and lists' state
REFUSED_NAMES = {"settings.toml", "equipment.md", "card.toml", "card.pdf", "insurance.pdf", "keywords.toml",
                 "state.json", "view.json", "proposals.json", "recall-matches.json", "front.html", "dashboard.html",
                 "conditions-settings.json", "map-conditions.json", "laptop-location", "usda-key.txt",
                 "upcdatabase-key.txt", "shutoffs.md", "generator.md", "battery-backup.md"}
REFUSED_WORDS = ("household private", "essential documents", "prepareme backup", "household pages")


SAMPLE_FOLDER = "Sample"  # the iPhone and iPad app's folder for the sample (app/Kiwix/project.yml)
SAMPLE_NAMES = {"sample-library.zim", "sample-street-map.pmtiles", "sample-inventory.json"}


def approved_sample(path) -> set:
    """(SHA-256, name) for each line of the approved sample list that isn't blank or a # comment."""
    if not path:
        return set()
    return {(parts[0].lower(), parts[1]) for line in Path(path).read_text().splitlines()
            if line.strip() and not line.lstrip().startswith("#") and len(parts := line.split()) == 2}


def is_approved_sample(app: Path, rel: Path, approved) -> bool:
    return (rel.parent == Path(SAMPLE_FOLDER) and rel.name in SAMPLE_NAMES
            and (hashlib.sha256((app / rel).read_bytes()).hexdigest(), rel.name) in approved)


def refused(rel: Path) -> str | None:
    name = rel.name.lower()
    if rel.suffix.lower() in REFUSED_SUFFIXES:
        return "a library or document file"
    if name in REFUSED_NAMES or (name.startswith("house-") and name.endswith(".md")):
        return "a household file"
    if any(word in rel.as_posix().lower() for word in REFUSED_WORDS):
        return "a household folder's name"
    return None


def text_of(path: Path) -> str | None:
    """A file's text to check: text as it is, a property list (binary ones too) as XML; None for other binaries."""
    data = path.read_bytes()
    if data.startswith(b"bplist"):
        try:
            return plistlib.dumps(plistlib.loads(data)).decode("utf-8", "replace")
        except Exception:  # a damaged one is checked as bytes would be: not text
            return None
    if not is_text(path):
        return None
    return data.decode("utf-8", "replace")


STORE_ID = "com.bigmike382.prepareme"  # decision 12: the app's ID stays the same
STORE_LOWEST = (4, 0)  # above every TestFlight and cable build's 3.17.1
DEMO_KEY = "DEMO_KEY"  # app/Kiwix/project.yml's PREPAREME_USDA_KEY
ENGLISH = {"en.lproj", "Base.lproj"}


def version_tuple(text) -> tuple:
    try:
        return tuple(int(part) for part in str(text).split("."))
    except ValueError:
        return ()


def store_problems(app: Path) -> list:
    """What makes this app not the store build (decisions 10 and 12, and no owner keys), in fixed words."""
    try:
        info = plistlib.loads((app / "Info.plist").read_bytes())
    except Exception:
        return ["Info.plist: can't be read"]
    found = []
    if info.get("PrepareMeChannel") != "appstore":
        found.append("Info.plist: not stamped as the store build (PrepareMeChannel)")
    if info.get("PrepareMeUSDAKey") != DEMO_KEY:
        found.append("Info.plist: PrepareMeUSDAKey isn't the project's demo key (an owner's key never goes in)")
    if info.get("PrepareMeUPCDBKey") != "":
        found.append("Info.plist: PrepareMeUPCDBKey isn't empty (an owner's key never goes in)")
    if info.get("CFBundleIdentifier") != STORE_ID:
        found.append(f"Info.plist: the app's ID isn't {STORE_ID}")
    if version_tuple(info.get("CFBundleShortVersionString")) < STORE_LOWEST:
        found.append("Info.plist: the version is below 4.0")
    others = sorted(p.name for p in app.iterdir() if p.suffix == ".lproj" and p.name not in ENGLISH)
    if others:
        found.append(f"{len(others)} language{'' if len(others) == 1 else 's'} besides English ({', '.join(others[:5])}{', …' if len(others) > 5 else ''})")
    if [lang for lang in info.get("CFBundleLocalizations") or [] if lang not in ("en", "Base")]:
        found.append("Info.plist: CFBundleLocalizations names languages besides English")
    missing = sorted(name for name in SAMPLE_NAMES if not (app / SAMPLE_FOLDER / name).is_file())
    if missing:
        found.append(f"the sample isn't all there ({', '.join(missing)} missing)")
    return found


def cleared_list(path) -> set:
    """The fingerprints in a cleared list: the first word of each line that isn't blank or a # comment."""
    if not path:
        return set()
    return {line.split()[0].lower() for line in Path(path).read_text().splitlines()
            if line.strip() and not line.lstrip().startswith("#")}


def check(app: Path, listing=None, cleared=frozenset(), sample=frozenset(), store=False) -> int:
    files = sorted(p for p in app.rglob("*") if p.is_file() and not p.is_symlink())
    lines, hits, read, skipped = [], 0, 0, 0
    if store:
        for problem in store_problems(app):
            hits += 1
            print(f"{problem}; not the store build")
    for path in files:
        rel = path.relative_to(app)
        lines.append(f"{path.stat().st_size}\t{rel.as_posix()}")
        why = refused(rel)
        # the Sample folder holds only the approved sample, and a sample file's name is allowed nowhere else
        sample_like = rel.parts[0] == SAMPLE_FOLDER or rel.name.lower() in SAMPLE_NAMES
        if (why or sample_like) and is_approved_sample(app, rel, sample):
            why = None
        elif sample_like and not why:
            why = "not the sample the owner read"
        if why:
            hits += 1
            print(f"{shown(rel)}: {why}; it never goes to Apple")
        if scan_name(rel):
            hits += 1
            print(f"{shown(rel)}: its name holds an ID number")
        text = text_of(path)
        if text is None:
            continue
        if cleared and hashlib.sha256(path.read_bytes()).hexdigest() in cleared:
            skipped += 1
            continue
        read += 1
        for hit in scan_text(text):
            hits += 1
            print(HIT_LINE.format(file=shown(rel), where=f"line {hit.line}", kind=a_kind(hit.kind)))
    if listing:
        Path(listing).write_text("\n".join(lines) + "\n")
    print(f"{len(files)} files in the app, {read} text files read, {skipped} cleared files skipped, {hits} problems")
    return 1 if hits or not files else 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("app", type=Path)
    parser.add_argument("--listing")
    parser.add_argument("--cleared")
    parser.add_argument("--sample-approved")
    parser.add_argument("--store", action="store_true")
    args = parser.parse_args(argv)
    if not (args.app / "Info.plist").is_file():
        print(f"{args.app} isn't a built app (no Info.plist)", file=sys.stderr)
        return 2
    return check(args.app, args.listing, cleared_list(args.cleared), approved_sample(args.sample_approved), args.store)


if __name__ == "__main__":
    sys.exit(main())
