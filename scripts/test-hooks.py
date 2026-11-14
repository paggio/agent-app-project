#!/usr/bin/env python3
"""Probe the submodule-write guard: does it block what it claims, and nothing else?

  ./scripts/test-hooks.py

A guard nobody probes is a guard that quietly stops working — docs/init/README.md's "break
a test on purpose and confirm the gate blocks" applied to the hook itself. The false-positive
half matters as much as the true-positive half: the first version of this hook fired on
`echo "never write into chatbot-backend/"`, and a guard that blocks ordinary work is a guard
the agent learns to route around.

The guard reads its submodule set from .gitmodules, so the per-submodule cases are generated
from the same file: a repo attached by new-repo.sh is probed in both directions, and its
`Edit(./<path>/**)` deny rule in .claude/settings.json is checked to exist.
"""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from repos import REPOS  # noqa: E402

HOOK = ".claude/hooks/no-subrepo-edits.sh"

BLOCK = [
    'sed -i "" s/a/b/ chatbot-backend/src/app/main.py',
    "echo hi > frontend/src/x.ts",
    "rm -rf infra/src",
    "cp /tmp/x chatbot-backend/foo",
    "tee frontend/Caddyfile < /tmp/c",
    "mkdir -p infra/modules/net",
    "cd /tmp && rm frontend/dist/a.js",
    "git apply /tmp/p.diff && mv chatbot-backend/a chatbot-backend/b",
    'python3 -c "x" ; touch infra/main.tf',
    "chmod +x chatbot-backend/scripts/x.sh",
    "cp /tmp/e.py chatbot-eval/src/eval/run.py",
    "rm -rf chatbot-eval/evalset/corpus",
] + [f"touch {r}/x" for r in REPOS] + [f"echo x > ./{r}/x" for r in REPOS]

ALLOW = [
    "cat CLAUDE.md",
    "git -C chatbot-backend status",
    "git -C frontend switch main",
    "git -C frontend switch -c feat/0002-x",
    "grep -rn foo chatbot-backend/src",
    "cat > CLAUDE.md <<'EOF'\nNEVER edit inside chatbot-backend/, chatbot-eval/, frontend/, infra/ from here.\nEOF",
    "rm -rf changes/0002/runs",
    'echo "do not write into chatbot-backend/"',
    'sed -i "" s/a/b/ CLAUDE.md',
    "ls chatbot-backend/src && cat contracts/openapi.yaml",
    "for tok in tee cp mv rm; do echo $tok; done; ls chatbot-backend/",
    "./scripts/lock.sh",
    "docker compose -f stack/compose.yml config",
    "wc -l chatbot-backend/CLAUDE.md frontend/CLAUDE.md infra/CLAUDE.md",
    "git -C chatbot-eval switch -c feat/0006-chatbot-eval",
    "cat chatbot-eval/evalset/questions.yaml",
] + [f"git -C {r} switch -c feat/x" for r in REPOS] + [f"cat {r}/README.md" for r in REPOS]


def verdict(cmd: str) -> str:
    payload = json.dumps({"tool_input": {"command": cmd}})
    p = subprocess.run([HOOK], input=payload, text=True, capture_output=True)
    return "allow" if p.returncode == 0 else "block"


fails = 0
for want, cases in (("block", BLOCK), ("allow", ALLOW)):
    print(f"MUST {want.upper()}:")
    for c in cases:
        got = verdict(c)
        mark = "ok  " if got == want else "FAIL"
        if got != want:
            fails += 1
        print(f"  {mark} {c!r}")
deny = set((json.load(open(".claude/settings.json")).get("permissions") or {}).get("deny") or [])
print("MUST DENY EDIT:")
for r in REPOS:
    ok = f"Edit(./{r}/**)" in deny
    fails += not ok
    print(f"  {'ok  ' if ok else 'FAIL'} Edit(./{r}/**) in .claude/settings.json")
print(f"\n{fails} failure(s)")
sys.exit(1 if fails else 0)
