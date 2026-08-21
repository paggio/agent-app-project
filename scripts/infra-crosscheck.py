#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6"]
# ///
"""Does the deployed environment agree with the frozen contract, and is it running the
code this run just verified locally?

  infra-crosscheck.py --outputs <infra-outputs.json> \
      --contract contracts/openapi.yaml --strip-prefix /api \
      --backend-sha <sha> --frontend-sha <sha>

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

2. THE IMAGES. `make -C infra deploy` cannot build the app, so without this the remote
   pass asserts whatever image happened to be deployed while the local pass asserted the
   code under test. Under a repair loop that means attempt 2's fix is invisible remotely
   and the run could report `verified` for an environment running last week's backend.
   Comparing the deployed tags against the submodule SHAs turns "the remote pass tested
   this change" from an assumption into a checked fact.
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
    ap.add_argument("--backend-sha", default="")
    ap.add_argument("--frontend-sha", default="")
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
    for name, sha, repo in (("deployed_backend_image", args.backend_sha, "chatbot-backend"),
                            ("deployed_frontend_image", args.frontend_sha, "frontend")):
        if not sha:
            continue
        ref = out.get(name) or ""
        tag = ref.rsplit(":", 1)[-1] if ":" in ref else ""
        if not tag:
            problems.append(f"{name}: {ref!r} carries no tag, so what is running cannot be "
                            f"identified")
        elif not sha.startswith(tag):
            problems.append(
                f"{name}: the environment is running {tag!r} but {repo} is at "
                f"{sha[:12]!r}. The remote pass would assert code this run did not verify "
                f"locally.")

    for p in problems:
        print(f"infra-crosscheck: {p}", file=sys.stderr)
    if problems:
        return 1
    print(f"infra-crosscheck: prefix {norm(promised)} agrees with the contract and with "
          f"smoke; deployed images match the submodule SHAs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
