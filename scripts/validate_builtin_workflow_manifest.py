#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate_builtin_workflow_manifest.py PATH", file=sys.stderr)
        return 2

    try:
        with Path(sys.argv[1]).open(encoding="utf-8") as source:
            manifest = json.load(source)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        print(f"cannot read built-in workflow manifest: {error}", file=sys.stderr)
        return 2

    if not isinstance(manifest, dict):
        print("Built-in workflow manifest must be a JSON object", file=sys.stderr)
        return 2
    if not isinstance(manifest.get("workflows"), list):
        print(
            "Built-in workflow manifest must contain a workflows array",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
