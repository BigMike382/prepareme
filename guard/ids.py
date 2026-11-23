"""ID-number shapes that never go in the library or git (library upgrades, Task 4).

The scope says codes, account and ID numbers are never stored anywhere. This
finds the shapes it can tell apart from ordinary numbers: Social Security,
payment card (Luhn and an issuer), bank routing (the ABA checksum), and,
right after their label, passport, driver's license, and account or code
numbers (owner, gate 4A). A hit names the line and the kind, never the value.
Standard library only.
"""

import re
from dataclasses import dataclass

SSN, CARD, ROUTING = "Social Security number", "payment card number", "bank routing number"
PASSPORT, LICENSE, LABELED = "passport number", "driver's license number", "labeled account or code number"
KINDS = (SSN, CARD, ROUTING, PASSPORT, LICENSE, LABELED)


@dataclass(frozen=True, order=True)
class Hit:
    line: int
    kind: str  # never the matched text


_SPACES = dict.fromkeys(map(ord, "   "), " ")
_DASHES = dict.fromkeys([*range(0x2010, 0x2016), 0x2212], "-")
_QUOTES = dict.fromkeys(map(ord, "’‘ʼ"), "'")


def normalize(text: str) -> str:
    """Curly apostrophes, odd spaces and dashes made plain; the line count is unchanged."""
    return text.translate({**_SPACES, **_DASHES, **_QUOTES})


_BEFORE, _AFTER = r"(?<![\w./-])", r"(?![\w/-]|[.,]\d)"
_LINKS = re.compile(r"https?://\S+|www\.\S+|doi:\s*\S+", re.I)
_SSN = re.compile(_BEFORE + r"(\d{3})([- ])(\d{2})\2(\d{4})" + _AFTER)
_CARD = re.compile(_BEFORE + r"(?:\d{13,19}|\d{4}([ -])\d{4}\1\d{4}\1\d{4}(?:\1\d{1,3})?|\d{4}([ -])\d{6}\2\d{4,5})" + _AFTER)
_NINE = re.compile(_BEFORE + r"\d{9}" + _AFTER)
# Quantities: a number followed by one of these is an amount, not an ID. The labeled rules use a shorter list:
# a single letter or "in" after a real account or code ("Gate code", four digits, "a new one") must not hide it.
_UNITS = (r"%|mg|g|kg|ml|l|oz|lbs?|gal|gallons|w|watts?|kw|mah|v|volts?|a|amps?|ft|feet|in|inches|mi|miles?"
          r"|m|km|cm|mm|meters?|metres?|yds?|yards?|qts?|quarts?|pints?|cups?|tbsp|tsp|ounces|pounds|calories|kcal"
          r"|psi|°f|°c|days?|hours?|minutes?|years?|people|visits|deaths|cases")
_UNIT_AFTER = re.compile(r"\s*(?:" + _UNITS + r")(?![a-z])", re.I)
_LABELED_UNITS = re.compile(
    r"\s*(?:%|mg|kg|ml|oz|lbs?|gal|gallons|watts?|kw|mah|volts?|amps?|ft|feet|inches|miles?|meters?|metres?"
    r"|°f|°c|days?|hours?|minutes?|years?|people|visits|deaths|cases)(?![a-z])", re.I)
_PHONE = re.compile(r"(?:1[ .-])?\(?\d{3}\)?[ .-]\d{3}[ .-]\d{4}")
_YEARS = re.compile(r"(?:19|20)\d\d-(?:19|20)\d\d")
_SUFFIX = r"(?:\s*(?i:number|no\.|num|#|id)(?![a-z]))?"
_SEP = r"\s*[:#=-]?\s*"  # codes: a missing colon is the likeliest way a real code gets typed
# Accounts and policies need a separator (owner, 2026-10-04): "Policy 2020-2025 Strategic Plan" isn't one.
_ACCOUNT_SEP = r"\s*(?:(?i:no\.|#)\s*[:=-]?|(?:(?i:number|num|id)(?![a-z])\s*)?[:=-])\s*"


def _labeled(labels: str, value: str, flags=re.I, sep=_SUFFIX + _SEP) -> re.Pattern:
    return re.compile(r"(?<![\w])(?:" + labels + r")" + sep + r"(?P<v>" + value + r")" + _AFTER, flags)


_SSN_LABELED = _labeled(r"ssn|ss#|social\s+security", r"\d{9}|\d{3}-\d{2}-\d{4}")
_PASSPORT = _labeled(r"passport", r"[A-Za-z]\d{8}|\d{9}")
_LICENSE = _labeled(r"driver'?s?\s+license|(?-i:DLN?)", r"[A-Za-z]?\d{5,12}")  # "mg/dL" isn't a license
_VALUE = r"[A-Za-z]{0,4}\d[\d -]*\d"
# A code is 4-8 digits, or a combination in short groups ("44-71-12"); not an Army publication's
# "PIN: 104237-000"-shaped number.
_CODE_VALUE = r"\d{4,8}|\d{1,3}(?:[- ]\d{1,3}){1,3}"
_ACCOUNT = _labeled(r"account|acct|policy|member\s+id|group\s+(?:number|no\.|#)", _VALUE, sep=_ACCOUNT_SEP)
_CODE = _labeled(r"passcode|(?:lock|safe)\s+combination|combination(?=\s*:)|(?:gate|door|lock|alarm|garage|safe)\s+code",
                 _CODE_VALUE)
# A parcel's PIN is often 10 digits, written whole or grouped 4-2-4 or 3-3-4 (owner, 2026-10-07, after phase M1
# found them unflagged). Grouped shapes come first so a whole run of digits isn't tried in pieces. The Army
# publication's "PIN: 104237-000" shape (6-3) still isn't one.
# Dots group it too (four, two and four digits, or three, three and four), and the word "is" may sit between the
# label and the number (owner, 2026-10-07, after the phase M2 review asked about dotted PINs).
_PIN_VALUE = (r"\d{4}\.\d{2}\.\d{4}|\d{3}\.\d{3}\.\d{4}|\d{4}[- ]\d{2}[- ]\d{4}|\d{3}[- ]\d{3}[- ]\d{4}"
              r"|\d{4,10}|\d{1,3}(?:[- ]\d{1,3}){1,3}")
_PIN_IS = r"(?:(?<=[\s:#=-])is(?![\w.])\s*[:=]?\s*)?"  # the label, then "is", with or without a colon on either side
_PIN = _labeled(r"PIN", _PIN_VALUE, flags=0, sep=_SUFFIX + _SEP + _PIN_IS)  # capitals only: "pin" is an ordinary word


def _luhn(digits: str) -> bool:
    total = 0
    for i, c in enumerate(reversed(digits)):
        d = int(c) * (2 if i % 2 else 1)
        total += d - 9 if d > 9 else d
    return total % 10 == 0


def _issuer(d: str) -> bool:
    n, two, three, four = len(d), int(d[:2]), int(d[:3]), int(d[:4])
    return ((d[0] == "4" and n in (13, 16, 19)) or ((51 <= two <= 55 or 2221 <= four <= 2720) and n == 16)
            or (two in (34, 37) and n == 15) or ((d.startswith("6011") or 644 <= three <= 649 or two == 65) and 16 <= n <= 19)
            or ((two == 36 or 300 <= three <= 305) and n == 14) or (3528 <= four <= 3589 and 16 <= n <= 19))


def _routing(d: str) -> bool:
    if len(set(d)) == 1:
        return False
    prefix = int(d[:2])
    if not (prefix <= 12 or 21 <= prefix <= 32 or 61 <= prefix <= 72 or prefix == 80):
        return False
    w = [int(c) for c in d]
    return (3 * (w[0] + w[3] + w[6]) + 7 * (w[1] + w[4] + w[7]) + (w[2] + w[5] + w[8])) % 10 == 0


def _plain_value(text: str, m: re.Match, min_digits: int, phone_ok: bool = True) -> bool:
    """A labeled value that is really an ID or code: not money, a grouped or decimal number, a quantity, or a phone
    (unless `phone_ok` is False: a PIN written 3-3-4 is still a PIN)."""
    value = m.group("v")
    start = m.start("v")
    if sum(c.isdigit() for c in value) < min_digits or (start and text[start - 1] in "$§"):
        return False
    if (phone_ok and _PHONE.fullmatch(value.strip())) or _YEARS.fullmatch(value.strip()):
        return False
    if value.isdigit() and _LABELED_UNITS.match(text, m.end("v")):
        return False
    return "." in value or not re.match(r"\d{1,3}(,\d{3})+|\d+\.\d", text[start:])  # a dotted value is a PIN's


_NUMBER_NEAR = re.compile(r"\d")
# A ZIP+4 written without its dash, after "zip" or a state's two capitals ("Washington, DC 205001234").
_ZIP_BEFORE = re.compile(r"(?:(?i:\bzip(?:\s*code)?)|\b[A-Z]{2})[\s:,#-]*$")


def _table_row(text: str, m: re.Match, serial: str) -> bool:
    """A space-separated 3-2-4 in a table row of numbers, an amount, or ending in a year, isn't a Social Security
    number; the dashed form is always counted."""
    line_start = text.rfind("\n", 0, m.start()) + 1
    line_end = text.find("\n", m.end())
    before = text[line_start:m.start()].split()
    after = text[m.end():None if line_end < 0 else line_end].split()
    if (before and _NUMBER_NEAR.search(before[-1])) or (after and _NUMBER_NEAR.search(after[0])):
        return True
    return bool(_UNIT_AFTER.match(text, m.end())) or 1900 <= int(serial) <= 2099


def _blank(text: str, spans) -> str:
    chars = list(text)
    for a, b in spans:
        for i in range(a, b):
            if chars[i] != "\n":
                chars[i] = " "
    return "".join(chars)


def find_id_numbers(text: str) -> list[Hit]:
    """Every ID-number shape in `text`, by line and kind. Never holds the number itself."""
    text = normalize(text)
    found = []  # (offset, kind)

    def labeled_account(chunk: str, offset: int):
        for pattern, digits, phone_ok in ((_ACCOUNT, 5, True), (_CODE, 4, True), (_PIN, 4, False)):
            for m in pattern.finditer(chunk):
                if _plain_value(chunk, m, digits, phone_ok):
                    found.append((offset + m.start(), LABELED))

    for link in _LINKS.finditer(text):  # ?acct=… in a link still counts
        query = link.group(0).partition("?")[2]
        if query:
            base = link.start() + link.group(0).index("?") + 1
            pos = 0
            for part in re.split(r"([&;])", query):
                if part not in ("&", ";"):
                    labeled_account(part, base + pos)
                pos += len(part)
    text = _blank(text, [m.span() for m in _LINKS.finditer(text)])

    ssn_spans = set()
    for m in _SSN.finditer(text):
        area, group, serial = m.group(1), m.group(3), m.group(4)
        if area in ("000", "666") or area[0] == "9" or group == "00" or serial == "0000":
            continue
        if m.group(2) == " " and _table_row(text, m, serial):
            continue
        found.append((m.start(), SSN))
        ssn_spans.add(m.span())
    for m in _SSN_LABELED.finditer(text):
        if not any(a <= m.start("v") < b for a, b in ssn_spans):
            found.append((m.start(), SSN))
        ssn_spans.add(m.span("v"))
    for m in _CARD.finditer(text):
        digits = re.sub(r"\D", "", m.group(0))
        if _luhn(digits) and _issuer(digits):
            found.append((m.start(), CARD))
    for m in _NINE.finditer(text):
        if m.span() not in ssn_spans and _routing(m.group(0)) and not _ZIP_BEFORE.search(text[max(0, m.start() - 24):m.start()]):
            found.append((m.start(), ROUTING))
    for pattern, kind in ((_PASSPORT, PASSPORT), (_LICENSE, LICENSE)):
        found += [(m.start(), kind) for m in pattern.finditer(text)]
    labeled_account(text, 0)

    return sorted(Hit(text.count("\n", 0, offset) + 1, kind) for offset, kind in found)
