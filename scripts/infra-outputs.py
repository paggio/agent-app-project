#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6"]
# ///
"""Check what infra actually produced against what contracts/infra-outputs.yaml promised.

infra outputs are the one interface the application repos cannot test against a running
service — they are consumed at deploy time, and a missing or retyped output surfaces as a
broken environment rather than a failed request. So it is checked here, structurally,
the moment infra deploys.

The comparison is one-directional in the strict sense and two-directional as a warning:
every promised output MUST be produced (a consumer would break), and anything produced
but unpromised is reported (undeclared surface consumers may start depending on).

  infra-outputs.py --actual outputs.json --contract contracts/infra-outputs.yaml
"""
from __future__ import annotations

import argparse
import json
import sys

import yaml

TYPES = {
    "string": str,
    "number": (int, float),
    "bool": bool,
    "boolean": bool,
    "list": list,
    "object": dict,
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--actual", required=True, help="JSON emitted by `make -C infra outputs`")
    ap.add_argument("--contract", default="contracts/infra-outputs.yaml")
    ap.add_argument("--json", dest="json_out")
    args = ap.parse_args()

    try:
        with open(args.actual) as fh:
            text = fh.read().strip()
        actual = json.loads(text) if text else {}
    except json.JSONDecodeError as exc:
        print(f"infra-outputs: `make -C infra outputs` did not emit valid JSON: {exc}",
              file=sys.stderr)
        print(f"infra-outputs: it must print a flat JSON object of output name -> value",
              file=sys.stderr)
        return 2
    if not isinstance(actual, dict):
        print("infra-outputs: expected a JSON object of output name -> value", file=sys.stderr)
        return 2

    spec = yaml.safe_load(open(args.contract)) or {}
    promised = spec.get("outputs") or {}

    problems: list[str] = []
    warnings: list[str] = []

    for name, decl in promised.items():
        decl = decl or {}
        if name not in actual:
            consumers = ", ".join(decl.get("consumers") or []) or "unknown consumers"
            problems.append(f"{name}: promised in {args.contract} ({consumers}) but not produced")
            continue
        want = decl.get("type")
        if want and want in TYPES and not isinstance(actual[name], TYPES[want]):
            got = type(actual[name]).__name__
            problems.append(f"{name}: contract says type {want}, deploy produced {got}")

    for name in actual:
        if name not in promised:
            warnings.append(f"{name}: produced by infra but not declared in {args.contract}")

    for w in warnings:
        print(f"infra-outputs: warning — {w}", file=sys.stderr)
    for p in problems:
        print(f"infra-outputs: {p}", file=sys.stderr)

    summary = {
        "ok": not problems,
        "promised": sorted(promised),
        "produced": sorted(actual),
        "problems": problems,
        "warnings": warnings,
    }
    if args.json_out:
        with open(args.json_out, "w") as fh:
            json.dump(summary, fh, indent=2)

    if not promised:
        print(f"infra-outputs: note — {args.contract} promises nothing yet; "
              f"produced {len(actual)} output(s), none of them checkable")
    elif not problems:
        print(f"infra-outputs: {len(promised)} promised output(s) all present and well-typed")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
