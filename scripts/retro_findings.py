"""What the § 7 ledger reads out of a retrospective, in one place.

Two callers need the same answer: retro-evidence.sh, which prints the ledger, and
check-docs.py, which holds every retro to it. When only the printer knew the rule, three
retros drifted to a shape it could not see and the ledger showed 8 of 32 findings — the
second-occurrence rule then reads a recorded finding as one nobody ever noticed.

Not a schema check. It answers "what did this file record", generously, because a finding
the ledger cannot see is worse than one it shows twice.
"""
import re

HEADING = re.compile(r"^(#{2,3})\s+(.*)$")
# The two forms the corpus uses: `### F1 — …` under `## Findings`, and `- **R2 — …**` under
# `## Recorded, not proposed` / `## Rejected`. A field label inside a finding body is
# `- **Evidence:** …`; the trailing colon is the whole difference.
BULLET = re.compile(r"^- \*\*(.+?)\*\*")
# Sections that are not findings. The audit is per-item state, and `Not verified` is the
# list of things nobody checked — neither is proposable next time.
NOT_FINDINGS = ("state audit", "not verified")


def leads(text):
    """[(section, lead)] — one entry per finding recorded in `text`, in file order."""
    out, section = [], ""
    for line in text.splitlines():
        m = HEADING.match(line)
        if m:
            if m.group(1) == "##":
                section = m.group(2).strip()
            elif not section.lower().startswith(NOT_FINDINGS):
                out.append((section, m.group(2).strip()))
            continue
        b = BULLET.match(line)
        if b and not section.lower().startswith(NOT_FINDINGS):
            lead = b.group(1).strip()
            if not lead.endswith(":"):
                out.append((section, lead))
    return out


def declared(text):
    """{proposed, recorded, rejected} from the frontmatter, or None if it says nothing."""
    m = re.search(r"^findings:\s*(.+)$", text, re.M)
    if not m:
        return None
    got = {k: int(n) for n, k in
           re.findall(r"(\d+)\s+(proposed|recorded|rejected)", m.group(1))}
    return got or None
