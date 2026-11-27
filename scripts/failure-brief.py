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
import glob
import json
import os
import re
import sys

# Which containers a repo is answerable for. `primary` logs are always included;
# `supporting` ones only when they actually complained, because a healthy datastore's
# boot log is several hundred lines that say nothing and would crowd out the evidence.
# Kept in step with stack/compose.yml by check-docs.py [stack-services]: opensearch and
# minio arrived with 0004 and were never added here, so a retrieval failure would have been
# briefed to the backend agent with no OpenSearch log in it. phoenix and phoenix-db arrived
# with 0005 and are `supporting` for a reason that is the point of the whole change: the app
# fails OPEN on telemetry, so a Phoenix that is down must never be the first thing an agent
# is shown — it is evidence only when it actually complained.
SERVICES = {
    "chatbot-backend": {"primary": ["backend", "call-worker", "call-simulator"],
                        "supporting": ["postgres", "redis", "opensearch", "minio",
                                       "phoenix", "phoenix-db", "elasticmq",
                                       "metrics-gateway"]},
    # The e2e stage drives the real backend through the proxy, so a browser test that fails
    # on the answer explains itself in the backend's log. 0010's metrics e2e failed on
    # `no_release` and the frontend brief carried no backend line.
    "frontend": {"primary": ["frontend", "proxy"], "supporting": ["backend"]},
    "infra": {"primary": [], "supporting": []},
    # The eval is a CLIENT of the backend, so `backend` is supporting here as well as
    # primary above: an eval run that fails because the API refused it is unreadable
    # without the API's own log, and the eval agent cannot fix the backend but can say
    # what it was told. phoenix is supporting for the reason it is supporting for the
    # backend — the eval fails CLOSED on Phoenix, so a Phoenix that is down is a real
    # cause here rather than a fail-open one, but it is still evidence only when it
    # actually complained.
    "chatbot-eval": {"primary": ["eval"],
                     "supporting": ["backend", "call-worker", "elasticmq", "phoenix",
                                    "phoenix-db", "opensearch", "minio", "proxy"]},
    # The release job builds against both engines and publishes to the bucket the gateway
    # reads; the gateway queries the same engines through MetricFlow. Each is supporting for
    # the other, because a release that does not load and a gateway that cannot read it fail
    # the same steps.
    "analytics-dbt": {"primary": ["dbt-release"],
                      "supporting": ["trino", "iceberg-rest", "postgres", "minio"]},
    "metrics-gateway": {"primary": ["metrics-gateway", "indexer"],
                        "supporting": ["trino", "iceberg-rest", "postgres", "minio",
                                       "phoenix", "dbt-release"]},
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
    r"unhealthy|failed to|could not connect|out of memory)"
    # The backend's structured WARNING is how it reports a fail-open degrade (0010:
    # `metrics search failed, not routing to metrics: no_release`). Bare WARNING is not
    # matched: Redis and MinIO print one at every boot.
    r'|"level": "WARNING"',
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

    # The assertions this repo owns that failed. smoke-remote.json is the deployed-origin
    # pass.
    failures = []
    # docs-currency.json is verify.sh's docs-moved-with-code assertion, in the same shape.
    for name, label in (("smoke.json", "local"), ("smoke-remote.json", "remote"),
                        ("docs-currency.json", "docs-currency")):
        data = read_json(os.path.join(rd, name))
        if data:
            for f in data.get("failures", []):
                if f.get("owner") == repo:
                    f = dict(f)
                    f["_pass"] = label
                    failures.append(f)

    if failures:
        out.append("## Failing assertions you own")
        out.append("")
        for f in failures:
            out.append(f"### {f.get('name')}")
            out.append("")
            # Which origin it failed against changes the diagnosis entirely: the same step
            # failing remotely but not locally is an environment or edge problem.
            out.append(f"- pass: `{f.get('_pass', 'local')}`")
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

    # The contract stage's evidence is a diff, and it lives in one file nothing read. A
    # brief for a harvest failure arrived naming the stage and attaching container logs
    # showing a single successful GET /openapi.json — so its most prominent content was a
    # log with nothing in it, and the agent had to go find harvest.log to learn which field
    # was even involved.
    harvest = os.path.join(rd, "harvest.log")
    if os.path.exists(harvest):
        body = open(harvest, errors="replace").read().strip()
        if body and "the contract and the implementation agree" not in body:
            out.append("## The contract versus what is served")
            out.append("")
            out.append("_This ran BEFORE the smoke suite, so no assertion was evaluated._")
            out.append("")
            out.append("```")
            out.append(body[:4000])
            out.append("```")
            out.append("")

    # A job's own output. This is the whole of the evidence when the failing stage is a
    # one-shot run: there is no request and no response to show, the exit code IS the
    # assertion, and what the process printed on its way to that code is the only thing
    # that says why. Included whenever a job log exists for this repo, not only on a
    # job-stage failure — a job that passed while a later assertion failed is still
    # context, and it is short.
    jobs = sorted(glob.glob(os.path.join(rd, "job-*.log")))
    if jobs:
        out.append("## One-shot runs in this pass")
        out.append("")
        out.append("_Each of these is a container the loop ran to completion inside the "
                   "joined stack. Its exit code is the assertion; `change.yaml` declares "
                   "what it had to be._")
        out.append("")
        for path in jobs:
            name = os.path.basename(path)[len("job-"):-len(".log")]
            out.append(f"### job `{name}`")
            out.append("")
            out.append("```")
            out.append(tail(path, args.log_lines, drop_noise=False) or "(no output)")
            out.append("```")
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

    # infra owns no containers, so the loop above finds nothing for it and its brief used to
    # arrive carrying a stage string and nothing else. Its evidence lives in different
    # files — including the outputs check, which nothing read at all.
    infra_evidence = 0
    if repo == "infra":
        check = read_json(os.path.join(rd, "infra-outputs-check.json"))
        if check and (check.get("problems") or check.get("warnings")):
            body = "\n".join(["problems:"] + [f"  - {p}" for p in check.get("problems") or []]
                             + ["warnings:"] + [f"  - {w}" for w in check.get("warnings") or []])
            section("### outputs versus `contracts/infra-outputs.yaml`", body)
            infra_evidence += 1
        for name, title in (("infra-plan.txt", "the plan"),
                            ("infra-deploy.log", "the apply"),
                            ("infra-outputs.err", "the outputs target's stderr")):
            content = tail(os.path.join(rd, name), args.log_lines)
            if content:
                section(f"### `{name}` — {title}", content)
                infra_evidence += 1

    out.append("## Rules for this pass")
    out.append("")
    out.append("- Fix the cause. Do NOT change, weaken or delete the smoke assertion to make")
    out.append("  it pass — the assertion is the acceptance criterion, and it is owned by the")
    out.append("  control repo, not by you.")
    out.append("- The contracts are still FROZEN, and the copy you were given is the frozen")
    out.append("  one. If the only correct fix requires changing the contract, STOP and")
    out.append("  report `blocked-by-contract` with the exact entry that must change.")
    out.append("- Full evidence for this run, including the other repos' logs, is in")
    out.append(f"  `{os.path.abspath(rd)}`.")
    out.append("")

    with open(args.out, "w") as fh:
        fh.write("\n".join(out))

    # A brief with no failing assertion, no log and no infra artefact says only "something
    # went wrong somewhere". Dispatching that is a blind retry, so say so and let the loop
    # decide — exit 3 rather than a silent 0.
    evidence = len(failures) + (1 if logs_added else 0) + infra_evidence
    print(f"failure-brief: wrote {args.out} ({len(failures)} owned assertion failure(s), "
          f"evidence: {evidence})")
    if evidence == 0:
        print(f"failure-brief: no evidence was captured for {repo} — a repair pass from this "
              f"brief would be a blind re-run", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
