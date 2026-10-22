#!/usr/bin/env python3
"""Zip a folder's contents, keeping file modes (run.sh and love stay executable).
   tools/zipdir.py OUT.zip FOLDER [--game] [--skip PATH,PATH] [--copy]
--game: a .love from a game's source: without version control folders and the
Windows / macOS libraries some repositories carry. --skip: folders or files (relative
to FOLDER) left out, such as a repository's screenshots. --copy: OUT is a folder the
files are copied into, not a zip (a game that reads its own files by path)."""
import os
import shutil
import sys
import zipfile

out, top = sys.argv[1], sys.argv[2]
game = "--game" in sys.argv[3:]
skip = set()
if "--skip" in sys.argv[3:]:
    skip = {p.strip("/") for p in sys.argv[sys.argv.index("--skip") + 1].split(",") if p}
SKIP_DIRS = {".git", ".github", ".vscode", ".idea"}
SKIP_EXT = (".dll", ".dylib", ".exe", ".zip", ".love")

copy = "--copy" in sys.argv[3:]


def files():
    for base, dirs, names in os.walk(top):
        rel = os.path.relpath(base, top)
        if game:
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        dirs[:] = [d for d in dirs if os.path.normpath(os.path.join(rel, d)) not in skip]
        dirs.sort()
        for name in sorted(names):
            if game and name.lower().endswith(SKIP_EXT):
                continue
            path = os.path.join(base, name)
            if os.path.normpath(os.path.join(rel, name)) in skip:
                continue
            yield path, os.path.relpath(path, top)


if copy:
    for path, rel in files():
        os.makedirs(os.path.dirname(os.path.join(out, rel)), exist_ok=True)
        shutil.copy2(path, os.path.join(out, rel))
else:
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for path, rel in files():
            info = zipfile.ZipInfo.from_file(path, rel)
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(path, "rb") as f:
                z.writestr(info, f.read())
