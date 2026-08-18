#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx>=0.27", "pyyaml>=6"]
# ///
"""Run a contract-driven smoke suite against a running stack.

The control repo owns these because they assert the one thing no product repo can assert
alone: that independently-built, independently-deployed services actually talk to each
other through the origin the browser will use.

Each step names an `owner` — the repo answerable for it. That field is not decoration; it
is what lets iterate.sh send a failure back to the agent that caused it instead of
guessing or asking a human.

Usage:
  smoke.py SUITE.yaml [SUITE.yaml ...] --base http://localhost:8080
           [--contract contracts/openapi.yaml] [--json out.json]
           [--only NAME] [--tag TAG] [--keep-going] [--quiet]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from typing import Any

import httpx
import yaml

METHODS = ("GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS")
VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


# --------------------------------------------------------------------------- helpers

def die(msg: str) -> None:
    print(f"smoke: {msg}", file=sys.stderr)
    raise SystemExit(2)


def interpolate(value: Any, scope: dict[str, Any]) -> Any:
    """Substitute ${name} from captured vars, falling back to the environment."""
    if isinstance(value, str):
        def sub(m: re.Match[str]) -> str:
            key = m.group(1)
            if key in scope:
                return str(scope[key])
            if key in os.environ:
                return os.environ[key]
            die(f"undefined variable ${{{key}}} — not captured by an earlier step or in env")
            return ""
        return VAR.sub(sub, value)
    if isinstance(value, dict):
        return {k: interpolate(v, scope) for k, v in value.items()}
    if isinstance(value, list):
        return [interpolate(v, scope) for v in value]
    return value


def dig(data: Any, path: str) -> Any:
    """Dotted lookup into decoded JSON: 'user.id', 'items.0.name'."""
    cur = data
    for part in path.split("."):
        if isinstance(cur, list):
            try:
                cur = cur[int(part)]
            except (ValueError, IndexError):
                return None
        elif isinstance(cur, dict):
            if part not in cur:
                return None
            cur = cur[part]
        else:
            return None
    return cur


def subset_of(expected: Any, actual: Any, path: str = "") -> str | None:
    """Deep containment: every key/value in `expected` must appear in `actual`.

    Containment rather than equality on purpose — a response is allowed to grow new
    fields without breaking every suite that touched it. Contracts are expand-first here
    (see docs/adr/0001), so the assertions should be too.
    """
    where = path or "(root)"
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return f"{where}: expected an object, got {type(actual).__name__}"
        for k, v in expected.items():
            if k not in actual:
                return f"{where}.{k}: missing from response"
            err = subset_of(v, actual[k], f"{path}.{k}" if path else k)
            if err:
                return err
        return None
    if isinstance(expected, list):
        if not isinstance(actual, list):
            return f"{where}: expected an array, got {type(actual).__name__}"
        if len(actual) < len(expected):
            return f"{where}: expected at least {len(expected)} items, got {len(actual)}"
        for i, v in enumerate(expected):
            err = subset_of(v, actual[i], f"{path}[{i}]")
            if err:
                return err
        return None
    if expected != actual:
        return f"{where}: expected {expected!r}, got {actual!r}"
    return None


# ----------------------------------------------------------------------- the contract

class Contract:
    """The frozen OpenAPI spec, used to assert that smoke only exercises declared surface.

    This catches mechanically what the contract-conformance agent catches by reading: a
    route that works but was never frozen. A green suite over undeclared endpoints is the
    failure mode this exists to prevent.
    """

    def __init__(self, spec_path: str, strip_prefix: str = "") -> None:
        with open(spec_path) as fh:
            spec = yaml.safe_load(fh) or {}
        self.path = spec_path
        self.strip_prefix = strip_prefix
        self.paths: dict[str, Any] = spec.get("paths") or {}
        self.empty = not self.paths

    def check(self, method: str, url_path: str, status: int) -> str | None:
        if self.empty:
            return None
        target = url_path.split("?")[0]
        if self.strip_prefix and target.startswith(self.strip_prefix):
            target = target[len(self.strip_prefix):] or "/"
        for template, ops in self.paths.items():
            pattern = "^" + re.sub(r"\{[^/}]+\}", r"[^/]+", re.escape(template)
                                   .replace(r"\{", "{").replace(r"\}", "}")) + "$"
            if not re.match(pattern, target):
                continue
            op = (ops or {}).get(method.lower())
            if op is None:
                return f"{method} {target} is not declared in {self.path} (path exists, method does not)"
            responses = op.get("responses") or {}
            if str(status) not in responses and "default" not in responses:
                return f"{method} {target} -> {status} is not a declared response in {self.path}"
            return None
        return f"{target} is not declared in {self.path}"


# ---------------------------------------------------------------------------- running

def load_steps(paths: list[str]) -> list[dict[str, Any]]:
    steps: list[dict[str, Any]] = []
    for p in paths:
        if not os.path.exists(p):
            die(f"no such suite: {p}")
        doc = yaml.safe_load(open(p)) or {}
        for step in doc.get("steps") or []:
            step["_suite"] = p
            steps.append(step)
    return steps


def request_line(step: dict[str, Any]) -> tuple[str, str]:
    found = [m for m in METHODS if m in step]
    if len(found) != 1:
        die(f"step {step.get('name', '?')!r} must have exactly one of {', '.join(METHODS)}")
    return found[0], str(step[found[0]])


def run_step(client: httpx.Client, step: dict[str, Any], scope: dict[str, Any],
             contract: Contract | None, base: str) -> dict[str, Any]:
    method, raw_path = request_line(step)
    path = interpolate(raw_path, scope)
    headers = interpolate(step.get("headers") or {}, scope)
    body = interpolate(step.get("body"), scope) if "body" in step else None
    form = interpolate(step.get("form"), scope) if "form" in step else None
    expect = step.get("expect") or {}
    retry = step.get("retry") or {}
    attempts = int(retry.get("attempts", 1))
    delay = float(retry.get("delay", 1.0))

    # A step may target a different origin than the suite default — the proxy is the
    # browser's view, but "is the backend itself healthy" is a different question and
    # answering both is how a 502 gets attributed to the right repo.
    step_base = interpolate(step["base"], scope) if "base" in step else base

    result: dict[str, Any] = {
        "name": step.get("name") or f"{method} {path}",
        "owner": step.get("owner"),
        "suite": step.get("_suite"),
        "request": f"{method} {path}" + ("" if step_base == base else f"  (at {step_base})"),
        "expected": expect,
    }

    last_err: str | None = None
    for attempt in range(1, attempts + 1):
        try:
            resp = client.request(method, step_base.rstrip("/") + path, headers=headers,
                                  json=body, data=form)
        except httpx.RequestError as exc:
            last_err = f"request failed: {exc.__class__.__name__}: {exc}"
            result["actual"] = {"error": last_err}
            if attempt < attempts:
                time.sleep(delay)
                continue
            result["ok"] = False
            result["message"] = last_err
            return result

        try:
            decoded = resp.json()
        except ValueError:
            decoded = None
        text = resp.text
        result["actual"] = {
            "status": resp.status_code,
            "body": text if len(text) <= 2000 else text[:2000] + f"\n... [{len(text)} bytes total]",
            "headers": {k: v for k, v in resp.headers.items()
                        if k.lower() in ("content-type", "set-cookie", "location")},
        }

        last_err = evaluate(expect, resp, decoded, text)
        if last_err is None and contract is not None:
            last_err = contract.check(method, path, resp.status_code)
        if last_err is None:
            for var, source in (step.get("capture") or {}).items():
                scope[var] = extract(source, resp, decoded)
            result["ok"] = True
            result["attempts"] = attempt
            return result

        if attempt < attempts:
            time.sleep(delay)

    result["ok"] = False
    result["message"] = last_err
    result["attempts"] = attempts
    return result


def evaluate(expect: dict[str, Any], resp: httpx.Response, decoded: Any, text: str) -> str | None:
    if "status" in expect:
        want = expect["status"]
        allowed = want if isinstance(want, list) else [want]
        if resp.status_code not in allowed:
            return f"expected status {want}, got {resp.status_code}"
    if "json" in expect:
        if decoded is None:
            return f"expected a JSON body, got content-type {resp.headers.get('content-type')!r}"
        err = subset_of(expect["json"], decoded)
        if err:
            return f"json mismatch — {err}"
    if "body_matches" in expect:
        if not re.search(expect["body_matches"], text, re.S):
            return f"body does not match /{expect['body_matches']}/"
    if "body_excludes" in expect:
        if re.search(expect["body_excludes"], text, re.S):
            return f"body unexpectedly matches /{expect['body_excludes']}/"
    for name, want in (expect.get("headers") or {}).items():
        got = resp.headers.get(name)
        if got is None:
            return f"expected header {name!r}, absent from response"
        if not re.search(want, got):
            return f"header {name}: {got!r} does not match /{want}/"
    if "cookie" in expect:
        for name in ([expect["cookie"]] if isinstance(expect["cookie"], str) else expect["cookie"]):
            if name not in resp.cookies:
                return f"expected cookie {name!r} to be set"
    return None


def extract(source: str, resp: httpx.Response, decoded: Any) -> Any:
    if source.startswith("header:"):
        return resp.headers.get(source[len("header:"):])
    if source.startswith("cookie:"):
        return resp.cookies.get(source[len("cookie:"):])
    return dig(decoded, source)


# ------------------------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("suites", nargs="+")
    ap.add_argument("--base", default=os.environ.get("SMOKE_BASE", "http://localhost:8080"))
    ap.add_argument("--contract")
    ap.add_argument("--strip-prefix", default="/api",
                    help="stripped before matching against the spec; the proxy serves the "
                         "API under /api/ but the spec declares paths without it")
    ap.add_argument("--json", dest="json_out")
    ap.add_argument("--only", action="append", default=[])
    ap.add_argument("--tag", action="append", default=[])
    ap.add_argument("--keep-going", action="store_true",
                    help="run every step instead of stopping at the first failure")
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    steps = load_steps(args.suites)
    if args.only:
        steps = [s for s in steps if s.get("name") in args.only]
    if args.tag:
        steps = [s for s in steps if set(s.get("tags") or []) & set(args.tag)]

    contract = None
    if args.contract and os.path.exists(args.contract):
        contract = Contract(args.contract, args.strip_prefix)
        if contract.empty and not args.quiet:
            print(f"smoke: note — {args.contract} declares no paths; "
                  f"contract assertions are inert until it is filled in")

    results: list[dict[str, Any]] = []
    scope: dict[str, Any] = {}
    # One client for the whole suite: cookies persist across steps, which is the only way
    # register -> login -> me is testable when sessions are httpOnly cookies.
    with httpx.Client(timeout=args.timeout, follow_redirects=False) as client:
        for step in steps:
            res = run_step(client, step, scope, contract, args.base)
            results.append(res)
            if not args.quiet:
                mark = "PASS" if res["ok"] else "FAIL"
                owner = f" [{res['owner']}]" if res.get("owner") else ""
                print(f"  {mark}  {res['name']}{owner}  ({res['request']})")
                if not res["ok"]:
                    print(f"        {res['message']}")
                    actual = res.get("actual", {})
                    if "body" in actual:
                        body = actual["body"].strip()
                        if body:
                            for line in body.splitlines()[:12]:
                                print(f"        | {line}")
            if not res["ok"] and not args.keep_going:
                break

    failures = [r for r in results if not r["ok"]]
    summary = {
        "ok": not failures,
        "base": args.base,
        "suites": args.suites,
        "passed": len(results) - len(failures),
        "failed": len(failures),
        "skipped": len(steps) - len(results),
        "owners_failing": sorted({r["owner"] for r in failures if r.get("owner")}),
        "failures": failures,
        "steps": results,
    }
    if args.json_out:
        with open(args.json_out, "w") as fh:
            json.dump(summary, fh, indent=2)
    if not args.quiet:
        print(f"smoke: {summary['passed']} passed, {summary['failed']} failed"
              + (f", {summary['skipped']} not reached" if summary["skipped"] else ""))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
