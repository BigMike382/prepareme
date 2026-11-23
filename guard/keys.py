"""Key and token shapes that never go in the library or git (library upgrades, Task 4). Standard library only."""

import re

from guard.ids import Hit

_SHAPES = (
    ("Anthropic key or token", re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}")),
    ("private key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("GitHub token", re.compile(r"gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,}")),
    ("AWS access key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("Google API key", re.compile(r"AIza[0-9A-Za-z_-]{35}")),
    ("Slack token", re.compile(r"xox[abposr]-[A-Za-z0-9-]{10,}")),
)
_WRITTEN = re.compile(r"(?<![A-Za-z0-9])(?:api_key|apikey|secret|token|password|passwd)\s*[=:]\s*[\"']?"
                      r"(?P<v>[A-Za-z0-9_\-+/=.]{16,})", re.I)


def find_keys(text: str) -> list[Hit]:
    """Every key shape in `text`, by line and kind. Never holds the key itself."""
    found = [(m.start(), kind) for kind, pattern in _SHAPES for m in pattern.finditer(text)]
    for m in _WRITTEN.finditer(text):
        value = m.group("v")
        if any(c.isalpha() for c in value) and any(c.isdigit() for c in value):
            found.append((m.start(), "secret written into the file"))
    return sorted(Hit(text.count("\n", 0, offset) + 1, kind) for offset, kind in found)
