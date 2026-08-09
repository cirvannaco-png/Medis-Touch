#!/usr/bin/env python3
"""Static structural validation for the MQL5 tree under EA/.

MetaEditor (the only real MQL5 compiler) is Windows-only and unavailable on
GitHub's Linux runners, so CI cannot type-check this code. What it CAN do is
catch the failure modes that actually broke this repository before:

  1. an ``#include`` pointing at a header that is not in the repo at all
     (the EA referenced Decision/DecisionEngine.mqh for a while when no such
     file existed - MetaEditor only tells you at F7 time, on a machine you
     may not be near),
  2. a header committed empty, which compiles "fine" as an include and then
     fails with hundreds of undeclared-identifier errors elsewhere,
  3. case-only path mismatches, which work on a Windows terminal and break
     nowhere else - so they get committed and stay invisible,
  4. an unbalanced ``#ifndef`` / ``#define`` / ``#endif`` include guard, the
     usual cause of "class already defined" in a multi-include tree,
  5. compiled binaries (*.ex5/*.ex4) committed by accident.

Exit code 0 = clean, 1 = at least one error. Warnings never fail the build.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

INCLUDE_RE = re.compile(r'^\s*#include\s+"([^"]+)"', re.MULTILINE)
SOURCE_SUFFIXES = (".mq5", ".mqh")
BINARY_SUFFIXES = (".ex5", ".ex4")


def read(path: Path) -> str:
    # MetaEditor writes UTF-8 with BOM by default; some files are cp1252.
    for encoding in ("utf-8-sig", "utf-8", "cp1252"):
        try:
            return path.read_text(encoding=encoding)
        except UnicodeDecodeError:
            continue
    return path.read_text(encoding="utf-8", errors="replace")


def check_includes(root: Path, sources: list[Path], errors: list[str]) -> int:
    """Resolve every #include relative to the including file, like MQL5 does."""
    checked = 0
    for src in sources:
        for target in INCLUDE_RE.findall(read(src)):
            checked += 1
            resolved = (src.parent / target).resolve()
            rel_src = src.relative_to(root)
            if not resolved.exists():
                errors.append(f'{rel_src}: #include "{target}" does not exist')
                continue
            # Case-only mismatch: exists() is case-insensitive on macOS/Windows
            # checkouts, so compare against the real on-disk name explicitly.
            real = resolved.parent / resolved.name
            siblings = {p.name for p in resolved.parent.iterdir()}
            if real.name not in siblings:
                errors.append(f'{rel_src}: #include "{target}" differs in case from the file on disk')
    return checked


def check_non_empty(root: Path, sources: list[Path], errors: list[str]) -> None:
    for src in sources:
        if src.stat().st_size == 0 or not read(src).strip():
            errors.append(f"{src.relative_to(root)}: file is empty")


def check_guards(root: Path, sources: list[Path], warnings: list[str], errors: list[str]) -> None:
    for src in sources:
        if src.suffix != ".mqh":
            continue
        text = read(src)
        ifndef = len(re.findall(r"^\s*#ifndef\b", text, re.MULTILINE))
        ifdef = len(re.findall(r"^\s*#ifdef\b", text, re.MULTILINE))
        endif = len(re.findall(r"^\s*#endif\b", text, re.MULTILINE))
        if ifndef + ifdef != endif:
            errors.append(
                f"{src.relative_to(root)}: unbalanced preprocessor guards "
                f"(#ifndef/#ifdef={ifndef + ifdef}, #endif={endif})"
            )
        elif ifndef == 0:
            warnings.append(
                f"{src.relative_to(root)}: no #ifndef include guard - "
                "including it twice will redefine its symbols"
            )


def check_no_binaries(root: Path, errors: list[str]) -> None:
    for path in sorted(root.rglob("*")):
        if path.suffix.lower() in BINARY_SUFFIXES:
            errors.append(
                f"{path.relative_to(root)}: compiled binary committed - "
                "it is covered by .gitignore, remove it with `git rm --cached`"
            )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", default="EA", help="directory containing the MQL5 sources")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    if not root.is_dir():
        print(f"error: {args.root} is not a directory", file=sys.stderr)
        return 1

    sources = sorted(p for p in root.rglob("*") if p.suffix in SOURCE_SUFFIXES)
    if not sources:
        print(f"error: no .mq5/.mqh sources found under {args.root}", file=sys.stderr)
        return 1

    errors: list[str] = []
    warnings: list[str] = []

    check_non_empty(root, sources, errors)
    include_count = check_includes(root, sources, errors)
    check_guards(root, sources, warnings, errors)
    check_no_binaries(root, errors)

    entry_points = [p for p in sources if p.suffix == ".mq5"]
    print(f"MQL5 validation: {len(sources)} source file(s), {len(entry_points)} entry point(s), "
          f"{include_count} #include(s) resolved")
    for entry in entry_points:
        print(f"  entry point: {entry.relative_to(root)}")

    for warning in warnings:
        print(f"warning: {warning}")
    for error in errors:
        print(f"error: {error}", file=sys.stderr)

    if errors:
        print(f"\n{len(errors)} problem(s) found.", file=sys.stderr)
        return 1
    print("No problems found.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
