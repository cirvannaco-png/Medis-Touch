"""Fast, compiler-independent structural checks for the MQL5 EA tree.

MetaEditor is Windows/terminal-bound, so GitHub Actions cannot be the source of
truth for MQL5 compilation. This validator catches cheap failures that should
not reach MetaEditor: broken relative includes and unbalanced braces.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "EA"
INCLUDE_RE = re.compile(r'#include\s+"([^"]+)"')


def strip_comments_and_strings(text: str) -> str:
    """Replace comments/string contents with spaces while preserving newlines."""
    out: list[str] = []
    i = 0
    state = "code"
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if state == "code":
            if ch == "/" and nxt == "/":
                out.extend("  ")
                i += 2
                state = "line"
                continue
            if ch == "/" and nxt == "*":
                out.extend("  ")
                i += 2
                state = "block"
                continue
            if ch == '"':
                out.append(" ")
                i += 1
                state = "string"
                continue
            out.append(ch)
            i += 1
            continue
        if state == "line":
            out.append("\n" if ch == "\n" else " ")
            i += 1
            if ch == "\n":
                state = "code"
            continue
        if state == "block":
            out.append("\n" if ch == "\n" else " ")
            i += 1
            if ch == "*" and nxt == "/":
                out.append(" ")
                i += 1
                state = "code"
            continue
        out.append("\n" if ch == "\n" else " ")
        i += 1
        if ch == "\\" and i < len(text):
            out.append(" ")
            i += 1
        elif ch == '"':
            state = "code"
    return "".join(out)


def check_file(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    clean = strip_comments_and_strings(text)
    errors: list[str] = []

    depth = 0
    for line_no, line in enumerate(clean.splitlines(), 1):
        for ch in line:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth < 0:
                    errors.append(f"{path.relative_to(ROOT.parent)}:{line_no}: unexpected '}}'")
                    depth = 0
    if depth != 0:
        errors.append(f"{path.relative_to(ROOT.parent)}: unbalanced braces (depth={depth})")

    for match in INCLUDE_RE.finditer(text):
        target = (path.parent / match.group(1)).resolve()
        if not target.is_file():
            errors.append(
                f"{path.relative_to(ROOT.parent)}: missing relative include {match.group(1)!r}"
            )
    return errors


def main() -> int:
    files = sorted(list(ROOT.rglob("*.mqh")) + list(ROOT.rglob("*.mq5")))
    if not files:
        print("No MQL5 sources found")
        return 1
    errors: list[str] = []
    for path in files:
        errors.extend(check_file(path))
    if errors:
        print("MQL5 structural validation failed:")
        print("\n".join(errors))
        return 1
    print(f"MQL5 structural validation passed: {len(files)} source files checked")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
