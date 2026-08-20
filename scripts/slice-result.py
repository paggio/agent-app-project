#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Parse one dispatched slice's result out of its log, as a field rather than a match.

Emits one TSV line: repo, status, exit, branch, reason, pr, contract_gap

WHY A SENTINEL BLOCK. The old protocol asked for `OK` or `FAIL:<reason>` as the last line
and matched it with `case "$last" in OK|OK.*)`. That glob needs a literal dot, so `OK — done`
and `**OK**` fell through to "unclear", which counted as failed — a successful slice
routinely earned a repair pass. And a contract gap was detected by grepping the whole of
fanout.json for the substring "contract", so `FAIL:contract tests in my repo are red`
became a hard stop for the entire change, while a genuine gap phrased as "the spec doesn't
allow this" got a normal repair pass and was sent back to work around a frozen contract.

Sentinels survive markdown, a code fence, and trailing tool noise. A file the agent writes
was the alternative and is worse: a crashed or hung agent writes nothing, and "absent" has
to be a defined result rather than an accident.

Status precedence is deliberate — a timeout or a crash outranks whatever the log claims.
"""
from __future__ import annotations

import argparse
import json
import re
import sys

BLOCK = re.compile(r"<<<SLICE-RESULT\s*(.*?)\s*SLICE-RESULT>>>", re.S)
VALID = ("ok", "failed", "blocked-by-contract")


def tail(path: str, n: int = 12) -> str:
    try:
        lines = [ln.rstrip() for ln in open(path, errors="replace") if ln.strip()]
    except OSError:
        return ""
    return " / ".join(lines[-n:])[:400]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--exit", type=int, required=True)
    ap.add_argument("--branch", default="unknown")
    ap.add_argument("--timed-out", default="0")
    args = ap.parse_args()

    status, reason, pr, gap = "failed", "", "", ""

    try:
        text = open(args.log, errors="replace").read()
    except OSError:
        text = ""

    blocks = BLOCK.findall(text)

    if args.timed_out == "1":
        status, reason = "timeout", "the session was killed after exceeding its time budget"
    elif args.exit != 0:
        status = "crashed"
        reason = f"agent exited {args.exit}: {tail(args.log, 6)}"
    elif not blocks:
        status = "no-result"
        reason = f"agent produced no SLICE-RESULT block; see {args.log}"
    else:
        # Last block wins: an agent may print an example of the format before the real one.
        try:
            data = json.loads(blocks[-1])
        except json.JSONDecodeError as exc:
            status = "malformed-result"
            reason = f"SLICE-RESULT is not valid JSON ({exc}); see {args.log}"
        else:
            claimed = str(data.get("status") or "")
            summary = str(data.get("summary") or "").replace("\t", " ")[:200]
            pr = str(data.get("pr") or "")
            gap = str(data.get("contract_gap") or "").replace("\t", " ")[:400]
            if claimed not in VALID:
                status = "malformed-result"
                reason = (f"SLICE-RESULT status {claimed!r} is not one of "
                          f"{', '.join(VALID)}")
            elif claimed == "blocked-by-contract" and not gap:
                # A hard stop for the whole change has to say what must change, or the
                # re-freeze pass has nothing to work from.
                status = "malformed-result"
                reason = ("blocked-by-contract with no contract_gap — a hard stop must say "
                          "what must change")
            else:
                status = claimed
                reason = summary

    print("\t".join([args.repo, status, str(args.exit), args.branch,
                     reason, pr, gap]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
