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
SUBMODULES = ("chatbot-backend", "chatbot-eval", "frontend", "infra")

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
    # retros/ was exempt from every check here, and it is the one directory written by an
    # agent and read as evidence by the next one — the exact shape of the drift that let
    # concept.md reach 838 lines teaching a superseded fanout.sh.
    for pat in (".claude/**/*.md", "docs/**/*.md", "CLAUDE.md", "README.md",
                "concept.md", "contracts/README.md", "retros/*.md"):
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


# --- a prose-dispatched gate is named by every lane that claims to run it -------------
# check_dead_wiring asks whether an agent is referenced ANYWHERE, and one mention in one
# file satisfies it. The failure that leaves open is the ordinary one: a phase is added to
# /ship, /realign is left alone, and half the lanes quietly stop being graded while both
# files still read as though they are. This is the LOOP_CALLS argument applied to a gate
# whose caller is a prompt rather than a script. What a prompt does cannot be asserted from
# here; that the instruction is present in every lane that claims it can, and its absence
# is the whole of the defect. check_lane_coverage below holds this list to the directory,
# so a lane added without an entry fails rather than going quiet. See docs/adr/0009.
AGENT_DISPATCHERS = {
    "harness-retro": (".claude/commands/ship.md",
                      ".claude/commands/ship-correct.md",
                      ".claude/commands/ship-iterate.md",
                      ".claude/commands/realign.md"),
}

# Every command in .claude/commands/ is a lane, and docs/adr/0009 says every lane ends with
# the retrospective. AGENT_DISPATCHERS is hand-kept, which is the shape of defect
# check_stack_services exists for: /ship-correct was added as a fourth lane and nothing
# would have failed if this dict had been left at three — check_agent_dispatchers would have
# reported a pass while one lane in four went ungraded. So the dict is held to the directory.
# A command that genuinely is not a lane goes in NOT_A_LANE, on purpose, with a reason.
NOT_A_LANE: dict[str, str] = {}


def check_agent_dispatchers() -> None:
    for agent, dispatchers in sorted(AGENT_DISPATCHERS.items()):
        if not os.path.exists(os.path.join(ROOT, ".claude", "agents", f"{agent}.md")):
            fail("agent-dispatchers",
                 f"AGENT_DISPATCHERS names the {agent!r} agent and "
                 f".claude/agents/{agent}.md does not exist. Add it, or drop the entry — "
                 f"a lane cannot dispatch a file that is not there.")
            continue
        for dispatcher in dispatchers:
            path = os.path.join(ROOT, dispatcher)
            try:
                text = open(path).read()
            except OSError:
                fail("agent-dispatchers",
                     f"AGENT_DISPATCHERS names {dispatcher} as a lane that dispatches "
                     f"{agent!r}, and it does not exist")
                continue
            if not re.search(rf"\b{re.escape(agent)}\b", text):
                fail("agent-dispatchers",
                     f"{dispatcher} never names the {agent!r} agent, so that lane ends "
                     f"without it. Either dispatch it in the lane's last phase, or remove "
                     f"the lane from AGENT_DISPATCHERS on purpose — a retrospective that "
                     f"runs on some lanes and not others is a blind spot with a "
                     f"green light on it.")


def check_lane_coverage() -> None:
    declared = set(AGENT_DISPATCHERS["harness-retro"])
    for path in sorted(glob.glob(os.path.join(ROOT, ".claude", "commands", "*.md"))):
        cmd = os.path.relpath(path, ROOT)
        if cmd in declared or os.path.basename(cmd)[:-3] in NOT_A_LANE:
            continue
        fail("lane-coverage",
             f"{cmd} is a command and is in neither AGENT_DISPATCHERS['harness-retro'] nor "
             f"NOT_A_LANE in scripts/check-docs.py. Every lane ends with the retrospective "
             f"(docs/adr/0009) — add it there so the dispatch is asserted, or declare with a "
             f"reason that it is not a lane. A lane nothing grades is a blind spot with a "
             f"green light on it.")
    for cmd in sorted(declared):
        if not os.path.exists(os.path.join(ROOT, cmd)):
            fail("lane-coverage",
                 f"AGENT_DISPATCHERS names {cmd}, which does not exist. "
                 f"check_agent_dispatchers reports that too; this is the same list held "
                 f"from the other side.")


def check_lane_vocabulary() -> None:
    """The set of lanes has three hand-kept copies, and two of them were wrong.

    `/ship-iterate` has told its retrospective to run `retro-evidence.sh --lane
    ship-iterate` since docs/adr/0010, and that script's case statement accepted
    `ship|realign` only — exit 2 for a correct invocation, for as long as the lane had
    existed, in the one script whose whole purpose is that the retro's facts are mechanical
    rather than re-derived. `retros/README.md`'s `lane:` vocabulary was not extended for
    that lane either; the 20260827 retrospective recorded it, and it recurred when the
    fourth lane arrived. So the directory is the source and the other two are asserted
    against it.
    """
    lanes = {os.path.basename(p)[:-3]
             for p in glob.glob(os.path.join(ROOT, ".claude", "commands", "*.md"))}
    lanes -= set(NOT_A_LANE)

    ev_path = os.path.join(ROOT, "scripts", "retro-evidence.sh")
    try:
        ev = open(ev_path).read()
    except OSError:
        fail("lane-vocabulary", "scripts/retro-evidence.sh is missing; it is what the "
                                "retrospective is told to run first")
        return
    # `\)\s*;;` on purpose: capturing the alternation alone would pass a branch rewritten
    # to `ship|…|realign) echo no; exit 2 ;;`, which refuses every lane while listing them
    # all. The accept branch has to be empty for the list to mean what this reads it as.
    m = re.search(r'case "\$LANE" in\s*\n\s*([a-z|-]+)\)\s*;;', ev)
    if not m:
        fail("lane-vocabulary",
             "could not find the `case \"$LANE\" in` accept branch in "
             "scripts/retro-evidence.sh, or its first branch is not a bare alternation "
             "list followed by `;;` — this check needs that as the accepted set")
    else:
        accepted = set(m.group(1).split("|"))
        for lane in sorted(lanes - accepted):
            fail("lane-vocabulary",
                 f"scripts/retro-evidence.sh refuses --lane {lane}, and "
                 f".claude/commands/{lane}.md tells its retrospective to pass exactly "
                 f"that. Exit 2 for a correct invocation means the retro works from the "
                 f"session it just read instead of from evidence. Add it to the case.")
        for lane in sorted(accepted - lanes):
            fail("lane-vocabulary",
                 f"scripts/retro-evidence.sh accepts --lane {lane} and there is no "
                 f".claude/commands/{lane}.md. Drop it, or the bundle names a lane that "
                 f"cannot have produced it.")

    readme = os.path.join(ROOT, "retros", "README.md")
    try:
        m = re.search(r"^lane:\s*(.+)$", open(readme).read(), re.M)
    except OSError:
        fail("lane-vocabulary", "retros/README.md is missing; it specifies the frontmatter "
                                "every retrospective is written against")
        return
    if not m:
        fail("lane-vocabulary",
             "retros/README.md's frontmatter block declares no `lane:` vocabulary. It is "
             "what a retrospective writes into every file here.")
        return
    declared = {v.strip() for v in m.group(1).split("|")}
    for lane in sorted(lanes - declared):
        fail("lane-vocabulary",
             f"retros/README.md's `lane:` vocabulary omits {lane!r}. A retrospective for "
             f"that lane writes a value the schema does not list, which is how the last "
             f"lane's file ended up outside its own spec.")
    # Both directions, like the case statement above: a lane that is deleted leaves its
    # name in the schema, and the next reader takes a vocabulary as a list of what exists.
    for lane in sorted(declared - lanes):
        fail("lane-vocabulary",
             f"retros/README.md's `lane:` vocabulary lists {lane!r} and there is no "
             f".claude/commands/{lane}.md. Drop it — a schema is read as the set of lanes "
             f"that exist.")


# The second run of a change has to be legible across changes, and the heading is the whole
# of that: 0004 and 0005 each invented `## Amended, <date> — /ship-iterate` by hand, and the
# fourth lane would have invented a fifth spelling. There is no template to hold — neither
# section exists when new-change.sh scaffolds — so the lanes are what carry it, and this is
# what keeps the two lanes from drifting apart.
STATUS_HEADINGS = {
    "ship-correct": "## Corrected, <YYYY-MM-DD> — /ship-correct",
    "ship-iterate": "## Amended, <YYYY-MM-DD> — /ship-iterate",
}


def check_status_headings() -> None:
    for lane, heading in sorted(STATUS_HEADINGS.items()):
        path = os.path.join(ROOT, ".claude", "commands", f"{lane}.md")
        if not os.path.exists(path):
            fail("status-headings",
                 f"STATUS_HEADINGS names the {lane!r} lane and "
                 f".claude/commands/{lane}.md does not exist. Drop the entry, or the "
                 f"heading has no lane to be written by.")
            continue
        if heading not in open(path).read():
            fail("status-headings",
                 f".claude/commands/{lane}.md does not spell the STATUS.md heading "
                 f"{heading!r} literally. Both lanes write into the same file and the "
                 f"heading is what tells an amendment from a correction — a lane that "
                 f"spells it differently makes STATUS.md unreadable across changes.")


def check_gate_messages() -> None:
    """A gate's failure message is the prose an agent reads under the most pressure.

    `manifest.py` said "see the freeze-contract skill" and `harvest-contract.py` said the
    same in its breaking-change advice, months after docs/adr/0005 deleted the skills.
    check_dead_wiring and check_commands both scan prose files only, so `scripts/` — the
    one surface consulted at the moment of failure — had no coverage at all.

    Scanned twice, and the second pass is the one that earns its place. This check was
    line-oriented, and a gate message long enough to matter is a wrapped Python string:
    `manifest.py`'s freeze advice sat across a seam as `"... the freeze-contract "` plus
    `"skill), commit ..."`, so the phrase existed in the file, reached the reader whole,
    and appeared on no single line. The check reported 13 passing while the one reference
    it was written to catch was still there. So adjacent literals are joined and the file
    is searched again — without a line number, because the offsets no longer map to one,
    and a file-level report is worth more than a precise number for a reference that is
    not there.
    """
    have_cmd = {os.path.basename(p)[:-3]
                for p in glob.glob(os.path.join(ROOT, ".claude", "commands", "*.md"))}
    have_skill = {os.path.basename(p)
                  for p in glob.glob(os.path.join(ROOT, ".claude", "skills", "*"))}
    named_skill = re.compile(r"\bthe ([a-z][a-z0-9]*(?:-[a-z0-9]+)+) skill\b")
    # `"... one half "` newline indent `"other half ..."` — one string to the reader, two
    # to a line-oriented scan.
    LITERAL_SEAM = re.compile(r"[\"']\s*\n\s*[\"']")

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

        # Second pass: the same two searches over a view of the file with adjacent string
        # literals joined, which is the form the reader actually sees. Only references the
        # per-line pass could not see are reported, so a wrapped message is named once.
        joined = LITERAL_SEAM.sub("", text)
        for name in named_skill.findall(joined):
            if name not in have_skill and not any(
                    name in named_skill.findall(l) for l in text.splitlines()):
                fail("gate-messages",
                     f"{rel(script)} tells the reader to see the {name!r} skill, which "
                     f"does not exist. It is wrapped across a string seam, so it appears "
                     f"on no single line while reaching the reader whole.")
        for name in re.findall(r"`/([a-z][a-z0-9-]*)`", joined):
            if name not in have_cmd and not any(
                    name in re.findall(r"`/([a-z][a-z0-9-]*)`", l) for l in text.splitlines()):
                fail("gate-messages",
                     f"{rel(script)} names /{name}, which does not exist in "
                     f".claude/commands/. It is wrapped across a string seam.")


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
                # The same argument for a segment at the END of a path, which has no
                # trailing slash: `/content` in prose about
                # `GET /v1/documents/{document_id}/content` was reported as a missing
                # command, and correct prose was reworded to satisfy the check. A slash
                # command is never preceded by another path segment.
                if re.search(r"[\w}\]\-]/" + re.escape(named) + r"\b", text):
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
                             f"The lanes are the commands in .claude/commands/; the scripts "
                             f"are what they call. See docs/adr/0005.")


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


# --- 15. the stack's services are all dumpable and all attributable ------------------
# 0004 added `opensearch` and `minio` to stack/compose.yml and updated neither list that
# names services: stack.sh's SERVICES, which decides what `dump` writes on a failure, and
# failure-brief.py's SERVICES, which decides which container logs an agent is shown. So
# changes/0005-observability-phoenix/runs/20260901T111656Z/attempt-1/ carries six
# .container.log files for a nine-service stack, and a knowledge-base failure would have
# been briefed with no OpenSearch log at all. Both lists are hand-kept; this is what keeps
# them honest. Scope is stack/compose.yml, the file this repo owns and where the
# agentapp.owner labels are declared — a service that exists only in an included file is
# out of reach here and has no owner label either.
def check_stack_services() -> None:
    compose = os.path.join(ROOT, "stack", "compose.yml")
    if not os.path.exists(compose):
        return
    services = set((yaml.safe_load(open(compose)) or {}).get("services") or {})
    if not services:
        return

    stack_sh = open(os.path.join(ROOT, "scripts", "stack.sh")).read()
    m = re.search(r"^SERVICES=\((.*?)\)", stack_sh, re.M)
    dumped = set((m.group(1) if m else "").split())
    for missing in sorted(services - dumped):
        fail("stack-services",
             f"stack/compose.yml declares service {missing!r} and scripts/stack.sh's "
             f"SERVICES does not list it — `stack.sh dump` writes no log for it, so a run "
             f"that failed because of it leaves no evidence. Add it to SERVICES.")

    # A job routes its failure by its own `owner`, and the service it runs routes a
    # stack failure by its `agentapp.owner` label. Two fields, one question — and when they
    # disagree the same container sends two different repos after the same problem. Neither
    # file can see the other, so this is the only place the pair is checkable.
    labels = {name: ((svc or {}).get("labels") or {}).get("agentapp.owner")
              for name, svc in ((yaml.safe_load(open(compose)) or {})
                                .get("services") or {}).items()}
    for path in sorted(glob.glob(os.path.join(ROOT, "changes", "*", "change.yaml"))):
        try:
            doc = yaml.safe_load(open(path)) or {}
        except yaml.YAMLError:
            continue  # manifest.py --validate is what reports an unparseable manifest
        for job in doc.get("jobs") or []:
            if not isinstance(job, dict):
                continue
            svc, owner = job.get("service"), job.get("owner")
            declared = labels.get(svc)
            if svc and owner and declared and declared != owner:
                fail("stack-services",
                     f"{rel(path)}: job {job.get('name')!r} runs service {svc!r} with "
                     f"owner: {owner!r}, and stack/compose.yml labels that service "
                     f"agentapp.owner: {declared!r}. One container, two answerable repos — "
                     f"a failing job and a failing stack would be routed to different "
                     f"agents. Make them agree.")

    brief = open(os.path.join(ROOT, "scripts", "failure-brief.py")).read()
    block = re.search(r"^SERVICES = \{(.*?)^\}", brief, re.M | re.S)
    attributed = set(re.findall(r'"([a-z0-9_.-]+)"', block.group(1) if block else ""))
    for missing in sorted(services - attributed):
        fail("stack-services",
             f"stack/compose.yml declares service {missing!r} and no repo claims it in "
             f"scripts/failure-brief.py's SERVICES map — its log is never put in front of "
             f"a repair agent. Add it as `primary` or `supporting` for whoever owns it.")


# --- 16. the local stack keeps no state across a `down` -------------------------------
# docs/adr/0011: `down` is a clean slate. A host bind mount for data, or an `external: true`
# volume, survives `docker compose down -v` — so the stack comes back warm and a run can pass
# on the previous run's leftovers. That failure is invisible, intermittent, and makes a broken
# change look green on the second attempt, which is why it is a gate and not a sentence.
#
# Reads the two included submodule compose files as plain YAML. NOT `docker compose config`:
# that inlines env_file and would print the credentials in chatbot-backend/.env (CLAUDE.md).
# Plain parsing sees the declarations, which is all this needs.
def check_clean_slate() -> None:
    files = [os.path.join(ROOT, "stack", "compose.yml")]
    files += [os.path.join(ROOT, sub, "docker-compose.yml") for sub in SUBMODULES]

    for path in files:
        if not os.path.exists(path):
            continue  # infra/ has no compose file, and a fresh clone may have no submodules
        try:
            doc = yaml.safe_load(open(path)) or {}
        except yaml.YAMLError as exc:
            fail("clean-slate", f"{os.path.relpath(path, ROOT)} is not parseable YAML: {exc}")
            continue
        rel = os.path.relpath(path, ROOT)

        for name, svc in (doc.get("services") or {}).items():
            for mount in (svc or {}).get("volumes") or []:
                # Long form: {type: bind|volume, source: ..., target: ...}
                if isinstance(mount, dict):
                    kind, source, target = (mount.get("type"), mount.get("source"),
                                            mount.get("target"))
                else:
                    parts = str(mount).split(":")
                    if len(parts) < 2:
                        continue  # an anonymous volume — Compose owns it, `down -v` takes it
                    source, target = parts[0], parts[1]
                    kind = "bind" if source.startswith((".", "/", "~", "$")) else "volume"
                if kind != "bind":
                    continue
                # A read-only mount of source or config is not state. Data is what this is about.
                if isinstance(mount, str) and mount.endswith((":ro", ":ro,z", ":ro,Z")):
                    continue
                if isinstance(mount, dict) and mount.get("read_only"):
                    continue
                fail("clean-slate",
                     f"{rel}: service {name!r} bind-mounts {source!r} at {target!r}. A host "
                     f"path survives `docker compose down -v`, so `make down && make up` "
                     f"would come back warm and a run could pass on the last run's data. "
                     f"docs/adr/0011 requires a project-scoped named volume. Mount it "
                     f"read-only if it is config rather than state.")

        for name, vol in (doc.get("volumes") or {}).items():
            if isinstance(vol, dict) and vol.get("external"):
                fail("clean-slate",
                     f"{rel}: volume {name!r} is `external: true`, so `docker compose down "
                     f"-v` leaves it behind and the joined stack comes back warm. "
                     f"docs/adr/0011 forbids it — declare it in the compose file that uses "
                     f"it and let Compose own its lifetime.")




# --- 17. every image carries a hand-bumped local version -----------------------------
# docs/adr/0015. `BACKEND_IMAGE_TAG=dev` honoured the rule that a build identity is supplied
# from outside the image, and was the same string for every build — so every experiment in
# Phoenix recorded `image_tag: "dev"` in the one field meant to distinguish builds. The rule
# held and the field was useless, which reads as working.
#
# Two checks. The shape always runs. The bump needs `origin/main` to compare against and
# SKIPS when there is none — a fresh clone or a shallow CI checkout — because a gate that
# cannot see the baseline must not invent one. That is a real weakening and is why
# changes/0006's suite asserts the shape at the seam independently.
IMAGE_TAG_SHAPE = re.compile(r"^local-\d+\.\d+\.\d+$")

# Which repo's changes oblige which tag. A repo absent from this map is NOT gated, on
# purpose: `frontend` ships an image but nothing reads a frontend build identity today, and
# a gate over a value nobody consumes is the speculative check this file's own doctrine
# rejects. `infra` ships no image. Adding one is a line here.
IMAGE_TAG_OWNERS = {
    "chatbot-backend": "BACKEND_IMAGE_TAG",
    "chatbot-eval": "EVAL_IMAGE_TAG",
}


def _dev_env_values(text: str) -> dict[str, str]:
    """FIRST occurrence wins, because that is what scripts/dev-env.sh does.

    dev-env.sh fills only variables that are still unset, so a name declared twice resolves
    to its FIRST value. This function used to build a dict and therefore took the LAST —
    so `[image-tags]` passed on `local-0.0.1` while the stack ran the `dev` declared 18
    lines earlier. A gate reading a file differently from the loader that consumes it is
    worse than no gate. `[dev-env-duplicates]` below makes the divergence unreachable;
    this keeps the two readers honest even so.
    """
    out: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        out.setdefault(key.strip(), value.strip())
    return out


# --- 18. a name is declared once in stack/dev.env ------------------------------------
# docs/adr/0006 makes stack/dev.env one layer of a precedence chain, and check_env_layers
# already refuses a name that ALSO appears in chatbot-backend/.env. It never looked for a
# name declared twice in this file, and that cost a run: BACKEND_IMAGE_TAG was `dev` in one
# block and `local-0.0.1` in another, dev-env.sh took the first, the gate took the last, and
# the stack was tested against a value nothing had asserted. Cheap, and it maps to a defect
# that actually happened.
def check_dev_env_duplicates() -> None:
    path = os.path.join(ROOT, "stack", "dev.env")
    try:
        lines = open(path).read().splitlines()
    except OSError:
        return  # check_suite_vars reports a missing dev.env

    seen: dict[str, int] = {}
    for n, line in enumerate(lines, 1):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key = line.split("=", 1)[0].strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            continue
        if key in seen:
            fail("dev-env-duplicates",
                 f"stack/dev.env declares {key} twice, on lines {seen[key]} and {n}. "
                 f"scripts/dev-env.sh fills only UNSET names, so line {seen[key]} wins and "
                 f"line {n} is unreachable — the stack runs one value while a reader of the "
                 f"file sees the other. Delete one.")
        else:
            seen[key] = n


def check_image_tags() -> None:
    dev_env = os.path.join(ROOT, "stack", "dev.env")
    try:
        current = _dev_env_values(open(dev_env).read())
    except OSError:
        return  # check_suite_vars already reports a missing dev.env

    declared = {k: v for k, v in current.items() if k.endswith("_IMAGE_TAG")}
    for name, value in sorted(declared.items()):
        if not IMAGE_TAG_SHAPE.match(value):
            fail("image-tags",
                 f"stack/dev.env: {name}={value!r} is not `local-<major>.<minor>.<patch>`. "
                 f"A tag that carries no version cannot distinguish two builds, which is the "
                 f"whole reason the field exists — `dev` satisfied every other check for a "
                 f"month. See docs/adr/0015.")

    for repo, name in sorted(IMAGE_TAG_OWNERS.items()):
        if name not in declared:
            fail("image-tags",
                 f"IMAGE_TAG_OWNERS maps {repo} to {name} and stack/dev.env does not declare "
                 f"it. Declare it, or drop the mapping — an unmapped repo is simply not "
                 f"gated, and that is a decision rather than an omission.")

    # The bump. Only for a change IN FLIGHT — one whose directory is not on origin/main.
    # A merged change's tag is already history and must not be re-litigated.
    # The ref is overridable so this half can be PROBED. It cannot fire against real
    # origin/main until the variables exist there, and an unprobed gate is worse than none
    # (docs/init/README.md). Defaults to origin/main; nothing in the harness sets it.
    baseline_ref = os.environ.get("CHECK_DOCS_BASELINE_REF", "origin/main")
    p = subprocess.run(("git", "show", f"{baseline_ref}:stack/dev.env"),
                       capture_output=True, text=True, cwd=ROOT)
    if p.returncode != 0:
        return  # no origin/main here; the shape check above still ran
    baseline = _dev_env_values(p.stdout)

    for path in sorted(glob.glob(os.path.join(ROOT, "changes", "*", "change.yaml"))):
        change_dir = os.path.basename(os.path.dirname(path))
        if change_dir == "0000-example-change":
            continue
        on_main = subprocess.run(
            ("git", "cat-file", "-e",
             f"{baseline_ref}:changes/{change_dir}/change.yaml"),
            capture_output=True, cwd=ROOT).returncode == 0
        if on_main:
            continue  # merged, or at least already on main: its tags are history
        try:
            doc = yaml.safe_load(open(path)) or {}
        except yaml.YAMLError:
            continue  # manifest.py --validate owns unparseable manifests
        for repo in doc.get("slices") or []:
            name = IMAGE_TAG_OWNERS.get(repo)
            if not name:
                continue
            was, now = baseline.get(name), declared.get(name)
            if was is not None and was == now:
                fail("image-tags",
                     f"changes/{change_dir} has a {repo} slice and stack/dev.env still has "
                     f"{name}={now!r}, the same value as on {baseline_ref}. A change that "
                     f"touches a product repo must bump its image tag, or every experiment "
                     f"and every deployed environment records this build as the previous "
                     f"one. See docs/adr/0015.")


# --- 19. one home for provider credentials, and no harness process reads it ----------
# docs/adr/0016. `make eval JUDGE=bedrock` failed with "You must specify a region" because
# chatbot-eval/.env held three credential names and no region, and nothing anywhere named
# one — while chatbot-backend/.env happened to carry AWS_REGION, so the backend worked and
# the eval did not. Credentials were per-repo, so a second consumer meant a second copy and
# a second chance to omit something.
#
# The safety property this must NOT trade away is docs/adr/0006's: a credential never
# enters a control-repo process, because this repo writes verify.json, smoke.json, container
# logs and repair prompts. A shared file is safe only while compose's `env_file` is its only
# reader — hence the dev-env.sh clause, which is the load-bearing one.
SECRETS_FILE = "secrets.env"

# Services in stack/compose.yml that may call a provider and therefore need the shared file.
# Hand-kept, like IMAGE_TAG_OWNERS: a service absent from this tuple is simply not gated,
# which is a decision rather than an omission.
PROVIDER_SERVICES = ("backend", "eval")

# What the template has to name. AWS_REGION is here because its absence is the whole reason
# this check exists: boto3 resolves a region from the environment or fails, and nothing in
# the joined stack named one for the eval.
REQUIRED_SECRET_NAMES = ("AWS_REGION",)

# Names that must NEVER appear in a committed file or an interpolated `environment:` value.
# Deliberately NOT CREDENTIAL_SHAPED: that also matches SMOKE_PASSWORD, DEV_ACCOUNT_PASSWORD
# and EVAL_ACCOUNT_PASSWORD, which are committed ON PURPOSE — they are `.test` identities
# that guard nothing reachable, docs/adr/0005 and 0006 argue why, and the smoke suites have
# to interpolate them so stack/dev.env is exactly where they belong. The rule is about a
# real credential for an external provider, which is a narrower thing.
PROVIDER_SECRET = re.compile(
    r"^AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN|PROFILE)$")


def check_provider_credentials() -> None:
    example = os.path.join(ROOT, "stack", f"{SECRETS_FILE}.example")
    if not os.path.exists(example):
        fail("provider-credentials",
             f"stack/{SECRETS_FILE}.example does not exist. It is the file a person copies "
             f"to stack/{SECRETS_FILE} to give the whole joined stack its credentials, and "
             f"without a template the names are folklore — which is how the eval ended up "
             f"with credentials and no AWS_REGION. See docs/adr/0016.")
    else:
        declared = _env_keys(example)
        for name in REQUIRED_SECRET_NAMES:
            if name not in declared:
                fail("provider-credentials",
                     f"stack/{SECRETS_FILE}.example does not name {name}. boto3 resolves a "
                     f"region from the environment or refuses, and `make eval JUDGE=bedrock` "
                     f"died on exactly that. Name it in the template, commented out if it "
                     f"has no sensible default.")

    # The real file must never be committable.
    p = subprocess.run(("git", "check-ignore", "-q", f"stack/{SECRETS_FILE}"),
                       capture_output=True, cwd=ROOT)
    if p.returncode != 0:
        fail("provider-credentials",
             f"stack/{SECRETS_FILE} is not gitignored. It is the one file in this repo that "
             f"holds real credentials; .gitignore must cover it by name.")

    # THE LOAD-BEARING CLAUSE. docs/adr/0006 keeps credentials out of every control-repo
    # process. The shared file is safe only because compose's env_file is its only reader.
    try:
        dev_env_sh = open(os.path.join(ROOT, "scripts", "dev-env.sh")).read()
    except OSError:
        dev_env_sh = ""
    # dev-env.sh MAY read the credentials file, for MODE SELECTORS only, through an
    # allowlist — docs/adr/0017. What it may never do is let a credential through: this repo
    # writes verify.json, smoke.json, container logs and repair prompts, and docs/adr/0006
    # keeps credentials out of exactly that. The rule used to be "must not name the file",
    # which was a blunt proxy for this and forbade the working fix along with the dangerous
    # one. The credentials themselves still reach the containers over compose's env_file
    # and are read by the Docker daemon, never here.
    if SECRETS_FILE in dev_env_sh:
        m = re.search(r'^SECRETS_ENV_ALLOW="([^"]*)"', dev_env_sh, re.M)
        if not m:
            fail("provider-credentials",
                 f"scripts/dev-env.sh reads {SECRETS_FILE} with no SECRETS_ENV_ALLOW "
                 f"allowlist. Reading that file without one lets a credential into the "
                 f"environment of the process that writes this repo's run artifacts. "
                 f"See docs/adr/0006 and docs/adr/0017.")
        else:
            for name in m.group(1).split():
                if PROVIDER_SECRET.match(name) or CREDENTIAL_SHAPED.search(name):
                    fail("provider-credentials",
                         f"SECRETS_ENV_ALLOW in scripts/dev-env.sh names {name}, which is "
                         f"credential-shaped. That allowlist exists for MODE SELECTORS — "
                         f"CHAT_MODEL, EVAL_JUDGE — and a credential in it would enter the "
                         f"process that writes verify.json, smoke.json and repair prompts.")

    compose = os.path.join(ROOT, "stack", "compose.yml")
    try:
        doc = yaml.safe_load(open(compose)) or {}
    except (OSError, yaml.YAMLError):
        return  # other checks report an unparseable compose file
    services = doc.get("services") or {}

    for name in PROVIDER_SERVICES:
        svc = services.get(name)
        if svc is None:
            fail("provider-credentials",
                 f"PROVIDER_SERVICES names {name!r} and stack/compose.yml declares no such "
                 f"service. Drop it from the tuple, or declare the service — an ungated "
                 f"provider service is how a credential goes missing silently.")
            continue
        entries = (svc or {}).get("env_file") or []
        if isinstance(entries, (str, dict)):
            entries = [entries]
        paths = [e if isinstance(e, str) else (e or {}).get("path", "") for e in entries]
        if not any(SECRETS_FILE in str(p) for p in paths):
            fail("provider-credentials",
                 f"stack/compose.yml service {name!r} does not read stack/{SECRETS_FILE} "
                 f"through env_file. It is a provider-calling service, so it needs the "
                 f"shared credentials — and per-service copies are what left the eval "
                 f"without a region. See docs/adr/0016.")

    # A credential must never be interpolated into an `environment:` value: `make config`
    # prints those, and stack/dev.env is committed.
    for name, svc in sorted(services.items()):
        for key in ((svc or {}).get("environment") or {}):
            if PROVIDER_SECRET.match(str(key)):
                fail("provider-credentials",
                     f"stack/compose.yml service {name!r} sets {key} under `environment:`. "
                     f"Credentials reach a container through env_file, read by the Docker "
                     f"daemon — an `environment:` value is interpolated by compose and "
                     f"printed by `make config`.")

    for key in _env_keys(os.path.join(ROOT, "stack", "dev.env")):
        if PROVIDER_SECRET.match(key):
            fail("provider-credentials",
                 f"stack/dev.env declares {key}, which is credential-shaped, and that file "
                 f"is COMMITTED. It belongs in stack/{SECRETS_FILE}.")


# --- 20. dev-env.sh does not strip trailing comments ---------------------------------
# Its parser is `_val="${_line#*=}"` — everything after the first `=`, verbatim. So
# `SIGNUP_CODE=dev-signup-code  # gates registration` sets the value to
# `dev-signup-code  # gates registration` and every assertion that interpolates it fails
# for a reason nobody would look for. This is a live trap precisely because the file was
# just made terse, and an inline comment is the obvious way to keep it terse.
def check_dev_env_inline_comments() -> None:
    path = os.path.join(ROOT, "stack", "dev.env")
    try:
        lines = open(path).read().splitlines()
    except OSError:
        return
    for n, line in enumerate(lines, 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        value = stripped.split("=", 1)[1]
        if " #" in value:
            fail("dev-env-inline-comments",
                 f"stack/dev.env line {n} looks like it has a trailing comment. "
                 f"scripts/dev-env.sh takes EVERYTHING after the first `=` verbatim — it "
                 f"does not strip comments or quotes — so the value would include the "
                 f"comment. Put it on its own line above.")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--warnings-are-errors", action="store_true")
    args = ap.parse_args()

    checks = (check_freeze_sha_home, check_suite_vars, check_step_schema_documented,
              check_banned_phrases, check_claude_md_size, check_dead_wiring,
              check_vendored_contracts, check_commands,
              check_scripts_are_not_the_entry_point, check_env_layers,
              check_gate_messages, check_loop_calls, check_agent_dispatchers,
              check_stack_services, check_clean_slate, check_lane_coverage,
              check_lane_vocabulary, check_status_headings,
              check_image_tags, check_dev_env_duplicates,
              check_provider_credentials, check_dev_env_inline_comments,
              report_readme_divergence)
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
