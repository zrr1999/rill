#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///

import plistlib
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 9:
        print(
            "usage: write_info_plist.py PATH VERSION BUILD_NUMBER BUILD_KIND "
            "SOURCE_REVISION SOURCE_DIRTY VERSION_LABEL MICROPHONE_DESCRIPTION",
            file=sys.stderr,
        )
        return 2

    (
        path,
        version,
        build_number,
        build_kind,
        source_revision,
        source_dirty,
        version_label,
        microphone_usage_description,
    ) = sys.argv[1:]
    payload = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": "Rill",
        "CFBundleGetInfoString": version_label,
        "CFBundleIconFile": "Rill.icns",
        "CFBundleIdentifier": "dev.zrr.Rill",
        "CFBundleName": "Rill",
        "CFBundleDisplayName": "Rill",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build_number,
        "CFBundleInfoDictionaryVersion": "6.0",
        "LSMinimumSystemVersion": "14.0",
        "LSUIElement": True,
        "NSMicrophoneUsageDescription": microphone_usage_description,
        "NSPrincipalClass": "NSApplication",
        "RillBuildKind": build_kind,
        "RillSourceDirty": source_dirty == "true",
        "RillSourceRevision": source_revision,
        "RillVersionLabel": version_label,
    }
    try:
        with Path(path).open("wb") as output:
            plistlib.dump(payload, output, fmt=plistlib.FMT_XML, sort_keys=True)
    except (OSError, ValueError) as error:
        print(f"cannot write Info.plist: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
