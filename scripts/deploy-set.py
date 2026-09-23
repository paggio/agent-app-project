#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6"]
# ///
"""Which commit of each repo a deploy to `dev` builds. docs/adr/0018 §4.

  deploy-set.py --change <NNNN-slug> [--ref <control ref>]   the control PR of a change
  deploy-set.py --product-pr <repo>@<sha> [--ref main]       a single-repo PR
  deploy-set.py --lock [--ref <control ref>]                 the gitlinks, nothing else
      [--only <repo>] [--current <infra-outputs.json>] [--json out] [--markdown out]

WHY THIS EXISTS. Mid-change the gitlinks name the last merged `main` and the change lives
on `feat/<change>` in each slice repo (concept.md §6). A deploy that built the gitlinks
would ship last week's code under a PR that claims this week's, and every assertion after
it would be about the wrong commits. So the set is resolved from the trigger, recorded,
and posted where the reviewer reads — never inferred from what happens to be checked out.

`--only <repo>` rebuilds that repo and CARRIES every other image repo at the tag `dev`
already runs, read from `--current`. infra is never carried: it has no image, and the
apply always runs the infra commit resolved here.

Remote heads come from `git ls-remote`. DEPLOY_SET_URL_TEMPLATE (e.g.
`git@github.com-{repo}:Paggio/{repo}.git`) overrides the .gitmodules URL, and
DEPLOY_SET_KEY_TEMPLATE (e.g. `~/.ssh/{repo}`) names the key each repo is reached with —
which is how CI reaches each repo with its own read-only deploy key.

Exit 0 resolved · 2 the harness refuses: an unpushed slice branch, a gitlink that disagrees
with repos.lock, nothing deployed to carry. docs/adr/0003.
"""
from __future__ import annotations

import argparse
import configparser
import json
import os
import re
import subprocess
import sys

import yaml

REPOS = ("chatbot-backend", "chatbot-eval", "frontend", "infra")

# What each repo contributes to a deploy. publish.sh builds these and infra's `deploy`
# takes them; chatbot-eval deploys nothing yet and is recorded so the set names all four.
IMAGES = {"chatbot-backend": ["backend"], "frontend": ["frontend", "proxy"],
          "infra": [], "chatbot-eval": []}

# The output that says what `dev` runs for each image. A carried image's tag comes from
# here, and infra-crosscheck.py compares the same names after the deploy.
DEPLOYED_OUTPUT = {"backend": "deployed_backend_image", "frontend": "deployed_frontend_image",
                   "proxy": "deployed_proxy_image"}

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def refuse(msg: str) -> None:
    print(f"deploy-set: {msg}", file=sys.stderr)
    raise SystemExit(2)


def git(*args: str) -> str:
    p = subprocess.run(("git",) + args, capture_output=True, text=True, cwd=ROOT)
    if p.returncode != 0:
        refuse(f"git {' '.join(args)} failed: {p.stderr.strip()}")
    return p.stdout


def gitlinks(ref: str) -> dict[str, str]:
    out = {}
    for line in git("ls-tree", ref, "--", *REPOS).splitlines():
        mode, kind, sha, path = line.split(None, 3)
        if kind == "commit":
            out[path] = sha
    missing = [r for r in REPOS if r not in out]
    if missing:
        refuse(f"{ref} records no gitlink for {', '.join(missing)}")
    return out


def locked(ref: str) -> dict[str, str]:
    out = {}
    for line in git("show", f"{ref}:repos.lock").splitlines():
        parts = line.split()
        if len(parts) >= 2 and not line.startswith("#"):
            out[parts[0]] = parts[1]
    return out


def remote_url(repo: str) -> str:
    template = os.environ.get("DEPLOY_SET_URL_TEMPLATE")
    if template:
        return template.format(repo=repo)
    cfg = configparser.ConfigParser()
    cfg.read(os.path.join(ROOT, ".gitmodules"))
    for section in cfg.sections():
        if cfg[section].get("path") == repo:
            return cfg[section]["url"]
    refuse(f".gitmodules names no submodule at {repo}")
    return ""


def remote_head(repo: str, branch: str) -> str:
    # GIT_SSH_COMMAND outranks core.sshCommand. actions/checkout's ssh-key persists the
    # CONTROL repo's key there, ssh offers it first, GitHub accepts it, and then answers
    # "Repository not found" for every other repo — so every change-mode deploy refused.
    env = dict(os.environ)
    key = os.environ.get("DEPLOY_SET_KEY_TEMPLATE")
    if key:
        env["GIT_SSH_COMMAND"] = (f"ssh -i {os.path.expanduser(key.format(repo=repo))} "
                                  f"-o IdentitiesOnly=yes -o StrictHostKeyChecking=yes")
    p = subprocess.run(("git", "ls-remote", "--heads", remote_url(repo), branch),
                       capture_output=True, text=True, cwd=ROOT, env=env)
    if p.returncode != 0:
        refuse(f"could not reach {repo}'s remote: {p.stderr.strip()}")
    for line in p.stdout.splitlines():
        sha, name = line.split()
        if name == f"refs/heads/{branch}":
            return sha
    return ""


def main() -> int:
    ap = argparse.ArgumentParser()
    trig = ap.add_mutually_exclusive_group(required=True)
    trig.add_argument("--change")
    trig.add_argument("--product-pr", metavar="REPO@SHA")
    trig.add_argument("--lock", action="store_true")
    ap.add_argument("--ref", default="HEAD", help="the control-repo commit under test")
    ap.add_argument("--only", choices=REPOS)
    ap.add_argument("--current", help="`make -C infra outputs` of what dev runs now")
    ap.add_argument("--json", dest="json_out")
    ap.add_argument("--markdown", dest="md_out")
    args = ap.parse_args()

    ref = git("rev-parse", args.ref).strip()
    links = gitlinks(ref)

    # The lock and the gitlinks move together in one /realign commit. If they disagree,
    # "every other repo at the lock" has two answers and the deploy would pick one silently.
    lock = locked(ref)
    drift = [f"{r} (gitlink {links[r][:7]}, lock {lock.get(r, '-')[:7]})"
             for r in REPOS if lock.get(r) != links[r]]
    if drift:
        refuse(f"gitlinks and repos.lock disagree at {ref[:7]}: {', '.join(drift)}. "
               f"/realign moves both in one commit; fix that before deploying.")

    repos = {r: {"sha": links[r], "from": "gitlink"} for r in REPOS}
    trigger: dict = {"ref": ref}

    if args.change:
        trigger["change"] = args.change
        try:
            manifest = yaml.safe_load(git("show", f"{ref}:changes/{args.change}/change.yaml"))
        except yaml.YAMLError as exc:
            refuse(f"changes/{args.change}/change.yaml at {ref[:7]} is not YAML: {exc}")
        slices = (manifest or {}).get("slices") or []
        branch = f"feat/{args.change}"
        unpushed = []
        for r in slices:
            sha = remote_head(r, branch)
            if not sha:
                unpushed.append(r)
            repos[r] = {"sha": sha, "from": branch}
        if unpushed:
            refuse(f"{', '.join(unpushed)} has no {branch} on its remote. The deploy builds "
                   f"what is pushed, so push the slice branch first.")
    elif args.product_pr:
        m = re.fullmatch(r"([a-z-]+)@([0-9a-f]{40})", args.product_pr)
        if not m or m.group(1) not in REPOS:
            refuse(f"--product-pr wants <repo>@<40-char sha>, got {args.product_pr!r}")
        trigger["product_pr"] = args.product_pr
        repos[m.group(1)] = {"sha": m.group(2), "from": "pull request"}
        # Carrying the PR's own repo would deploy none of the PR's code and still report a
        # green deployed-partial about it.
        if args.only and args.only != m.group(1) and IMAGES[m.group(1)]:
            refuse(f"--only {args.only} on a {m.group(1)} PR would carry {m.group(1)} at what "
                   f"dev runs, deploying none of this PR. Use /dev-push, or "
                   f"/dev-push-{m.group(1).replace('chatbot-', '')}.")
    else:
        trigger["lock"] = True

    current = {}
    if args.current:
        try:
            current = json.load(open(args.current))
        except (OSError, json.JSONDecodeError) as exc:
            refuse(f"--current {args.current} is not readable JSON: {exc}")

    for r, entry in repos.items():
        entry["tag"] = entry["sha"][:12]
        entry["images"] = {}
        carried = args.only is not None and r != args.only and IMAGES[r]
        entry["source"] = "carried" if carried else "built"
        for image in IMAGES[r]:
            if not carried:
                entry["images"][image] = entry["tag"]
                continue
            ref_out = current.get(DEPLOYED_OUTPUT[image]) or ""
            tag = ref_out.rsplit(":", 1)[-1] if ":" in ref_out else ""
            if not tag:
                refuse(f"--only {args.only} carries {image} at what dev runs, and dev reports "
                       f"no {DEPLOYED_OUTPUT[image]}. Nothing is deployed to carry — run a "
                       f"full /dev-push first.")
            entry["images"][image] = tag
        if carried:
            # The commit is whatever built the running tag; only the tag is known here.
            entry.update(sha="", tag=next(iter(entry["images"].values())),
                         **{"from": "what dev runs"})

    doc = {"trigger": trigger, "only": args.only,
           "partial": args.only is not None, "repos": repos}
    if args.json_out:
        json.dump(doc, open(args.json_out, "w"), indent=2)

    rows = ["| repo | commit | from | images |", "| --- | --- | --- | --- |"]
    for r, e in repos.items():
        imgs = ", ".join(f"{k}:{v}" for k, v in e["images"].items()) or "—"
        rows.append(f"| {r} | `{e['tag']}` | {e['from']} ({e['source']}) | {imgs} |")
    table = "\n".join(rows)
    if args.md_out:
        open(args.md_out, "w").write(table + "\n")
    print(table)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
