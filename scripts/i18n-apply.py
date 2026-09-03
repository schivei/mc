#!/usr/bin/env python3
# i18n-apply.py — applies scripts/i18n-map.tsv (PT -> EN messages) and
# scripts/i18n-idents.tsv (PT -> EN identifiers) to the repository.
#
# Message pass: exact substring replacement, longest PT key first (so a full
# phrase is consumed before any of its shorter sub-phrases can match).
# Identifier pass: whole-word (\b...\b) replacement, applied after the
# message pass, longest key first for the same reason.
#
# Idempotent: once the PT text is gone, re-running is a no-op.
#
# Usage: scripts/i18n-apply.py [--messages-only | --idents-only]

import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def target_files():
    pats = [
        "stage0/*.c",
        "stage0/mc.h",
        "src/*.mc",
        "lib/*.mc",
        "tests/**/*.mc",
        "examples/api/**/*.mc",
        "scripts/*.sh",
        "examples/api/*.sh",
        "examples/api/tests/*.sh",
        "Makefile",
        "examples/api/Makefile",
    ]
    files = []
    for p in pats:
        files += glob.glob(os.path.join(ROOT, p), recursive=True)
    # de-dup, keep only real files, skip this script itself and the TSVs
    seen = []
    for f in sorted(set(files)):
        if os.path.isfile(f):
            seen.append(f)
    return seen


def load_tsv(path):
    pairs = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            pt, en = line.split("\t", 1)
            pairs.append((pt, en))
    # longest PT key first, so a full phrase is replaced before any of its
    # substrings could partially match.
    pairs.sort(key=lambda kv: -len(kv[0]))
    return pairs


def apply_messages(files, pairs):
    changed = 0
    for f in files:
        with open(f, encoding="utf-8") as fh:
            text = fh.read()
        orig = text
        for pt, en in pairs:
            if pt in text:
                text = text.replace(pt, en)
        if text != orig:
            with open(f, "w", encoding="utf-8") as fh:
                fh.write(text)
            changed += 1
    return changed


def apply_idents(files, pairs):
    changed = 0
    for f in files:
        with open(f, encoding="utf-8") as fh:
            text = fh.read()
        orig = text
        for pt, en in pairs:
            pattern = r"\b" + re.escape(pt) + r"\b"
            if re.search(pattern, text):
                text = re.sub(pattern, en, text)
        if text != orig:
            with open(f, "w", encoding="utf-8") as fh:
                fh.write(text)
            changed += 1
    return changed


def main():
    args = sys.argv[1:]
    do_messages = "--idents-only" not in args
    do_idents = "--messages-only" not in args

    files = target_files()

    if do_messages:
        map_path = os.path.join(ROOT, "scripts", "i18n-map.tsv")
        if os.path.exists(map_path):
            pairs = load_tsv(map_path)
            n = apply_messages(files, pairs)
            print(f"messages: {len(pairs)} entries, {n} files changed")
        else:
            print(f"messages: {map_path} not found, skipped")

    if do_idents:
        idents_path = os.path.join(ROOT, "scripts", "i18n-idents.tsv")
        if os.path.exists(idents_path):
            pairs = load_tsv(idents_path)
            n = apply_idents(files, pairs)
            print(f"identifiers: {len(pairs)} entries, {n} files changed")
        else:
            print(f"identifiers: {idents_path} not found, skipped")


if __name__ == "__main__":
    main()
