#!/usr/bin/env python3
"""Lists user-visible string keys used by the Swift sources (English text is the key).

Usage: Scripts/extract-strings.py            print keys, one per line
       Scripts/extract-strings.py --check    fail if a key is missing from a Localizable.strings file
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [ROOT / "Sources/Steppe", ROOT / "Sources/SteppeCore"]

SWIFTUI_CALLS = r'(?:Text|Button|Label|Section|Picker|Toggle|LabeledContent|Link|Chip\(symbol:\s*"[^"]*",\s*text:)'
PATTERNS = [
    re.compile(r'\b(?:Text|Button|Label|Section|Picker|Toggle|LabeledContent|Link)\(\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'\.alert\(\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'String\(localized:\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'\bL\(\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'\bbullet\(\s*"[^"]*",\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'title:\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'text:\s*"((?:[^"\\]|\\.)*)"(?=\))'),
    re.compile(r'\.(?:checkMac|engine|frameworks|prefix|steamClient|signIn|game):\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'return\s+"((?:[^"\\]|\\.)*)"'),
]
SKIP = {"", "Steppe", "dev", "main", "Cossacks 3", "playing", "ready", "setup", "unsupported", "welcome", "%@ GB", "%@/s", "%@ free"}
EXTRA = {"%@/s", "%@ free"}  # interpolations the extractor cannot parse


def normalize(raw: str) -> str:
    # Swift interpolation -> printf placeholder (SwiftUI uses %@ / %lld; we only use %@ for strings).
    return re.sub(r'\\\((?:[^()]|\([^()]*\))*\)', '%@', raw).replace('\\"', '"').replace('\\n', '\n')


def keys() -> set[str]:
    found: set[str] = set()
    for base in SOURCES:
        for path in base.rglob("*.swift"):
            text = path.read_text()
            for pattern in PATTERNS:
                for match in pattern.finditer(text):
                    key = normalize(match.group(1))
                    if key in SKIP or key.startswith(("com.", "http", "square.", "arrow.", "person.", "lock.", "shippingbox", "cpu", "memory", "display", "sparkles", "externaldrive", "hand.", "checkmark", "exclamation", "gearshape", "info.", "play.")):
                        continue
                    found.add(key)
    return found | EXTRA


def parse_strings(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for m in re.finditer(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', path.read_text(), re.M):
        result[m.group(1).replace('\\"', '"').replace('\\n', '\n')] = m.group(2)
    return result


if __name__ == "__main__":
    used = keys()
    if "--check" not in sys.argv:
        for key in sorted(used):
            print(key)
        sys.exit(0)
    status = 0
    for lang in ("en", "tr"):
        table = parse_strings(ROOT / f"Resources/{lang}.lproj/Localizable.strings")
        missing = sorted(k for k in used if k not in table)
        extra = sorted(k for k in table if k not in used)
        for k in missing:
            print(f"[{lang}] missing: {k!r}")
            status = 1
        for k in extra:
            print(f"[{lang}] unused:  {k!r}")
    sys.exit(status)
