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
import re
import shlex
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

# What an output IS, as distinct from what it says. Only `value` outputs are exported into
# the environment a smoke suite can interpolate — which is what stops a secret reference
# from being interpolable into a request body.
KINDS = ("value", "env_var_name", "secret_ref")

SCALARS = (str, int, float, bool)


def env_name(output: str) -> str:
    """app_base_url -> INFRA_APP_BASE_URL.

    The prefix is mandatory and not configurable: it makes collision with SIGNUP_CODE,
    SMOKE_PASSWORD or PATH structurally impossible, and it makes "this came from a deploy"
    visible at the point of use in a suite.
    """
    return "INFRA_" + re.sub(r"[^A-Za-z0-9_]", "_", output).upper()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--actual", help="JSON emitted by `make -C infra outputs`")
    ap.add_argument("--contract", default="contracts/infra-outputs.yaml")
    ap.add_argument("--json", dest="json_out")
    ap.add_argument("--require", action="append", default=[], metavar="NAME",
                    help="the contract must PROMISE this output. Repeatable. This is what "
                         "makes an empty contract a failure instead of a vacuous pass.")
    ap.add_argument("--contract-only", action="store_true",
                    help="validate the contract's shape with no --actual. Run in preflight, "
                         "before any apply, so a contract that still promises nothing fails "
                         "before it costs money.")
    ap.add_argument("--env-out", metavar="FILE",
                    help="write `export INFRA_<NAME>=...` for every promised, kind: value, "
                         "scalar output — only after every check below has passed")
    args = ap.parse_args()

    spec = yaml.safe_load(open(args.contract)) or {}
    promised = spec.get("outputs") or {}

    problems: list[str] = []
    warnings: list[str] = []

    # ---- the contract's own shape, checkable without a deploy -----------------------
    for name, decl in (promised or {}).items():
        decl = decl or {}
        kind = decl.get("kind", "value")
        if kind not in KINDS:
            problems.append(f"{name}: unknown kind {kind!r} in {args.contract} "
                            f"(expected one of: {', '.join(KINDS)})")
        want = decl.get("type")
        if want and want not in TYPES:
            problems.append(f"{name}: unknown type {want!r} in {args.contract} "
                            f"(expected one of: {', '.join(sorted(TYPES))})")

    for name in args.require:
        if name not in promised:
            problems.append(
                f"{name}: a remote pass cannot run without it, but {args.contract} does not "
                f"promise it. Add it to the contract (one commit, contracts/ alone) and "
                f"record the freeze — see contracts/README.md.")

    # Two output names must not collapse to one variable; last-writer-wins would be silent.
    seen: dict[str, str] = {}
    for name, decl in (promised or {}).items():
        if ((decl or {}).get("kind", "value")) != "value":
            continue
        var = env_name(name)
        if var in seen:
            problems.append(f"{name} and {seen[var]} both map to ${var} — rename one")
        seen[var] = name

    if args.contract_only:
        for p in problems:
            print(f"infra-outputs: {p}", file=sys.stderr)
        if problems:
            return 1
        print(f"infra-outputs: {args.contract} promises {len(promised)} output(s), "
              f"including all {len(args.require)} the remote pass requires")
        return 0

    if not args.actual:
        print("infra-outputs: --actual is required unless --contract-only", file=sys.stderr)
        return 2

    try:
        with open(args.actual) as fh:
            text = fh.read().strip()
        actual = json.loads(text) if text else {}
    except json.JSONDecodeError as exc:
        print(f"infra-outputs: `make -C infra outputs` did not emit valid JSON: {exc}",
              file=sys.stderr)
        print(f"infra-outputs: it must print a flat JSON object of output name -> value, "
              f"and NOTHING else — a stray echo in the recipe lands here", file=sys.stderr)
        return 2
    if not isinstance(actual, dict):
        print("infra-outputs: expected a JSON object of output name -> value", file=sys.stderr)
        return 2

    for name, decl in promised.items():
        decl = decl or {}
        if name not in actual:
            consumers = ", ".join(decl.get("consumers") or []) or "unknown consumers"
            problems.append(f"{name}: promised in {args.contract} ({consumers}) but not produced")
            continue
        want = decl.get("type")
        value = actual[name]
        if want and want in TYPES and not isinstance(value, TYPES[want]):
            got = type(value).__name__
            problems.append(f"{name}: contract says type {want}, deploy produced {got}")
        # An empty string passes an isinstance check and then interpolates to nothing, after
        # which every remote step hits a relative path and fails incomprehensibly.
        elif isinstance(value, str) and not value.strip():
            problems.append(f"{name}: produced an empty string — a promised output with no "
                            f"value is not a value")

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

    if problems:
        return 1

    # ---- exports, and only now ------------------------------------------------------
    # Writing these as a product of the checks above means the exported set is exactly the
    # checked set: a suite cannot interpolate an output the contract does not promise.
    if args.env_out:
        lines = []
        for name, decl in sorted(promised.items()):
            decl = decl or {}
            if decl.get("kind", "value") != "value":
                continue
            value = actual[name]
            if not isinstance(value, SCALARS):
                print(f"infra-outputs: note — {name} is a {type(value).__name__}, not a "
                      f"scalar; not exported", file=sys.stderr)
                continue
            lines.append(f"export {env_name(name)}={shlex.quote(str(value))}")
        with open(args.env_out, "w") as fh:
            fh.write("\n".join(lines) + ("\n" if lines else ""))
        print(f"infra-outputs: exported {len(lines)} output(s) as INFRA_* for the remote pass")

    if not promised:
        print(f"infra-outputs: note — {args.contract} promises nothing yet; "
              f"produced {len(actual)} output(s), none of them checkable")
    else:
        print(f"infra-outputs: {len(promised)} promised output(s) all present and well-typed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
