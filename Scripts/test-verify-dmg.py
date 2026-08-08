#!/usr/bin/env python3
"""Prove verify-dmg.py's background-alias check catches a stale alias.

A DMG's window layout — icon positions, background image — lives entirely in
a .DS_Store, and Finder resolves the background through an alias: a record of
*which volume* the file lives on plus a path on that volume, not just a bare
filename. verify-dmg.py used to compare only the alias's filename against the
volume's contents, so a stale alias recorded against some other volume — same
background.tiff, wrong disk — passed the check while Finder quietly fell back
to a white background. See Scripts/verify-dmg.py's background-alias block for
the fix: it now checks the alias's recorded volume name against the volume
actually mounted, and resolves the alias's target path instead of guessing at
one from the filename alone.

This script builds one small throwaway DMG with dmgbuild — the same settings
and generated background make-dmg.sh uses, so there is no second copy of the
layout to drift out of step with the real one — then:

  1. Runs verify-dmg.py against it untouched. Expected: pass.
  2. Rewrites the background alias so it names a different volume while
     leaving everything else, including the target file, untouched. Expected:
     verify-dmg.py fails, specifically on the volume-name check.

A disk image dmgbuild just built is read-only (UDZO), so step 2 needs a
writable copy — `hdiutil convert -format UDRW` makes one without changing
anything dmgbuild wrote.

Requires the same throwaway venv make-dmg.sh does:
    python3 -m venv .dmg-venv
    ./.dmg-venv/bin/pip install --require-hashes -r Scripts/dmg-requirements.txt
    PATH="$PWD/.dmg-venv/bin:$PATH" Scripts/test-verify-dmg.py

Exits 0 if both the positive and negative checks behaved as designed.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile

try:
    import mac_alias
    from ds_store import DSStore
except ImportError:
    sys.exit(
        "test-verify-dmg.py needs the ds_store and mac_alias modules.\n"
        "Install them with:  pip install --require-hashes -r Scripts/dmg-requirements.txt"
    )

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
VERIFY = os.path.join(SCRIPT_DIR, "verify-dmg.py")
SETTINGS = os.path.join(SCRIPT_DIR, "dmg-settings.py")
RENDERER = os.path.join(SCRIPT_DIR, "render-dmg-background.swift")
GEOMETRY = os.path.join(SCRIPT_DIR, "dmg-geometry.json")
APP_NAME = "Fixture.app"


def run_verify(mount_point: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, VERIFY, mount_point, "--settings", SETTINGS, "--app-name", APP_NAME],
        capture_output=True,
        text=True,
    )


def sh(*args: str) -> None:
    subprocess.run(args, check=True, capture_output=True, text=True)


def main() -> int:
    work = tempfile.mkdtemp(prefix="verify-dmg-test-")
    mount_point = os.path.join(work, "mnt")
    attached = False
    try:
        app_path = os.path.join(work, APP_NAME)
        os.makedirs(app_path)  # a stand-in bundle — verify-dmg.py just checks isdir

        bg_dir = os.path.join(work, "bg")
        print("== rendering the real background art ==")
        sh("swift", RENDERER, bg_dir)
        tiff = os.path.join(work, "background.tiff")
        sh(
            "tiffutil",
            "-cathidpicheck",
            os.path.join(bg_dir, "background.png"),
            os.path.join(bg_dir, "background@2x.png"),
            "-out",
            tiff,
        )

        ro_dmg = os.path.join(work, "Fixture.dmg")
        print("== building a throwaway DMG from the real settings ==")
        sh(
            "dmgbuild",
            "-s",
            SETTINGS,
            "-D",
            f"app={app_path}",
            "-D",
            f"background={tiff}",
            "-D",
            f"geometry={GEOMETRY}",
            "Fixture",
            ro_dmg,
        )

        # dmgbuild's output is UDZO (read-only); a writable copy is needed to
        # corrupt the alias in step 2 without rebuilding anything.
        rw_dmg = os.path.join(work, "Fixture-rw.dmg")
        sh("hdiutil", "convert", ro_dmg, "-format", "UDRW", "-o", rw_dmg)

        os.makedirs(mount_point)
        sh("hdiutil", "attach", rw_dmg, "-nobrowse", "-noautoopen", "-mountpoint", mount_point)
        attached = True

        print("\n== positive control: verify-dmg.py against an untouched image ==")
        good = run_verify(mount_point)
        print(good.stdout)
        if good.returncode != 0:
            print(good.stderr, file=sys.stderr)
            sys.exit(f"expected the untouched image to pass; exit code {good.returncode}")

        print("== corrupting the background alias's recorded volume ==")
        ds_store_path = os.path.join(mount_point, ".DS_Store")
        with DSStore.open(ds_store_path, "r+") as store:
            icvp = store["."]["icvp"]
            alias = mac_alias.Alias.from_bytes(bytes(icvp["backgroundImageAlias"]))
            real_target = os.path.join(mount_point, alias.target.posix_path.lstrip("/"))
            if not os.path.isfile(real_target):
                sys.exit("background file vanished before we could break its alias")

            # Same filename, same target path — a different volume. This is
            # exactly the case a basename-only check can't tell from the real
            # thing, and the case Finder resolves by volume identity and
            # therefore fails on.
            alias.volume.name = "SomeOtherVolume"
            icvp["backgroundImageAlias"] = alias.to_bytes()
            store["."]["icvp"] = icvp

        print("\n== negative control: verify-dmg.py against the corrupted image ==")
        bad = run_verify(mount_point)
        print(bad.stdout)
        if bad.returncode == 0:
            sys.exit("expected the corrupted alias to fail verification, but it passed")
        if "background alias volume" not in bad.stdout:
            sys.exit(f"failed, but not for the volume-name reason under test:\n{bad.stdout}")

        print("Negative control failed as designed: a stale-volume alias is caught.")
        return 0
    finally:
        if attached:
            subprocess.run(["hdiutil", "detach", mount_point, "-force"], capture_output=True)
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
