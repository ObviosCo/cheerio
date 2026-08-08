#!/usr/bin/env python3
"""Check that a Sparkle appcast entry really describes the zip we just built.

Run by .github/workflows/release.yml between generating the appcast and publishing
it. Prints the entry's EdDSA signature on success so the workflow can hand it to
`sign_update --verify`; exits non-zero with a reason on any mismatch.

Everything here is a mistake that ships silently if nobody looks:

- generate_appcast reads SUPublicEDKey out of the app it is signing. If that key is
  missing, unparseable, or a different key from the one in the private key file, it
  prints a warning, writes an item with *no* sparkle:edSignature, and exits 0. A
  feed like that either offers unverified downloads or is rejected by every install.
- A wrong enclosure URL, or an entry for some other build that happened to be lying
  around, produces a feed that points at a download that isn't this release.
- A minimumSystemVersion that isn't 26.0 means LSMinimumSystemVersion drifted, and
  Sparkle would offer the update to Macs that cannot run it.

Usage:
    verify-appcast.py APPCAST ZIP --short-version 1.2.3 --bundle-version 47 \\
        --url https://example.com/Cheerio-1.2.3.zip [--minimum-system-version 26.0]
"""

import argparse
import os
import sys
import xml.etree.ElementTree as ElementTree

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def sparkle_text(item, tag):
    node = item.find(f"{{{SPARKLE_NS}}}{tag}")
    return node.text if node is not None else None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("appcast", help="path to the generated appcast.xml")
    parser.add_argument("zip", help="path to the zip the appcast should describe")
    parser.add_argument("--short-version", required=True, help="expected CFBundleShortVersionString")
    parser.add_argument("--bundle-version", required=True, help="expected CFBundleVersion (Sparkle's sparkle:version)")
    parser.add_argument("--url", required=True, help="expected enclosure URL")
    parser.add_argument("--minimum-system-version", default="26.0", help="expected sparkle:minimumSystemVersion")
    # Default matches both a tagged release's notes link (…/releases/tag/v1.2.3) and a
    # dry run's (…/releases), so the check is the same on both paths.
    parser.add_argument("--release-notes-must-contain", default="/releases", help="substring the release notes must contain")
    args = parser.parse_args()

    root = ElementTree.parse(args.appcast).getroot()
    items = root.findall("./channel/item")
    if not items:
        sys.exit(f"{args.appcast}: no items — generate_appcast wrote nothing for this build")

    # Sparkle identifies a build by sparkle:version (CFBundleVersion), so that is
    # what we match on, not the human-facing version string.
    matching = [item for item in items if sparkle_text(item, "version") == args.bundle_version]
    if len(matching) != 1:
        sys.exit(f"{args.appcast}: expected exactly one item for build {args.bundle_version}, found {len(matching)}")
    item = matching[0]

    problems = []

    short_version = sparkle_text(item, "shortVersionString")
    if short_version != args.short_version:
        problems.append(f"shortVersionString is {short_version!r}, expected {args.short_version!r}")

    minimum = sparkle_text(item, "minimumSystemVersion")
    if minimum != args.minimum_system_version:
        problems.append(f"minimumSystemVersion is {minimum!r}, expected {args.minimum_system_version!r}")

    notes = item.findtext("description") or ""
    if args.release_notes_must_contain not in notes:
        problems.append(f"release notes do not mention {args.release_notes_must_contain!r}")

    enclosure = item.find("enclosure")
    if enclosure is None:
        sys.exit(f"{args.appcast}: item for build {args.bundle_version} has no enclosure")

    if enclosure.get("url") != args.url:
        problems.append(f"enclosure url is {enclosure.get('url')!r}, expected {args.url!r}")

    actual_length = os.path.getsize(args.zip)
    if enclosure.get("length") != str(actual_length):
        problems.append(f"enclosure length is {enclosure.get('length')!r}, but {args.zip} is {actual_length} bytes")

    signature = enclosure.get(f"{{{SPARKLE_NS}}}edSignature")
    if not signature:
        problems.append("enclosure has no sparkle:edSignature — generate_appcast could not sign this build")

    if problems:
        sys.exit(f"{args.appcast} does not describe {args.zip}:\n  - " + "\n  - ".join(problems))

    print(signature)


if __name__ == "__main__":
    main()
