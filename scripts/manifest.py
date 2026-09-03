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
  manifest.py <change-dir> --jobs             one TSV line per one-shot job
  manifest.py <change-dir> --validate         the ship gate; exit 2 on problems

--validate is the ONE gate that decides whether a change is shippable. It used to check
change.yaml only, and .claude/commands/ship.md carried six more preconditions as prose for
a reader to verify by hand — the freeze SHA and its reachability, a clean contracts/ tree,
filled-in criteria, a smoke file with steps, every step owned. Prose cannot fail a build
(docs/adr/0001), and five of the six are mechanical, so they live here now. The step schema
itself belongs to smoke.py, which owns step semantics; this shells out to `smoke.py --lint`
rather than keeping a second copy of the key list to drift.

Exit 2, not 1: a change that cannot be validated is the harness refusing to judge, not the
thing under test failing. See docs/adr/0003.
"""
from __future__ import annotations

import argparse
import os
import shlex
import subprocess
import sys

import yaml

REPOS = ("chatbot-backend", "chatbot-eval", "frontend", "infra")

# Environments iterate.sh and verify.sh may deploy to. `prod` is deliberately absent:
# adding it is a reviewed commit in this repo, not a change author's decision, and an
# agent-driven self-repairing loop is not the tool for a production deploy. The real
# guarantee is credentials — see docs/adr/0004.
ENVIRONMENTS = ("staging",)

HERE = os.path.dirname(os.path.abspath(__file__))


def fail(msg: str) -> None:
    # Exit 2, not 1: this is the harness refusing to judge, not the change failing. Callers
    # route on the difference — iterate.sh reads 1 as "slices failed" and carries on.
    print(f"manifest: {msg}", file=sys.stderr)
    raise SystemExit(2)


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
            if repo in ("backend", "eval"):
                hint = (f" — did you mean chatbot-{repo}.md? (that is the submodule path; "
                        f"'{repo}' is the compose SERVICE name, which is a different thing)")
            problems.append(f"{entry} exists but is not listed in slices:{hint}")

    problems += validate_freeze(doc)
    problems += validate_deploy(doc, slices)
    problems += validate_prose(change_dir)
    problems += validate_smoke(doc, change_dir, slices)
    problems += validate_jobs(doc, slices)
    return problems


def git(*args: str) -> tuple[int, str]:
    p = subprocess.run(("git",) + args, capture_output=True, text=True)
    return p.returncode, p.stdout.strip()


def validate_freeze(doc: dict) -> list[str]:
    """The freeze SHA, and the tree it names.

    These three checks used to live in fanout.sh, which meant they only ran on the dispatch
    path — and iterate.sh swallowed fanout's exit code, so a change with no freeze SHA got
    deployed and smoked anyway and reported `verified`. One gate, three callers.
    """
    problems: list[str] = []
    sha = doc.get("freeze_sha") or ""
    if not sha:
        return ['freeze_sha: is empty — freeze the contract first: edit contracts/, commit '
                'it ALONE with nothing else in the diff, and record that commit here. '
                'contracts/README.md section "Changing a contract" is the normative version']

    rc, kind = git("cat-file", "-t", sha)
    if rc != 0 or kind != "commit":
        problems.append(
            f"freeze_sha: {sha[:8]} is not a commit in this repo — record the commit that "
            f"landed contracts/, not a branch name or a short hash from another clone")
        return problems

    rc, _ = git("merge-base", "--is-ancestor", sha, "HEAD")
    if rc != 0:
        problems.append(
            f"freeze_sha: {sha[:8]} is not an ancestor of HEAD — the slices would build "
            f"against a contract this branch does not have; merge or rebase, then re-record")

    # The gate presented as "it exits 0 or names what to fix" never PARSED the artifact it
    # gates. A real YAML error in openapi.yaml — an unquoted `: ` inside a description is
    # enough — passed validation and detonated later, inside a dispatched session or at
    # smoke.py --contract, after the dispatch had been paid for.
    for name in ("openapi.yaml", "infra-outputs.yaml"):
        path = os.path.join(HERE, os.pardir, "contracts", name)
        if not os.path.exists(path):
            continue
        try:
            doc = yaml.safe_load(open(path))
        except yaml.YAMLError as exc:
            where = ""
            mark = getattr(exc, "problem_mark", None)
            if mark is not None:
                where = f" at line {mark.line + 1}, column {mark.column + 1}"
            problems.append(f"contracts/{name} is not valid YAML{where} — a malformed "
                            f"freeze passes every other check here and fails inside a "
                            f"dispatched session instead: {getattr(exc, 'problem', exc)}")
            continue
        if not isinstance(doc, dict) or not doc:
            problems.append(f"contracts/{name} parsed to {type(doc).__name__}, not a "
                            f"mapping — it is not a usable spec")

    rc, dirty = git("status", "--porcelain", "--", "contracts/")
    if rc == 0 and dirty:
        # git() strips its output, so the leading space of " M contracts/x" is already
        # gone and a fixed line[3:] ate the first character of the path.
        names = ", ".join(sorted(line.split(maxsplit=1)[-1]
                                 for line in dirty.splitlines())[:4])
        problems.append(
            f"contracts/ has uncommitted changes ({len(dirty.splitlines())} file(s): {names}) "
            f"— the freeze is a commit, so commit or stash them before dispatching")
    return problems


def validate_deploy(doc: dict, slices: list) -> list[str]:
    """The deploy flags, strictly typed.

    `deploy.get("local", True)` treated a present-but-empty `local:` key as false, because
    it parses as None. That skipped the deploy stage AND the smoke stage and still reported
    PASS. The mirror case is worse: the string "false" is truthy, so `infra: "false"` would
    have enabled a real deploy.
    """
    problems: list[str] = []
    deploy = doc.get("deploy") or {}

    for key, default in (("local", True), ("infra", False)):
        if key not in deploy:
            continue
        value = deploy[key]
        if value is not True and value is not False:
            problems.append(
                f"deploy.{key}: must be true or false, got {value!r} — "
                + ("a null or quoted value silently disables the deploy stage AND the "
                   "smoke stage" if key == "local"
                   else "the string \"false\" is truthy and would enable a real deploy"))

    local = deploy.get("local", True) is True
    infra = deploy.get("infra", False) is True

    if local is False and infra is False and not problems:
        problems.append(
            "deploy.local: false and deploy.infra: false — this change would deploy "
            "nothing and assert nothing; set one of them")

    if infra and "infra" not in slices:
        problems.append("deploy.infra is true but there is no infra slice")

    env = deploy.get("environment")
    if infra and not env:
        problems.append(
            "deploy.infra is true but deploy.environment names no environment — "
            f"choose one of: {', '.join(ENVIRONMENTS)}")
    if env and env not in ENVIRONMENTS:
        problems.append(
            f"deploy.environment: {env!r} is not a deployable environment "
            f"(allowed: {', '.join(ENVIRONMENTS)}). Adding one is a reviewed commit in "
            f"this repo, not a change author's decision — see docs/adr/0004")
    if env and not infra:
        problems.append(
            f"deploy.environment names {env!r} but deploy.infra is false — nothing would "
            f"be deployed there and the remote pass would never run")
    return problems


PLACEHOLDERS = ("<link>", "<slug>", "<placeholder>", "<what", "<why", "<one paragraph>",
                "EXAMPLE / TEMPLATE")


def validate_prose(change_dir: str) -> list[str]:
    """Prose still full of template placeholders has not been written yet.

    STATUS.md is checked as well as BRIEF.md. It was not, and that is why 0001-auth carried
    an "EXAMPLE / TEMPLATE" banner and a `<link>` PR column directly above a block saying
    the change was verified.
    """
    problems = []
    path = os.path.join(change_dir, "BRIEF.md")
    if not os.path.exists(path):
        problems.append(f"BRIEF.md does not exist in {change_dir} — the slices are "
                        f"dispatched with a pointer to it")

    for name in ("BRIEF.md", "STATUS.md"):
        path = os.path.join(change_dir, name)
        if not os.path.exists(path):
            continue
        hits = []
        for n, line in enumerate(open(path), 1):
            for token in PLACEHOLDERS:
                if token in line:
                    hits.append(f"{token} on line {n}")
                    break
        if hits:
            shown = ", ".join(hits[:3]) + (f", and {len(hits) - 3} more" if len(hits) > 3 else "")
            problems.append(f"{name} still contains template placeholders ({shown}) — "
                            f"fill it in before dispatching")
    return problems


def validate_smoke(doc: dict, change_dir: str, slices: list) -> list[str]:
    """The suite, its owners, and the coverage of every slice.

    ship.md asked a reader to check "at least one step, and every step has an owner". The
    coverage rule is the one that matters most and nobody could check by eye: a slice with
    no owned step is dispatched, deployed, and reported verified with nothing asserted
    about it.
    """
    problems: list[str] = []
    smoke = doc.get("smoke") or {}
    name = smoke.get("file") or "smoke.yaml"
    path = os.path.join(change_dir, name)

    if not os.path.exists(path):
        return [f"{name} does not exist in {change_dir} — write the acceptance criteria as "
                f"steps (see changes/0000-example-change/smoke.yaml for the step shape)"]

    doc_s = yaml.safe_load(open(path)) or {}
    steps = doc_s.get("steps") or []
    if not steps:
        return [f"{name} declares no steps — a change with acceptance criteria and no steps "
                f"is a change nobody checks. Write one step per criterion in BRIEF.md, each "
                f"with an owner."]

    owned: set[str] = set()
    for i, step in enumerate(steps, 1):
        step = step or {}
        label = f"{name} step {i}" + (f" ({step.get('name')!r})" if step.get("name") else "")
        owner = step.get("owner")
        if not owner:
            problems.append(
                f"{label}: no owner — owner routes the repair to one repo; set it to one "
                f"of: {', '.join(slices)}")
            continue
        owned.add(owner)
        if owner not in slices:
            hint = (f" — did you mean chatbot-{owner}? (that is the submodule path; "
                    f"'{owner}' is the compose service name)"
                    if owner in ("backend", "eval") else "")
            problems.append(
                f"{label}: owner {owner!r} is not a slice of this change "
                f"(slices: {', '.join(slices)}){hint}")

    for repo in slices:
        if repo not in owned:
            problems.append(
                f"slices names {repo} but no step in {name} has owner: {repo} — {repo} "
                f"would be dispatched, deployed and reported verified with nothing "
                f"asserted about it. Add at least one step it is answerable for.")

    # The step schema belongs to smoke.py. Delegated, not duplicated.
    lint = os.path.join(HERE, "smoke.py")
    p = subprocess.run([lint, "--lint", path], capture_output=True, text=True)
    if p.returncode != 0:
        problems += [line.replace("smoke: ", "", 1) if line.startswith("smoke: ") else line
                     for line in p.stderr.strip().splitlines() if line.strip()]
    return problems


# A job's `service` must be a service stack/compose.yml declares. That file is also where
# the agentapp.owner label lives, so the two facts a failing job needs — how to start it and
# who is answerable — are declared in one place. A typo would otherwise surface as compose's
# "no such service", mid-run, with no owner.
def stack_services() -> set[str]:
    path = os.path.join(HERE, os.pardir, "stack", "compose.yml")
    try:
        doc = yaml.safe_load(open(path)) or {}
    except (OSError, yaml.YAMLError):
        return set()
    return set((doc.get("services") or {}))


def validate_jobs(doc: dict, slices: list) -> list[str]:
    """One-shot containers the loop runs inside the joined stack, and their exit codes.

    A job exists for a criterion whose oracle is a PROCESS rather than a request: the eval
    run of 0006 produces its evidence by running, and "it exits non-zero when a threshold
    is breached" is not a thing any HTTP client can ask. See docs/adr/0014.

    Typed as strictly as deploy.* is, and for the reason docs/adr/0003 gives: a job whose
    `expect_exit` parses as None would compare against nothing, and a stage that cannot
    fail is the whole class of defect this harness was rebuilt to remove.
    """
    problems: list[str] = []
    if "jobs" not in doc:
        return problems

    jobs = doc["jobs"]
    if jobs is None:
        return ["jobs: is present but empty. Delete the key, or write `jobs: []` — a null "
                "parses as falsy and would skip the stage silently, which is the shape "
                "docs/adr/0003 forbids"]
    if not isinstance(jobs, list):
        return [f"jobs: must be a list, got {type(jobs).__name__}"]

    services = stack_services()
    seen: set[str] = set()
    for i, job in enumerate(jobs, 1):
        if not isinstance(job, dict):
            problems.append(f"jobs[{i}]: must be a mapping, got {type(job).__name__}")
            continue
        name = job.get("name")
        label = f"jobs[{i}]" + (f" ({name!r})" if name else "")
        if not name or not isinstance(name, str):
            problems.append(f"{label}: no name — it names the log file and the failing "
                            f"stage a reader is sent to")
        elif name in seen:
            problems.append(f"{label}: duplicate name — two jobs would write one log")
        else:
            seen.add(name)

        service = job.get("service")
        if not service or not isinstance(service, str):
            problems.append(f"{label}: no service — a job is a one-shot run of a service "
                            f"in the joined stack")
        elif services and service not in services:
            problems.append(
                f"{label}: service {service!r} is not declared in stack/compose.yml "
                f"(declared: {', '.join(sorted(services))}). Declare it there — that is "
                f"also where its agentapp.owner label goes, so a failure is attributable")

        owner = job.get("owner")
        if not owner:
            problems.append(f"{label}: no owner — owner routes the repair to one repo, "
                            f"exactly as it does for a smoke step; set it to one of: "
                            f"{', '.join(slices)}")
        elif owner not in slices:
            problems.append(f"{label}: owner {owner!r} is not a slice of this change "
                            f"(slices: {', '.join(slices)})")

        code = job.get("expect_exit", 0)
        if code is True or code is False or not isinstance(code, int):
            problems.append(f"{label}: expect_exit must be an integer, got {code!r} — a "
                            f"null or quoted value compares against nothing")
        elif not 0 <= code <= 125:
            problems.append(f"{label}: expect_exit {code} is outside 0-125; 126 and above "
                            f"are the shell's own codes and cannot be a claim about the job")

        timeout = job.get("timeout_s", 900)
        if timeout is True or timeout is False or not isinstance(timeout, int) or timeout <= 0:
            problems.append(f"{label}: timeout_s must be a positive integer, got {timeout!r}")

        env = job.get("env") or {}
        if not isinstance(env, dict):
            problems.append(f"{label}: env must be a mapping, got {type(env).__name__}")
        else:
            for k, v in env.items():
                if not isinstance(k, str) or not k.replace("_", "").isalnum():
                    problems.append(f"{label}: env key {k!r} is not a variable name")
                text = "" if v is None else str(v)
                # Passed to the runner as one whitespace-separated K=V field, so a value
                # with a space in it would split into two. Refused rather than quoted:
                # a job env is a threshold or a switch, and one that needs a space wants
                # a compose file entry instead.
                if text != text.strip() or any(c.isspace() for c in text):
                    problems.append(f"{label}: env {k} has whitespace in its value; the "
                                    f"runner passes these as space-separated K=V pairs")

    if jobs and doc.get("deploy", {}).get("local", True) is not True:
        problems.append("jobs are declared but deploy.local is not true — a job runs inside "
                        "the joined local stack, so there would be nothing to run it in")
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
    ap.add_argument("--jobs", action="store_true")
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
                return 2
            # --shell still emits, so callers can report the change name in their error
            print("MANIFEST_OK=0")
        elif args.shell:
            print("MANIFEST_OK=1")
        if args.validate:
            print(f"manifest: {os.path.join(change_dir, 'change.yaml')} is valid")
            return 0

    if args.jobs:
        # TSV, like fanout.sh's results: shell reads it with `while IFS=$\'\\t\' read`.
        # Validation forbids whitespace inside an env value, so the last field is safely
        # space-separated.
        for job in doc.get("jobs") or []:
            env = " ".join(f"{k}={'' if v is None else v}"
                           for k, v in (job.get("env") or {}).items())
            print("\t".join((str(job.get("name") or ""),
                             str(job.get("service") or ""),
                             str(job.get("owner") or ""),
                             str(job.get("expect_exit", 0)),
                             str(job.get("timeout_s", 900)),
                             env)))
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
            # `is True` rather than truthiness, twice over. `local:` present but empty
            # parses as None, which is falsy — and that silently skipped BOTH the deploy
            # stage and the smoke stage while still reporting PASS. In the other
            # direction, the string "false" is truthy and would have enabled a real
            # deploy. validate() rejects both shapes outright; this is the belt to that
            # brace, because --shell runs even when nobody called --validate.
            "CHANGE_DEPLOY_LOCAL": "1" if deploy.get("local", True) is True else "0",
            "CHANGE_DEPLOY_INFRA": "1" if deploy.get("infra", False) is True else "0",
            "CHANGE_DEPLOY_ENVIRONMENT": deploy.get("environment") or "",
            "CHANGE_SMOKE_FILE": smoke.get("file") or "smoke.yaml",
            "CHANGE_SMOKE_BASE": smoke.get("base") or "http://localhost:8080",
            "CHANGE_SMOKE_TIMEOUT": str(smoke.get("timeout_s") or 120),
            "CHANGE_SMOKE_E2E": "1" if smoke.get("e2e", False) is True else "0",
            # A count rather than the jobs themselves: verify.sh reads them with --jobs.
            # It is here so the loop can record the stage as "skipped: none declared"
            # rather than leaving a silence a reader has to interpret.
            "CHANGE_JOBS_COUNT": str(len(doc.get("jobs") or [])),
        }
        for k, v in out.items():
            print(f"{k}={shlex.quote(str(v))}")
        return 0

    yaml.safe_dump(doc, sys.stdout, sort_keys=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
