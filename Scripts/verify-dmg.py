#!/usr/bin/env python3
"""Assert a mounted Cheerio disk image actually has the layout we asked for.

Every cosmetic property of a DMG window lives in a .DS_Store on the volume,
and every way of writing one fails quietly: the icons land in a default grid,
the background reverts to white, and the image still mounts and still works.
Nobody notices until someone downloads it. So the layout is checked rather
than assumed, the same way the release workflow checks a signature instead of
trusting that codesign ran.

Scripts/dmg-settings.py is the single source of truth: this script execs it and
compares the mounted volume against what it declares, so there are no expected
coordinates duplicated here to drift out of step.

Usage:
    verify-dmg.py <mount-point> --settings Scripts/dmg-settings.py \\
        --app-name Cheerio.app

Exits 0 and prints each check, or exits 1 naming the first mismatch.
"""

from __future__ import annotations

import argparse
import os
import sys

try:
    import mac_alias
    from ds_store import DSStore
except ImportError:  # pragma: no cover - a setup error, not a layout error
    sys.exit(
        "verify-dmg.py needs the ds_store and mac_alias modules.\n"
        "Install them with:  pip install --require-hashes -r Scripts/dmg-requirements.txt"
    )

FAILURES: list[str] = []


def check(label: str, actual: object, expected: object) -> None:
    if actual == expected:
        print(f"  ok    {label}: {actual!r}")
    else:
        print(f"  FAIL  {label}: expected {expected!r}, got {actual!r}")
        FAILURES.append(label)


def load_settings(path: str, app_name: str) -> dict:
    """Exec the dmgbuild settings file with a stand-in `defines`.

    dmgbuild hands the file a `defines` dict; the only two keys ours reads are
    paths, and the layout values we compare don't depend on them beyond the app's
    basename. The background path is a placeholder — what the image should be
    called is derived from the volume, not from this.
    """
    namespace: dict = {
        "defines": {"app": app_name, "background": "background.tiff"},
        "__file__": path,
    }
    with open(path, encoding="utf-8") as handle:
        source = handle.read()
    exec(compile(source, path, "exec"), namespace)  # noqa: S102 - our own file
    return namespace


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mount_point", help="where the DMG is attached")
    parser.add_argument(
        "--settings",
        default="Scripts/dmg-settings.py",
        help="the dmgbuild settings file the image was built from",
    )
    parser.add_argument("--app-name", default="Cheerio.app")
    args = parser.parse_args()

    volume = args.mount_point.rstrip("/")
    settings = load_settings(args.settings, args.app_name)

    print(f"Verifying {volume} against {args.settings}")

    # ---- Contents ------------------------------------------------------
    print("contents")
    app_path = os.path.join(volume, args.app_name)
    check(f"{args.app_name} present", os.path.isdir(app_path), True)
    # The whole point of the DMG: a drop target that is the real /Applications,
    # so the copy lands outside the read-only mount and Sparkle can update it.
    link = os.path.join(volume, "Applications")
    check("Applications is a symlink", os.path.islink(link), True)
    if os.path.islink(link):
        check("Applications target", os.readlink(link), "/Applications")
    for name, target in settings.get("symlinks", {}).items():
        path = os.path.join(volume, name)
        check(f"symlink {name} → {target}", os.path.islink(path) and os.readlink(path), target)
    # Nothing else should be visible in the window.
    visible = sorted(e for e in os.listdir(volume) if not e.startswith("."))
    check("visible entries", visible, sorted([args.app_name, "Applications"]))

    ds_store_path = os.path.join(volume, ".DS_Store")
    if not os.path.isfile(ds_store_path):
        print("  FAIL  .DS_Store present: missing — the window has no saved layout at all")
        FAILURES.append(".DS_Store present")
        return report()
    print(f"  ok    .DS_Store present: {os.path.getsize(ds_store_path)} bytes")

    # "r": the volume is mounted read-only, and ds_store opens r+ by default.
    # One pass over every record; store["."] returns a lazy Partial rather than
    # a mapping, so the records are collected by hand.
    root: dict = {}
    ilocs: dict = {}
    with DSStore.open(ds_store_path, "r") as store:
        for entry in store:
            # entry.code has been bytes in some ds_store versions and str in
            # others; normalise rather than pick one and be wrong on a bump.
            code = entry.code.decode() if isinstance(entry.code, bytes) else entry.code
            if code == "Iloc":
                ilocs[entry.filename] = entry.value
            elif entry.filename == ".":
                root[code] = entry.value
    icvp = root.get("icvp")
    bwsp = root.get("bwsp")

    # ---- Window --------------------------------------------------------
    print("window")
    if bwsp is None:
        print("  FAIL  browser window settings (bwsp): missing")
        FAILURES.append("bwsp")
    else:
        (wx, wy), (ww, wh) = settings["window_rect"]
        check("WindowBounds", bwsp.get("WindowBounds"), f"{{{{{wx}, {wy}}}, {{{ww}, {wh}}}}}")
        for key, setting in (
            ("ShowStatusBar", "show_status_bar"),
            ("ShowToolbar", "show_toolbar"),
            ("ShowPathbar", "show_pathbar"),
            ("ShowSidebar", "show_sidebar"),
        ):
            check(key, bwsp.get(key), settings[setting])

    # ---- Icon view -----------------------------------------------------
    print("icon view")
    if icvp is None:
        print("  FAIL  icon view settings (icvp): missing — no background, no icon sizes")
        FAILURES.append("icvp")
    else:
        check("iconSize", icvp.get("iconSize"), float(settings["icon_size"]))
        check("textSize", icvp.get("textSize"), float(settings["text_size"]))
        check("labelOnBottom", icvp.get("labelOnBottom"), settings["label_pos"] == "bottom")
        # Icons must not be auto-arranged, or Finder overrides the positions.
        check("arrangeBy", icvp.get("arrangeBy"), "none")
        # backgroundType 2 == "picture". 1 is a solid colour, 0 is the default
        # white — both mean the generated art never made it in.
        check("backgroundType (2 = picture)", icvp.get("backgroundType"), 2)
        alias_bytes = icvp.get("backgroundImageAlias")
        if not alias_bytes:
            print("  FAIL  backgroundImageAlias: missing")
            FAILURES.append("backgroundImageAlias")
        else:
            # An alias records the volume name and path. Resolving it is the
            # only check that proves Finder will find the image rather than
            # fall back to white — a background file sitting on the volume that
            # nothing points at looks identical on disk.
            alias = mac_alias.Alias.from_bytes(bytes(alias_bytes))
            filename = alias.target.filename
            print(f"  ok    background alias: {alias.volume.name}:{filename}")
            resolved = os.path.join(volume, filename)
            check(f"background file {filename} on volume", os.path.isfile(resolved), True)
            if os.path.isfile(resolved):
                # A multi-representation TIFF: 1x and 2x in one file, which is
                # how the window stays sharp on a Retina display.
                with open(resolved, "rb") as handle:
                    magic = handle.read(4)
                check(
                    "background is a TIFF",
                    magic in (b"II*\x00", b"MM\x00*"),
                    True,
                )

    # ---- Icon positions ------------------------------------------------
    print("icon positions")
    for name, (x, y) in settings["icon_locations"].items():
        check(f"Iloc {name}", ilocs.get(name), (x, y))

    return report()


def report() -> int:
    print()
    if FAILURES:
        print(f"FAILED: {len(FAILURES)} layout check(s) did not match: {', '.join(FAILURES)}")
        return 1
    print("DMG layout matches the settings file.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
