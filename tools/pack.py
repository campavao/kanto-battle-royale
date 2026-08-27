#!/usr/bin/env python3
"""Build the release zip.

Two rules the mod index enforces that a hand-rolled zip kept getting wrong:

  1. Files sit at the ARCHIVE ROOT, not under a battle_royale/ folder.
     The engine accepts either -- LauncherMods.locateRoot returns "" for a
     root manifest and "<dir>" for a single wrapping folder, and the install
     path is mods/<manifest.id> either way -- but the index's PR checklist
     asks for root, so root is what we ship.

  2. tests/ does not ship. It is 39% of the download, nothing at runtime
     references it, and modkit's MK301 gate fails on any distributed file
     containing the literal "data/generated/" -- which br_test.lua does, in
     pcall'd dofile calls that skip when the cache is absent. No ROM content
     is involved; the file simply has no business in a player's download.

Allowlist, not denylist: a new repo-only directory should have to be added
here deliberately rather than ship by accident.

    python tools/pack.py            # writes battle_royale-v<version>.zip
    python tools/pack.py --check    # verify only, write nothing
"""

import json
import pathlib
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Everything a player needs, and nothing else.
SHIP_FILES = ["manifest.json", "main.lua", "LICENSE", "README.md", "COMPATIBILITY.md"]
SHIP_DIRS = ["lib", "relay", "assets"]

# modkit MK301: nothing distributed may point into the player's ROM-derived
# cache. Checked here so a release cannot reintroduce what MK301 catches only
# once someone thinks to run it.
FORBIDDEN = ("data/generated/", "assets/generated/")

SKIP_NAMES = {".DS_Store", "Thumbs.db"}


def collect():
    picked, missing = [], []

    for name in SHIP_FILES:
        path = ROOT / name
        if path.is_file():
            picked.append((path, name))
        else:
            missing.append(name)

    for name in SHIP_DIRS:
        base = ROOT / name
        if not base.is_dir():
            missing.append(name + "/")
            continue
        for path in sorted(base.rglob("*")):
            if path.is_file() and path.name not in SKIP_NAMES:
                picked.append((path, path.relative_to(ROOT).as_posix()))

    return picked, missing


def audit(picked):
    problems = []
    for path, arcname in picked:
        if arcname.startswith("tests/") or "/tests/" in arcname:
            problems.append(f"{arcname}: tests must not ship")
        if path.suffix in (".lua", ".js", ".json", ".md"):
            body = path.read_text(encoding="utf-8", errors="replace")
            for bad in FORBIDDEN:
                if bad in body:
                    problems.append(f"{arcname}: contains {bad!r} (modkit MK301)")
    return problems


def main():
    check_only = "--check" in sys.argv

    manifest = json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))
    version, mod_id = manifest["version"], manifest["id"]

    picked, missing = collect()
    if missing:
        print("missing from the tree: " + ", ".join(missing), file=sys.stderr)
        return 1

    problems = audit(picked)
    if problems:
        print("refusing to pack:", file=sys.stderr)
        for p in problems:
            print("  " + p, file=sys.stderr)
        return 1

    out = ROOT / f"{mod_id}-v{version}.zip"
    if check_only:
        print(f"ok: {len(picked)} files would ship as {out.name}")
        return 0

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for path, arcname in picked:
            z.write(path, arcname)

    with zipfile.ZipFile(out) as z:
        names = z.namelist()
        if "manifest.json" not in names:
            print("manifest.json is not at the archive root", file=sys.stderr)
            return 1
        size = sum(i.compress_size for i in z.infolist())

    print(f"{out.name}: {len(names)} files, {size / 1024:.0f}KB compressed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
