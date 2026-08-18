#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6"]
# ///
"""Read changes/NNNN-*/change.yaml and answer questions about it.

The shell scripts need structured answers — which repos have slices, does this change
want an infra deploy — and grepping prose for them is how fanout.sh ended up warning
about a missing freeze SHA whenever BRIEF.md happened to contain any hex string. ADR 0001
chose a machine-readable artifact over prose for exactly this reason; the manifest is the
same idea applied to the change itself.

  manifest.py <change-dir> --shell            eval-able assignments for bash
  manifest.py <change-dir> --get deploy.infra dotted lookup, one value on stdout
  manifest.py <change-dir> --validate         schema check only, exit 1 on problems
"""
from __future__ import annotations

import argparse
import os
import shlex
import sys

import yaml

REPOS = ("chatbot-backend", "frontend", "infra")


def fail(msg: str) -> None:
    print(f"manifest: {msg}", file=sys.stderr)
    raise SystemExit(1)


def load(change_dir: str) -> dict:
    path = os.path.join(change_dir, "change.yaml")
    if not os.path.exists(path):
        fail(f"{path} not found — run ./scripts/new-change.sh, or add a manifest to an "
             f"older change directory")
    doc = yaml.safe_load(open(path)) or {}
    if not isinstance(doc, dict):
        fail(f"{path} is not a mapping")
    return doc


def validate(doc: dict, change_dir: str) -> list[str]:
    problems: list[str] = []
    slices = doc.get("slices") or []
    if not slices:
        problems.append("slices: is empty — nothing would be dispatched")
    for repo in slices:
        if repo not in REPOS:
            problems.append(f"slices: unknown repo {repo!r} (expected one of {', '.join(REPOS)})")
        elif not os.path.exists(os.path.join(change_dir, f"{repo}.md")):
            problems.append(f"slices names {repo} but {change_dir}/{repo}.md does not exist")

    # The mismatch that silently dropped work before: instructions said backend.md, the
    # dispatcher looked for chatbot-backend.md, and `[ -f ... ] || continue` swallowed it.
    for entry in sorted(os.listdir(change_dir)):
        if not entry.endswith(".md") or entry in ("BRIEF.md", "STATUS.md"):
            continue
        repo = entry[:-3]
        if repo not in slices:
            hint = ""
            if repo == "backend":
                hint = " — did you mean chatbot-backend.md? (that is the submodule path)"
            problems.append(f"{entry} exists but is not listed in slices:{hint}")

    deploy = doc.get("deploy") or {}
    if deploy.get("infra") and "infra" not in slices:
        problems.append("deploy.infra is true but there is no infra slice")

    smoke = doc.get("smoke") or {}
    smoke_file = smoke.get("file")
    if smoke_file and not os.path.exists(os.path.join(change_dir, smoke_file)):
        problems.append(f"smoke.file names {smoke_file} but it does not exist in {change_dir}")
    return problems


def dig(doc: dict, path: str):
    cur = doc
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("change_dir")
    ap.add_argument("--shell", action="store_true")
    ap.add_argument("--get")
    ap.add_argument("--validate", action="store_true")
    args = ap.parse_args()

    change_dir = args.change_dir.rstrip("/")
    if not os.path.isdir(change_dir):
        fail(f"no such change directory: {change_dir}")
    doc = load(change_dir)

    if args.validate or args.shell:
        problems = validate(doc, change_dir)
        if problems:
            for p in problems:
                print(f"manifest: {p}", file=sys.stderr)
            if args.validate:
                return 1
            # --shell still emits, so callers can report the change name in their error
            print("MANIFEST_OK=0")
        elif args.shell:
            print("MANIFEST_OK=1")
        if args.validate:
            print(f"manifest: {os.path.join(change_dir, 'change.yaml')} is valid")
            return 0

    if args.get:
        value = dig(doc, args.get)
        if value is None:
            return 1
        if isinstance(value, bool):
            print("true" if value else "false")
        elif isinstance(value, list):
            print(" ".join(str(v) for v in value))
        else:
            print(value)
        return 0

    if args.shell:
        deploy = doc.get("deploy") or {}
        smoke = doc.get("smoke") or {}
        out = {
            "CHANGE_NAME": doc.get("change") or os.path.basename(change_dir),
            "CHANGE_SLICES": " ".join(doc.get("slices") or []),
            "CHANGE_FREEZE_SHA": doc.get("freeze_sha") or "",
            "CHANGE_DEPLOY_LOCAL": "1" if deploy.get("local", True) else "0",
            "CHANGE_DEPLOY_INFRA": "1" if deploy.get("infra") else "0",
            "CHANGE_SMOKE_FILE": smoke.get("file") or "smoke.yaml",
            "CHANGE_SMOKE_BASE": smoke.get("base") or "http://localhost:8080",
            "CHANGE_SMOKE_TIMEOUT": str(smoke.get("timeout_s") or 120),
        }
        for k, v in out.items():
            print(f"{k}={shlex.quote(str(v))}")
        return 0

    yaml.safe_dump(doc, sys.stdout, sort_keys=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
