#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6"]
# ///
"""Does the deployed environment agree with the frozen contract, and is it running the
code this run just verified locally?

  infra-crosscheck.py --outputs <infra-outputs.json> \
      --contract contracts/openapi.yaml --strip-prefix /api \
      --deploy-set deploy-set.json

Two checks, both cheap, both closing a silent pass.

1. THE PREFIX. Locally the proxy's `handle_path /api/*` STRIPS /api before forwarding, and
   contracts/openapi.yaml declares `servers: [{url: /api}]` with paths written as the
   backend serves them. An ALB path rule does NOT strip a prefix without an explicit
   rewrite — and because the frontend answers any unmatched path with the SPA shell and a
   200 (`try_files $uri $uri/ /index.html`), a rule that never matches /api/* returns
   `200 text/html` for API calls rather than a loud 404. `Contract.check` never looks at a
   body, so any step asserting only a status would pass. Three things must therefore name
   the same prefix: what infra configured, what the contract declares, and what smoke.py
   strips before matching. Two of the three legs need no deploy at all.

2. THE IMAGES. `infra/bin/infra deploy` cannot build the app, so without this the remote
   pass asserts whatever image happened to be deployed while the local pass asserted the
   code under test. Under a repair loop that means attempt 2's fix is invisible remotely
   and the run could report `verified` for an environment running last week's backend.
   Comparing the deployed tags against the deploy set (scripts/deploy-set.py) turns "the
   remote pass tested these commits" from an assumption into a checked fact.
"""
from __future__ import annotations

import argparse
import json
import sys

import yaml


def norm(p: str) -> str:
    p = (p or "").strip()
    return "/" + p.strip("/") if p.strip("/") else "/"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--outputs", required=True)
    ap.add_argument("--contract", default="contracts/openapi.yaml")
    ap.add_argument("--strip-prefix", default="")
    ap.add_argument("--deploy-set", required=True)
    args = ap.parse_args()

    out = json.load(open(args.outputs))
    spec = yaml.safe_load(open(args.contract)) or {}

    problems: list[str] = []

    # ---- 1. the prefix, three ways --------------------------------------------------
    servers = spec.get("servers") or []
    declared = (servers[0] or {}).get("url", "") if servers else ""
    promised = out.get("api_path_prefix") or ""

    if norm(promised) != norm(declared):
        problems.append(
            f"api_path_prefix: infra deployed {promised!r} but {args.contract} declares "
            f"servers[0].url = {declared!r}. The edge strips this prefix; if it strips a "
            f"different one, every API path is wrong.")
    if norm(promised) != norm(args.strip_prefix):
        problems.append(
            f"api_path_prefix: infra deployed {promised!r} but smoke will strip "
            f"{args.strip_prefix!r} before matching the contract, so the remote pass would "
            f"assert the wrong paths.")

    # ---- 2. the images actually running ---------------------------------------------
    # backend and frontend are promised by the contract, so a missing output is a failure.
    # An image the contract does not promise yet cannot be checked, and says so.
    PROMISED = {"backend", "frontend"}
    ds = json.load(open(args.deploy_set))
    for repo, entry in (ds.get("repos") or {}).items():
        for image, want in (entry.get("images") or {}).items():
            name = f"deployed_{image}_image"
            ref = out.get(name) or ""
            tag = ref.rsplit(":", 1)[-1] if ":" in ref else ""
            if not ref and image not in PROMISED:
                print(f"infra-crosscheck: warning — {name} is not reported, so {image} "
                      f"cannot be checked against {want}", file=sys.stderr)
            elif not tag:
                problems.append(f"{name}: {ref!r} carries no tag, so what is running cannot "
                                f"be identified")
            elif tag != want:
                problems.append(
                    f"{name}: the environment is running {tag!r} but the deploy set says "
                    f"{repo} {entry.get('source')} {want!r}. The remote pass would assert "
                    f"commits nobody asked for.")

    for p in problems:
        print(f"infra-crosscheck: {p}", file=sys.stderr)
    if problems:
        return 1
    print(f"infra-crosscheck: prefix {norm(promised)} agrees with the contract and with "
          f"smoke; deployed images match the deploy set")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
