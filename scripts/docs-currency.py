#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Docs move with the code: one assertion per slice repo, owned by that repo.

  docs-currency.py --repos "chatbot-backend frontend" --json out.json

Per repo: the files changed on HEAD since its merge-base with origin/main. Code changed and
no doc did = a failed assertion. Docs = README.md at any depth, CLAUDE.md, docs/**.
contracts/ (the vendored copy) counts as neither. No changes = not a failure.

The JSON is smoke.json's shape (steps, failures, owners_failing), so verify.sh counts it
and failure-brief.py routes it the way it routes a failing smoke step. docs/adr/0019.

Exit 0 = every repo passed. 1 = a repo moved code without docs. 2 = refused: a repo with
no origin/main to compare against, which never passes silently (docs/adr/0003).
"""
from __future__ import annotations

import argparse
import json
import subprocess

SUITE = "docs-currency"


def is_doc(path: str) -> bool:
    return path == "CLAUDE.md" or path.startswith("docs/") or path.rsplit("/", 1)[-1] == "README.md"


def git(repo: str, *args: str) -> tuple[int, str]:
    p = subprocess.run(("git", "-C", repo, *args), capture_output=True, text=True)
    return p.returncode, p.stdout.strip()


def check(repo: str) -> dict:
    rc, base = git(repo, "merge-base", "HEAD", "origin/main")
    if rc != 0 or not base:
        return {"refused": f"{repo}: no merge-base with origin/main — fetch it; "
                           f"docs currency cannot be judged without it"}
    rc, out = git(repo, "diff", "--name-only", f"{base}..HEAD")
    if rc != 0:
        return {"refused": f"{repo}: git diff {base[:8]}..HEAD failed"}
    changed = [p for p in out.splitlines() if p and not p.startswith("contracts/")]
    docs = [p for p in changed if is_doc(p)]
    code = [p for p in changed if not is_doc(p)]
    return {"base": base, "changed": changed, "docs": docs, "code": code,
            "ok": not code or bool(docs)}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repos", required=True, help="space-separated slice repos")
    ap.add_argument("--json", required=True)
    args = ap.parse_args()

    steps, failures, refused, unchanged = [], [], [], []
    for repo in args.repos.split():
        r = check(repo)
        if "refused" in r:
            refused.append(r["refused"])
            print(f"docs-currency: REFUSED {r['refused']}")
            continue
        if not r["changed"]:
            unchanged.append(repo)
            print(f"docs-currency: {repo}: no changes since origin/main")
            continue
        name = f"docs-currency:{repo}"
        steps.append({"name": name, "owner": repo, "ok": r["ok"], "suite": SUITE})
        if r["ok"]:
            print(f"docs-currency: ok   {name} ({len(r['code'])} code, {len(r['docs'])} doc file(s))")
            continue
        msg = (f"{len(r['code'])} code file(s) changed since origin/main and no documentation "
               f"did — update docs/architecture.md, README.md or CLAUDE.md in this branch")
        print(f"docs-currency: FAIL {name} — {msg}")
        failures.append({
            "name": name, "owner": repo, "suite": SUITE,
            "request": f"git -C {repo} diff --name-only {r['base'][:12]}..HEAD",
            "expected": "a README.md, CLAUDE.md or docs/ path among the changed files",
            "actual": {"body": "\n".join(r["code"])},
            "message": msg,
        })

    json.dump({"steps": steps, "failures": failures,
               "owners_failing": sorted({f["owner"] for f in failures}),
               "unchanged": unchanged, "refused": refused},
              open(args.json, "w"), indent=2)
    return 2 if refused else (1 if failures else 0)


if __name__ == "__main__":
    raise SystemExit(main())
