"""Choose and read the files to check for ID numbers and keys (library upgrades, Task 4).

Files are chosen by content, not name: anything with no NUL byte near its
start is text and gets read. Office formats can't be read as text, so they
are reported for the owner to save as Markdown or PDF. Standard library only.
"""

import re
from pathlib import Path

from guard.ids import Hit, find_id_numbers
from guard.keys import find_keys

OFFICE_SUFFIXES = {".doc", ".docx", ".pages", ".numbers", ".key", ".xls", ".xlsx", ".ppt", ".pptx", ".odt", ".ods",
                   ".rtfd", ".zip", ".epub", ".gz", ".tgz", ".7z", ".rar"}  # office files and archives: unreadable
_BOMS = (b"\xff\xfe", b"\xfe\xff")  # UTF-16 (Excel's "Unicode text" export): NULs, but text
HIT_LINE = "{file}: {where}: looks like {kind}"  # kind with its article: see a_kind
OFFICE_LINE = "{file}: can't check this kind of file; save it as Markdown or PDF"
ADVICE = ("ID, card and account numbers, codes and keys never go in the library. If it is one, take it out. If it "
          "isn't, leave the file as it is (a guide the librarian wrote is never edited by hand) and tell a Claude "
          "session the file, line and kind: the check gets fixed, not the page.")


def a_kind(kind: str) -> str:
    return ("an " if kind[0].lower() in "aeiou" else "a ") + kind


def is_text(path: Path) -> bool:
    with open(path, "rb") as fh:
        head = fh.read(8192)
    return head.startswith(_BOMS) or b"\x00" not in head


def is_office(path: Path) -> bool:
    """Any part of the path, since some office formats are folders (a .pages or .numbers bundle)."""
    return any(Path(part).suffix.lower() in OFFICE_SUFFIXES for part in Path(path).parts)


def office_part(path: Path) -> Path:
    """The office file or bundle a path is in."""
    parts = Path(path).parts
    for i, part in enumerate(parts):
        if Path(part).suffix.lower() in OFFICE_SUFFIXES:
            return Path(*parts[: i + 1])
    return Path(path)


def scan_text(text: str) -> list[Hit]:
    return sorted(find_id_numbers(text) + find_keys(text))


def scan_file(path: Path) -> list[Hit]:
    if not is_text(path):
        return []
    data = Path(path).read_bytes()
    encoding = "utf-16" if data.startswith(_BOMS) else "utf-8"
    return scan_text(data.decode(encoding, errors="replace"))


def scan_name(path: Path) -> list[Hit]:
    """ID numbers in a file's name and folders ("Policy #<digits> declarations.pdf", "policy-<digits>.txt").
    Read twice: as written, and with each dash spaced out, so a dash between a label and its number counts."""
    plain = Path(path).as_posix().replace("/", " ").replace("_", " ")
    spaced = re.sub(r"-", " - ", plain)
    found = {(h.kind) for h in find_id_numbers(plain) + find_id_numbers(spaced)}
    return [Hit(1, kind) for kind in sorted(found)]


def shown(path: Path) -> str:
    """How a file is named in any message: a file or folder whose name holds an ID number is described, not named."""
    parts = Path(path).parts
    out = []
    for i, part in enumerate(parts):
        hits = scan_name(Path(part))
        what = "file" if i == len(parts) - 1 else "folder"
        out.append(f"a {what} whose name looks like {a_kind(hits[0].kind)}" if hits else part)
    return "/".join(out)
