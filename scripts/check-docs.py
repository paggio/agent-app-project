#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6"]
# ///
"""Every check here maps to a documentation defect that actually happened.

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
    # concept.md belongs here and was missing, which is the whole reason it drifted to 838
    # lines still teaching a superseded fanout.sh: no check ever looked at it.
    for pat in (".claude/**/*.md", "docs/**/*.md", "CLAUDE.md", "README.md",
                "concept.md", "contracts/README.md"):
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
    # changes/**/*.md was NOT scanned, so the BRIEF.md template — which carried
    # "Frozen as of <commit sha>" and is the file new-change.sh copies — was exempt from
    # the check written to prevent exactly that line. The template soliciting a defect has
    # to be in scope, or the check only catches the prose nobody copies.
    targets = prose_files() + sorted(glob.glob(os.path.join(ROOT, "changes", "*", "*.md")))
    for path in targets:
        for n, line in enumerate(open(path), 1):
            if pat.search(line) and sha_words.search(line):
                # A line that explicitly says BRIEF.md is NOT where it goes is the fix,
                # not the defect.
                if re.search(r"\b(not|never|nowhere|removed|no longer)\b", line, re.I):
                    continue
                fail("freeze-sha-home",
                     f"{rel(path)}:{n} ties BRIEF.md to the freeze SHA. It goes in "
                     f"change.yaml as freeze_sha — nothing reads BRIEF.md for it.")

    # The other shape of the same defect: a BRIEF.md that carries the SHA itself rather
    # than prose telling you to. The template did, so every scaffolded change inherited a
    # field that manifest.py then demanded be filled in — forcing the author to write the
    # forbidden second copy or rewrite the template line.
    frozen_as_of = re.compile(r"\b(frozen|freeze[sd]?)\b.{0,40}\b(as of|sha|commit)\b", re.I)
    negation = r"\b(not|never|nowhere|no longer|rather than|deliberately|nothing else)\b"
    for path in sorted(glob.glob(os.path.join(ROOT, "changes", "*", "BRIEF.md"))):
        lines = open(path).read().splitlines()
        for n, line in enumerate(lines, 1):
            # A sentence can wrap, and the negation that makes the line correct is often on
            # the next one. Judge the sentence.
            window = " ".join(lines[n - 1:n + 1])
            if frozen_as_of.search(line) and not re.search(negation, window, re.I):
                fail("freeze-sha-home",
                     f"{rel(path)}:{n} records the freeze in BRIEF.md. The SHA belongs in "
                     f"change.yaml as freeze_sha and nowhere else — a second copy is a copy "
                     f"that goes stale.")


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


# --- a gate the loop is documented to call, is called by the loop --------------------
# The generalisation of every dead guard this repo has had. DEV_ENV_DEFAULTED was consumed
# and never set; the agentapp.owner labels were read and never declared;
# harvest-contract.py --diff was cited in three files as a stage verify.sh runs and had no
# caller; and prs.sh was announced in docs/adr/0005 AND in the commit that added it as
# something iterate.sh calls on a green outcome, while iterate.sh never mentioned it. Each
# read as protection and provided none, and each was found by a person rather than a check.
# One table, asserted.
LOOP_CALLS = {
    "prs.sh": ("iterate.sh",),
    "failure-brief.py": ("iterate.sh",),
    "fanout.sh": ("iterate.sh",),
    "verify.sh": ("iterate.sh",),
    "vendor-contracts.sh": ("fanout.sh",),
    "slice-result.py": ("fanout.sh",),
    "harvest-contract.py": ("verify.sh",),
    "smoke.py": ("verify.sh",),
    "service-owner.sh": ("verify.sh",),
    "infra-outputs.py": ("verify.sh",),
    "infra-crosscheck.py": ("verify.sh",),
    "publish.sh": ("verify.sh",),
    "stack.sh": ("verify.sh",),
    "dev-env.sh": ("verify.sh", "stack.sh"),
}


def check_loop_calls() -> None:
    for script, callers in sorted(LOOP_CALLS.items()):
        if not os.path.exists(os.path.join(ROOT, "scripts", script)):
            fail("loop-calls", f"LOOP_CALLS names scripts/{script}, which does not exist")
            continue
        found = []
        for caller in callers:
            path = os.path.join(ROOT, "scripts", caller)
            try:
                if script in open(path, errors="replace").read():
                    found.append(caller)
            except OSError:
                fail("loop-calls", f"LOOP_CALLS names scripts/{caller} as a caller of "
                                   f"{script}, and it does not exist")
        if not found:
            fail("loop-calls",
                 f"scripts/{script} is documented as part of the loop but is called by none "
                 f"of {', '.join(callers)}. A gate that is described and never invoked "
                 f"produces confidence without enforcement — wire it or stop claiming it.")


def check_gate_messages() -> None:
    """A gate's failure message is the prose an agent reads under the most pressure.

    `manifest.py` said "see the freeze-contract skill" and `harvest-contract.py` said the
    same in its breaking-change advice, months after docs/adr/0005 deleted the skills.
    check_dead_wiring and check_commands both scan prose files only, so `scripts/` — the
    one surface consulted at the moment of failure — had no coverage at all.
    """
    have_cmd = {os.path.basename(p)[:-3]
                for p in glob.glob(os.path.join(ROOT, ".claude", "commands", "*.md"))}
    have_skill = {os.path.basename(p)
                  for p in glob.glob(os.path.join(ROOT, ".claude", "skills", "*"))}
    named_skill = re.compile(r"\bthe ([a-z][a-z0-9]*(?:-[a-z0-9]+)+) skill\b")

    for script in sorted(glob.glob(os.path.join(ROOT, "scripts", "*"))):
        if os.path.isdir(script):
            continue
        # This file necessarily quotes the dead references it exists to prevent, in the
        # same way checks 1 and 4 exempt a line that negates the phrase they ban.
        if os.path.basename(script) == "check-docs.py":
            continue
        try:
            text = open(script, errors="replace").read()
        except OSError:
            continue
        for n, line in enumerate(text.splitlines(), 1):
            for name in named_skill.findall(line):
                if name not in have_skill:
                    fail("gate-messages",
                         f"{rel(script)}:{n} tells the reader to see the {name!r} skill, "
                         f"which does not exist. A gate that names a missing route sends "
                         f"someone looking for a file at the worst possible moment.")
            for name in re.findall(r"`/([a-z][a-z0-9-]*)`", line):
                if name not in have_cmd:
                    fail("gate-messages",
                         f"{rel(script)}:{n} names /{name}, which does not exist in "
                         f".claude/commands/.")


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
readme_divergence: list[str] = []


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
            readme_divergence.append(sub)



# --- 8. every command named in prose exists, and every command is routed to -----------
# The mirror of check 6, for the surface that replaced the skills. A lane table naming
# `/deploy` would send a reader to nothing; a command nothing routes to is never invoked,
# and commands do not self-activate the way a skill's description does. docs/adr/0005 makes
# CLAUDE.md's lane table the load-bearing routing, so this is what holds it to that.
def check_commands() -> None:
    cmd_dir = os.path.join(ROOT, ".claude", "commands")
    have = {os.path.basename(p)[:-3]
            for p in glob.glob(os.path.join(cmd_dir, "*.md"))}

    routing = ""
    for name in ("CLAUDE.md", "README.md"):
        try:
            routing += open(os.path.join(ROOT, name)).read()
        except OSError:
            pass

    for path in prose_files():
        text = open(path).read()
        for n, line in enumerate(text.splitlines(), 1):
            for named in re.findall(r"`/([a-z][a-z0-9-]*)`", line):
                if named in have:
                    continue
                # `/api` is a URL prefix, not a command. A token this file also uses as a
                # path segment is a path; a slash command never appears as `/ship/`.
                if f"/{named}/" in text:
                    continue
                fail("commands",
                     f"{rel(path)}:{n} names /{named}, which does not exist in "
                     f".claude/commands/. Either add it or stop pointing at it.")

    # The lane table is the routing surface, and it does not have to spell a lane with a
    # leading slash: main's table named four skills as bare `freeze-contract` and the
    # regex above — which requires `/` — could not see them. So the gate that holds the
    # table to reality was blind on the default branch, which is the branch every fresh
    # session starts from. Any hyphenated bare name in the table must resolve to a command
    # or a skill that exists.
    have_skill = {os.path.basename(p)
                  for p in glob.glob(os.path.join(ROOT, ".claude", "skills", "*"))}
    lane = ""
    try:
        text = open(os.path.join(ROOT, "CLAUDE.md")).read()
        if "## Which lane am I in?" in text:
            lane = text.split("## Which lane am I in?", 1)[1].split("\n## ", 1)[0]
    except OSError:
        pass
    for n, line in enumerate(lane.splitlines(), 1):
        for named in re.findall(r"`([a-z][a-z0-9]*(?:-[a-z0-9]+)+)`", line):
            if named in have or named in have_skill:
                continue
            if "/" in named or "." in named or os.path.exists(os.path.join(ROOT, named)):
                continue
            fail("commands",
                 f"CLAUDE.md's lane table names {named!r}, which is neither a command in "
                 f".claude/commands/ nor a skill in .claude/skills/. The lane table is the "
                 f"routing an agent follows; a lane that does not exist sends it nowhere.")

    for name in sorted(have):
        if f"/{name}" not in routing:
            fail("commands",
                 f"command {name!r} is not routed to from CLAUDE.md or README.md. A command "
                 f"does not activate on its own the way a skill description does, so one "
                 f"nobody is told about is one nobody runs — route it or delete it.")


# --- 9. the scripts are not the entry point ------------------------------------------
# concept.md spent 838 lines teaching readers to run fanout.sh, in a form docs/adr/0002 had
# already replaced, because nothing held prose to the actual surface. The scripts are called
# BY the commands; a document that presents one as the way to do the work is the drift that
# produced docs/adr/0005.
INTERNAL = ("fanout.sh", "iterate.sh", "verify.sh")
ENTRY_SHAPES = (
    r"(?:^|\s)(?:just |simply |then )?run\s+`?\.?/?scripts/{s}",
    r"^\s*[-*\d.]*\s*`?\.?/scripts/{s}`?\s+<",
)


def check_scripts_are_not_the_entry_point() -> None:
    for path in prose_files():
        # The command files themselves legitimately say "run ./scripts/iterate.sh" — that is
        # what a command is for. docs/adr/ records history and may quote what was true then.
        r = rel(path)
        if r.startswith(".claude/commands/") or r.startswith("docs/adr/"):
            continue
        for n, line in enumerate(open(path), 1):
            for script in INTERNAL:
                for shape in ENTRY_SHAPES:
                    if re.search(shape.format(s=re.escape(script)), line, re.I | re.M):
                        fail("script-entry-point",
                             f"{r}:{n} presents scripts/{script} as the way to do the work. "
                             f"The lanes are /ship and /realign; the scripts are what they "
                             f"call. See docs/adr/0005.")


# --- 10. the three env layers are in the order docs/adr/0006 claims -------------------
# The joined stack ran against a real Bedrock model, and nothing in this repo said why:
# Compose resolves ${VAR} inside an include:d file against THAT file's directory .env, so
# chatbot-backend/.env was already the bottom layer by accident. docs/adr/0006 made that a
# decision and dev-env.sh implements it. These three failures are the ones no reader would
# find, and the first two silently change what the stack runs rather than breaking it.
# TOKEN is anchored at the end so AWS_SESSION_TOKEN matches and BEDROCK_MAX_TOKENS does
# not — a token count is not a token. This check caught that itself on the first run.
CREDENTIAL_SHAPED = re.compile(r"SECRET|PASSWORD|CREDENTIAL|TOKEN$|_KEY$|^AWS_ACCESS", re.I)


def _env_keys(path: str) -> set[str]:
    """Variable NAMES only. This function must never return or log a value: one of the
    files it reads holds live credentials."""
    keys: set[str] = set()
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("export "):
                    line = line[len("export "):].lstrip()
                if "=" not in line:
                    continue
                key = line.split("=", 1)[0].strip()
                if key and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
                    keys.add(key)
    except OSError:
        return keys
    return keys


def check_env_layers() -> None:
    dev_env_sh = os.path.join(ROOT, "scripts", "dev-env.sh")
    try:
        src = open(dev_env_sh).read()
    except OSError:
        fail("env-layers", "scripts/dev-env.sh is missing; it is what implements the "
                           "three-layer precedence docs/adr/0006 decided")
        return

    # (a) the wiring exists at all. An ADR describing a layer no script loads is exactly
    # the drift check 6 exists for, in the direction that reads as working.
    if "SUBMODULE_ENV_FILE" not in src or "chatbot-backend/.env" not in src:
        fail("env-layers",
             "scripts/dev-env.sh no longer reads chatbot-backend/.env. docs/adr/0006 "
             "decided it is layer 3 of the joined stack's configuration; either restore "
             "the layer or supersede that ADR.")
        return

    # (b) the allowlist stays non-secret. dev-env.sh exports into the environment of the
    # process that writes verify.json, smoke.json, container logs and repair prompts.
    m = re.search(r'^SUBMODULE_ENV_ALLOW="([^"]*)"', src, re.M)
    if not m:
        fail("env-layers",
             "scripts/dev-env.sh has no SUBMODULE_ENV_ALLOW allowlist. docs/adr/0006 "
             "requires layer 3 to be an allowlist of non-secret names, not a denylist.")
        return
    allow = m.group(1).split()
    for name in allow:
        if CREDENTIAL_SHAPED.search(name):
            fail("env-layers",
                 f"SUBMODULE_ENV_ALLOW in scripts/dev-env.sh names {name}, which is "
                 f"credential-shaped. Credentials reach the container over compose's "
                 f"env_file and must never enter a control-repo process — this repo "
                 f"writes run artifacts. See docs/adr/0006.")

    # (c) no name in both files. dev-env.sh exports the stack/dev.env value into the
    # process environment, which IS layer 1, so an overlap does not "override for the
    # stack" — it makes the submodule's value permanently unreachable. Nothing else
    # notices: the stack comes up and runs the wrong configuration.
    sub_path = os.path.join(ROOT, "chatbot-backend", ".env")
    if not os.path.exists(sub_path):
        # A fresh clone and CI have no .env, and must still pass. Nothing to compare.
        return
    overlap = sorted(_env_keys(os.path.join(ROOT, "stack", "dev.env"))
                     & _env_keys(sub_path) & set(allow))
    for name in overlap:
        fail("env-layers",
             f"{name} is declared in BOTH stack/dev.env and chatbot-backend/.env, and is "
             f"allowlisted. stack/dev.env wins by being exported into the environment, so "
             f"the submodule's value can never be reached. Remove it from stack/dev.env, "
             f"or drop it from SUBMODULE_ENV_ALLOW in scripts/dev-env.sh.")


def report_readme_divergence() -> None:
    """One line for a known, permanent divergence — not one per submodule.

    Every sub-repo carries the short vendored notice rather than this repo's normative
    copy, and no session here can change that. Three identical warnings on every
    invocation is how a reader learns to skim warnings, which then hides the actionable
    one. Said once, with what would make it actionable.
    """
    if readme_divergence:
        warn("vendored-contracts",
             f"{', '.join(readme_divergence)} carry the short vendored contracts/README.md "
             f"rather than this repo's normative copy. Known and permanent: this repo "
             f"cannot write there, so closing it means a slice in each — which is a change, "
             f"not a warning to act on today.")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--warnings-are-errors", action="store_true")
    args = ap.parse_args()

    checks = (check_freeze_sha_home, check_suite_vars, check_step_schema_documented,
              check_banned_phrases, check_claude_md_size, check_dead_wiring,
              check_vendored_contracts, check_commands,
              check_scripts_are_not_the_entry_point, check_env_layers,
              check_gate_messages, check_loop_calls, report_readme_divergence)
    for fn in checks:
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
    print(f"check-docs: {len(checks)} checks passed"
          + (f" ({len(warnings)} warning(s))" if warnings else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
