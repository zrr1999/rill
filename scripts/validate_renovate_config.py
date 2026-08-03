#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///

import json
import sys
from pathlib import Path

EXPECTED = {
    "$schema": "https://docs.renovatebot.com/renovate-schema.json",
    "extends": ["github>zrr1999/renovate-config"],
}


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate_renovate_config.py PATH", file=sys.stderr)
        return 2
    try:
        with Path(sys.argv[1]).open(encoding="utf-8") as config_file:
            config = json.load(config_file)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        print(f"cannot read Renovate config: {error}", file=sys.stderr)
        return 2
    if config != EXPECTED:
        print(
            "Renovate config must match the shared zrr1999 preset entrypoint",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
