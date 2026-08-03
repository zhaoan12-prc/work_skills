#!/usr/bin/env python3
"""Verify Claude Code JSON output without printing response content."""

import json
import sys


SUPPORTED = {"claude-sonnet-4.6", "claude-opus-4.6"}


def collect_model_usage(value, found):
    if isinstance(value, dict):
        usage = value.get("modelUsage")
        if isinstance(usage, dict):
            found.update(key for key in usage if isinstance(key, str))
        for child in value.values():
            collect_model_usage(child, found)
    elif isinstance(value, list):
        for child in value:
            collect_model_usage(child, found)


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError as exc:
        print("ERROR: input is not valid Claude JSON output: {}".format(exc), file=sys.stderr)
        return 2

    models = set()
    collect_model_usage(payload, models)
    if not models:
        print("ERROR: modelUsage is missing from Claude JSON output", file=sys.stderr)
        return 1

    unsupported = sorted(models - SUPPORTED)
    if unsupported:
        print(
            "ERROR: unsupported model(s): {}".format(", ".join(unsupported)),
            file=sys.stderr,
        )
        return 1

    print("OK: {}".format(", ".join(sorted(models))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
