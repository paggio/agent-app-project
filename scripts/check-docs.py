#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6"]
# ///
"""Seven checks that each map to a documentation defect that actually happened.

  ./scripts/check-docs.py [--warnings-are-errors]

The repo's doctrine is that prose is advisory and only mechanisms are deterministic
(docs/init/README.md § "Where each new document goes"). That applies to the repo's own
prose too: `freeze-contract` told agents to record the freeze SHA in BRIEF.md for weeks
after docs/adr/0002 removed that mechanism, README.md taught "three independently green
PRs" as the definition of done that CLAUDE.md explicitly contradicts, and CLAUDE.md stated
a stack/dev.env rule that the baseline suite itself broke.

None of that is caught by a test suite, because none of it is code. Six greps and a
byte-comparison are, and every one of them fails with a message naming the file and the
fix. Deliberately NOT a doc-linting framework: each check exists because of a specific
defect, and a check that cannot name the defect it prevents does not belong here.
"""
from __future__ import annotations

import argparse
import glob
import os
import re
import subprocess
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUBMODULES = ("chatbot-backend", "frontend", "infra")

problems: list[str] = []
warnings: list[str] = []


def fail(check: str, msg: str) -> None:
    problems.append(f"[{check}] {msg}")


def warn(check: str, msg: str) -> None:
    warnings.append(f"[{check}] {msg}")


def prose_files() -> list[str]:
    out = []
    for pat in (".claude/**/*.md", "docs/**/*.md", "CLAUDE.md", "README.md",
                "contracts/README.md"):
        out += glob.glob(os.path.join(ROOT, pat), recursive=True)
    return sorted(set(out))


def rel(p: str) -> str:
    return os.path.relpath(p, ROOT)


# --- 1. the freeze SHA lives in change.yaml, and nowhere else ------------------------
# `freeze-contract` said "record its SHA in the change's BRIEF.md" long after ADR 0002
# removed that mechanism, because the old check was a grep for hex that any stray string
# satisfied. Nothing reads BRIEF.md for it; manifest.py reads change.yaml and only that.
def check_freeze_sha_home() -> None:
    pat = re.compile(r"BRIEF\.md")
    sha_words = re.compile(r"\b(sha|freeze_sha|freeze point|frozen)\b", re.I)
    for path in prose_files():
        for n, line in enumerate(open(path), 1):
            if pat.search(line) and sha_words.search(line):
                # A line that explicitly says BRIEF.md is NOT where it goes is the fix,
                # not the defect.
                if re.search(r"\b(not|never|nowhere|removed|no longer)\b", line, re.I):
                    continue
                fail("freeze-sha-home",
                     f"{rel(path)}:{n} ties BRIEF.md to the freeze SHA. It goes in "
                     f"change.yaml as freeze_sha — nothing reads BRIEF.md for it.")


# --- 2. every suite variable is declared -------------------------------------------
# CLAUDE.md says "never export a smoke variable by hand — declare it in stack/dev.env",
# and BACKEND_DIRECT_BASE was hand-exported by the Makefile, in the BASELINE suite, which
# every change runs. A rule the baseline breaks is a rule agents learn to ignore. This
# also catches "you added a step whose variable nobody supplies" at commit time rather
# than mid-run.
HARNESS_VARS = {"SMOKE_ORIGIN", "SMOKE_RUN_ID", "BACKEND_DIRECT_BASE"}
VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def check_suite_vars() -> None:
    declared = set(HARNESS_VARS)
    dev_env = os.path.join(ROOT, "stack", "dev.env")
    try:
        for line in open(dev_env):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                declared.add(line.split("=", 1)[0].strip())
    except OSError:
        fail("suite-vars", "stack/dev.env is missing; it is the declared source for "
                           "every variable a suite interpolates")
        return

    suites = glob.glob(os.path.join(ROOT, "smoke", "*.yaml")) \
        + glob.glob(os.path.join(ROOT, "changes", "*", "smoke.yaml"))
    for path in sorted(suites):
        doc = yaml.safe_load(open(path)) or {}
        captured: set[str] = set()
        for step in doc.get("steps") or []:
            step = step or {}
            blob = yaml.safe_dump(step)
            for name in VAR.findall(blob):
                if name.startswith("INFRA_") or name in captured or name in declared:
                    continue
                fail("suite-vars",
                     f"{rel(path)}: ${{{name}}} is used by step "
                     f"{step.get('name', '?')!r} but is not declared in stack/dev.env")
            captured |= set((step.get("capture") or {}).keys())


# --- 3. the step schema is documented where suite authors look -----------------------
# `contract: false` was used by four steps and documented only inside align-contract's
# SKILL.md. A suite author should not have to load a contract skill to learn a field name.
def check_step_schema_documented() -> None:
    template = os.path.join(ROOT, "changes", "0000-example-change", "smoke.yaml")
    try:
        text = open(template).read()
    except OSError:
        fail("step-schema", "the change template's smoke.yaml is missing")
        return
    header = text.split("steps:")[0]

    smoke = os.path.join(ROOT, "scripts", "smoke.py")
    src = open(smoke).read()
    m = re.search(r"STEP_KEYS\s*=\s*\{(.*?)\}", src, re.S)
    if not m:
        fail("step-schema", "could not find STEP_KEYS in scripts/smoke.py — this check "
                            "needs it as the authority on the vocabulary")
        return
    keys = set(re.findall(r"\"([a-z_]+)\"", m.group(1))) - {"_suite"}
    for key in sorted(keys):
        if not re.search(rf"\b{re.escape(key)}\b", header):
            fail("step-schema",
                 f"step key {key!r} is accepted by smoke.py but not documented in the "
                 f"step-shape comment in {rel(template)}")


# --- 4. "three green PRs" is not the definition of done ------------------------------
# README.md taught it as step 4 while CLAUDE.md said it was not shipped. It was the first
# thing any reader saw, and it is the definition ADR 0002 exists to reject.
BANNED = (r"three\s+(independently\s+)?green\s+PRs",)


def check_banned_phrases() -> None:
    for path in prose_files():
        for n, line in enumerate(open(path), 1):
            for pat in BANNED:
                if re.search(pat, line, re.I):
                    # A line that negates it is the correction, not the defect.
                    if re.search(r"\b(not|never|isn't|is not|rather than)\b", line, re.I):
                        continue
                    fail("banned-phrase",
                         f"{rel(path)}:{n} presents three green PRs as done. Shipped means "
                         f"deployed together with the suite passing — see docs/adr/0002.")


# --- 5. CLAUDE.md stays inside its own stated budget ---------------------------------
# docs/init/README.md sets 40-60 lines and says: if the agent repeatedly violates a rule,
# the file is too long — shorten before adding emphasis. It had drifted to 76.
def check_claude_md_size() -> None:
    path = os.path.join(ROOT, "CLAUDE.md")
    n = sum(1 for _ in open(path))
    if n > 60:
        fail("claude-md-size",
             f"CLAUDE.md is {n} lines; the budget in docs/init/README.md is 40-60. "
             f"Move detail into a skill or docs/ — shorten before adding emphasis.")


# --- 6. no dead wiring, in either direction -----------------------------------------
# .claude/agents/contract-conformance.md said "use after any slice completes" and was
# referenced by nothing executable, while smoke.py's docstring pointed at it. A doc that
# names a gate nobody runs is worse than no doc: someone runs it and believes it.
def check_dead_wiring() -> None:
    text_by_file = {p: open(p).read() for p in prose_files()}
    all_prose = "\n".join(text_by_file.values())

    for path, text in text_by_file.items():
        for script in set(re.findall(r"scripts/[a-z0-9-]+\.(?:sh|py)", text)):
            if not os.path.exists(os.path.join(ROOT, script)):
                fail("dead-wiring", f"{rel(path)} references {script}, which does not exist")
        for adr in set(re.findall(r"docs/adr/(\d{4})", text)):
            if not glob.glob(os.path.join(ROOT, "docs", "adr", f"{adr}-*.md")):
                fail("dead-wiring", f"{rel(path)} references docs/adr/{adr}, which does not exist")

    # The other direction: a skill nothing routes to will never be loaded.
    for skill_dir in sorted(glob.glob(os.path.join(ROOT, ".claude", "skills", "*"))):
        name = os.path.basename(skill_dir)
        others = "\n".join(t for p, t in text_by_file.items()
                           if os.path.basename(os.path.dirname(p)) != name)
        if name not in others:
            fail("dead-wiring",
                 f"skill {name!r} is referenced by nothing — route to it from CLAUDE.md's "
                 f"lane table, or delete it")

    for agent in sorted(glob.glob(os.path.join(ROOT, ".claude", "agents", "*.md"))):
        name = os.path.basename(agent)[:-3]
        if not re.search(rf"\b{re.escape(name)}\b", all_prose) and \
           not _referenced_in_scripts(name):
            fail("dead-wiring",
                 f"agent {name!r} is dispatched by nothing and referenced by nothing. An "
                 f"agent that claims to be a gate but is never run produces confidence "
                 f"without enforcement — wire it or delete it")


def _referenced_in_scripts(needle: str) -> bool:
    for p in glob.glob(os.path.join(ROOT, "scripts", "*")):
        try:
            if needle in open(p, errors="replace").read():
                return True
        except OSError:
            pass
    return False


# --- 7. the vendored contracts match this repo --------------------------------------
# Each sub-repo's contracts/README.md claims CI enforces that these files match the
# control repo at the pinned SHA. That step is commented out in all three, and there is no
# sync step at all: `git log -- contracts/` shows the files arriving in a scaffold commit
# and being updated inside a FEATURE commit, i.e. copied by hand by a dispatched agent —
# which the vendored README forbids. This is the right home for the check because the
# control repo is the only place all four trees are already present, so it needs no
# network and does not invert the dependency direction docs/adr/0001 protects.
def check_vendored_contracts() -> None:
    for sub in SUBMODULES:
        sub_dir = os.path.join(ROOT, sub, "contracts")
        if not os.path.isdir(sub_dir):
            continue
        for name in ("openapi.yaml", "infra-outputs.yaml"):
            ours = os.path.join(ROOT, "contracts", name)
            theirs = os.path.join(sub_dir, name)
            if not os.path.exists(theirs):
                continue
            if open(ours, "rb").read() != open(theirs, "rb").read():
                fail("vendored-contracts",
                     f"{sub}/contracts/{name} differs from contracts/{name}. The sub-repo "
                     f"verifies its implementation against its copy, so a stale copy means "
                     f"its CI is green against the wrong promise.")

        # The normative prose is a known, tracked divergence rather than a surprise.
        theirs = os.path.join(sub_dir, "README.md")
        ours = os.path.join(ROOT, "contracts", "README.md")
        if os.path.exists(theirs) and \
                open(ours, "rb").read() != open(theirs, "rb").read():
            warn("vendored-contracts",
                 f"{sub}/contracts/README.md is the short vendored notice, not this repo's "
                 f"103-line normative copy. Eleven places in chatbot-backend cite it as "
                 f"authority — including a section that does not exist in the vendored "
                 f"file. Fixing it is sub-repo work (a slice or a session inside the "
                 f"repo); this repo cannot write there.")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--warnings-are-errors", action="store_true")
    args = ap.parse_args()

    for fn in (check_freeze_sha_home, check_suite_vars, check_step_schema_documented,
               check_banned_phrases, check_claude_md_size, check_dead_wiring,
               check_vendored_contracts):
        try:
            fn()
        except Exception as exc:  # a broken check must not read as a clean repo
            fail(fn.__name__, f"the check itself failed: {exc!r}")

    for w in warnings:
        print(f"check-docs: warning — {w}", file=sys.stderr)
    for p in problems:
        print(f"check-docs: {p}", file=sys.stderr)

    if problems or (warnings and args.warnings_are_errors):
        return 1
    print(f"check-docs: 7 checks passed"
          + (f" ({len(warnings)} warning(s))" if warnings else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
