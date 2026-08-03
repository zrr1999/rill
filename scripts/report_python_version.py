#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///

import sys

print(".".join(str(component) for component in sys.version_info[:3]))
