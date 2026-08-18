#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Write the failure context that goes back to one repo's agent on a repair pass.

This is the most load-bearing artifact in the loop. An agent told only "smoke failed"
will guess; an agent given the exact assertion, the request it made, the response it got,
and its own container's log at the moment of failure will usually fix the actual cause.

Everything here is evidence, not diagnosis. The brief deliberately does not tell the agent
what is wrong — it tells it what was observed. Diagnosis from a script is how a loop talks
an agent into a wrong fix.

  failure-brief.py --run-dir DIR --repo chatbot-backend --change 0001-auth --attempt 1 -o F
"""
from __future__ import annotations

import argparse
import json
import os
import re

# Which containers a repo is answerable for. `primary` logs are always included;
# `supporting` ones only when they actually complained, because a healthy datastore's
# boot log is several hundred lines that say nothing and would crowd out the evidence.
SERVICES = {
    "chatbot-backend": {"primary": ["backend"], "supporting": ["postgres", "redis"]},
    "frontend": {"primary": ["frontend", "proxy"], "supporting": []},
    "infra": {"primary": [], "supporting": []},
}

# Health probes run every few seconds against every container, so by the time anything
# fails the logs are almost entirely successful /healthz lines. Dropping them is the
# difference between a brief an agent can read and one it has to search.
NOISE = re.compile(r"(/healthz.*\b(200|OK)\b)|(\b(200|OK)\b.*/healthz)")
# Case-sensitive on the level names and specific on the phrases: a bare /timeout|error/i
# matches `bf-error-rate` and `coordinator timeout: 0ms` in a healthy Redis config dump,
# which is how a "problems only" section fills up with things that are not problems.
TROUBLE = re.compile(
    r"\b(ERROR|FATAL|PANIC|CRITICAL|SEVERE)\b"
    r"|\b(Traceback|Exception)\b"
    r"|(connection refused|connection reset|timed out|no such host|"
    r"unhealthy|failed to|could not connect|out of memory)",
)


def read_json(path: str):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None


def tail(path: str, lines: int, drop_noise: bool = True) -> str:
    try:
        with open(path, errors="replace") as fh:
            content = fh.readlines()
    except OSError:
        return ""
    if drop_noise:
        content = [ln for ln in content if not NOISE.search(ln)]
    return "".join(content[-lines:]).rstrip()


def troubles(path: str, lines: int) -> str:
    """Only the lines where a supporting service actually complained."""
    try:
        with open(path, errors="replace") as fh:
            content = fh.readlines()
    except OSError:
        return ""
    hits = [ln for ln in content if TROUBLE.search(ln) and not NOISE.search(ln)]
    return "".join(hits[-lines:]).rstrip()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--change", required=True)
    ap.add_argument("--attempt", default="1")
    ap.add_argument("--log-lines", type=int, default=60)
    ap.add_argument("-o", "--out", required=True)
    args = ap.parse_args()

    rd = args.run_dir
    repo = args.repo
    out: list[str] = []

    verify = read_json(os.path.join(rd, "verify.json")) or {}
    fanout = read_json(os.path.join(rd, "fanout.json")) or {}

    out.append(f"# Deploy verification failed — {args.change}, attempt {args.attempt}")
    out.append("")
    out.append(f"Your slice ({repo}) was deployed alongside the other repos as one stack and")
    out.append("checked through the single origin a browser would use. The following is what")
    out.append("was observed. Fix the cause in your repo.")
    out.append("")
    if verify.get("failed_stage"):
        out.append(f"**Stage that failed:** {verify['failed_stage']}")
        out.append("")

    # What this repo's own dispatch reported, if it reported a problem.
    mine = (fanout.get("repos") or {}).get(repo)
    if mine and mine.get("status") != "ok":
        out.append("## Your previous run ended badly")
        out.append("")
        out.append(f"- status: `{mine.get('status')}` (exit {mine.get('exit')})")
        if mine.get("reason"):
            out.append(f"- reason: {mine['reason']}")
        out.append("")

    # The assertions this repo owns that failed.
    failures = []
    for name in ("smoke.json", "smoke-infra.json"):
        data = read_json(os.path.join(rd, name))
        if data:
            failures += [f for f in data.get("failures", []) if f.get("owner") == repo]

    if failures:
        out.append("## Failing assertions you own")
        out.append("")
        for f in failures:
            out.append(f"### {f.get('name')}")
            out.append("")
            out.append(f"- request: `{f.get('request')}`")
            out.append(f"- expected: `{json.dumps(f.get('expected'))}`")
            actual = f.get("actual") or {}
            if "status" in actual:
                out.append(f"- actual status: `{actual['status']}`")
            if actual.get("headers"):
                out.append(f"- actual headers: `{json.dumps(actual['headers'])}`")
            out.append(f"- failure: {f.get('message')}")
            body = (actual.get("body") or "").strip()
            if body:
                out.append("")
                out.append("Response body:")
                out.append("")
                out.append("```")
                out.append(body[:2000])
                out.append("```")
            if actual.get("error"):
                out.append("")
                out.append(f"Transport error: `{actual['error']}`")
            out.append("")

    # Container logs, which is where a 500 actually explains itself.
    spec = SERVICES.get(repo, {"primary": [], "supporting": []})
    logs_added = False

    def section(title: str, content: str) -> None:
        nonlocal logs_added
        if not logs_added:
            out.append("## Container logs at the time of failure")
            out.append("")
            out.append("_Successful health-probe lines are filtered out._")
            out.append("")
            logs_added = True
        out.append(title)
        out.append("")
        out.append("```")
        out.append(content)
        out.append("```")
        out.append("")

    for svc in spec["primary"]:
        content = tail(os.path.join(rd, f"{svc}.container.log"), args.log_lines)
        if content:
            section(f"### `{svc}` (last {args.log_lines} lines)", content)

    for svc in spec["supporting"]:
        content = troubles(os.path.join(rd, f"{svc}.container.log"), 40)
        if content:
            section(f"### `{svc}` (errors and warnings only)", content)

    out.append("## Rules for this pass")
    out.append("")
    out.append("- Fix the cause. Do NOT change, weaken or delete the smoke assertion to make")
    out.append("  it pass — the assertion is the acceptance criterion, and it is owned by the")
    out.append("  control repo, not by you.")
    out.append("- The contracts are still FROZEN. If the only correct fix requires changing")
    out.append("  the contract, STOP and reply `FAIL:contract — <what needs to change>`.")
    out.append("- Full evidence for this run, including the other repos' logs, is in")
    out.append(f"  `{os.path.abspath(rd)}`.")
    out.append("")

    with open(args.out, "w") as fh:
        fh.write("\n".join(out))
    print(f"failure-brief: wrote {args.out} ({len(failures)} owned assertion failure(s))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
