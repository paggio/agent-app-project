"""Tests: which ones run, where, and when. The spirit, not the detail.

check-docs.py [diagrams] fails when a repo's CI or a smoke suite appears or disappears that
REVIEWED_AGAINST does not list: look at the picture, redraw it if the story changed, then
update the list and `make diagrams`.
"""
from draw import E, arrow, box, text

STYLE = "clean"
W, H = 1720, 900

# Every repo CI (<repo>/ci.yml) and suite file this picture was last checked against.
REVIEWED_AGAINST = [
    "agent-app-project/ci.yml", "analytics-dbt/ci.yml", "chatbot-backend/ci.yml",
    "chatbot-eval/ci.yml", "frontend/ci.yml", "infra/ci.yml", "metrics-gateway/ci.yml",
    "smoke/baseline.yaml",
]

MUTED = "#868e96"


def card(x, y, w, h, title, tone, rows):
    box(x, y, w, h, title, owner=tone, tsize=20, align="left")
    gid = next(e["group"] for e in reversed(E) if e["kind"] == "rect")
    cy = y + 52
    for label, body in rows:
        text(x + 18, cy, label, 12, color=MUTED, group=gid, bold=True)
        text(x + 18, cy + 18, body, 15, group=gid)
        cy += 18 + 15 * 1.35 * (body.count("\n") + 1) + 16


def scene():
    text(40, 28, "What we test, where and when", 30, bold=True)
    text(40, 74, "Each layer is slower and closer to the real thing than the one before. A "
                 "failure goes back to the repo that owns it.", 16, color=MUTED)

    text(40, 118, "cheap, fast, isolated", 14, color=MUTED, bold=True)
    text(1535, 118, "slow, real, end to end", 14, color=MUTED, bold=True)
    arrow([(215, 128), (1515, 128)], color="#adb5bd")

    cols = [
        ("Every pull request", "blue", [
            ("WHEN", "every push to a PR, in each repo"),
            ("WHERE", "GitHub runners: no AWS, no other repos"),
            ("WHAT", "• lint and types\n• unit tests\n• contract check: the repo still\n   speaks the "
                     "agreed API\n• docs moved with the code"),
            ("CATCHES", "one repo broken on its own"),
        ]),
        ("The local loop", "green", [
            ("WHEN", "during /ship, before any PR"),
            ("WHERE", "your machine: every repo on\nDocker, as one system"),
            ("WHAT", "• acceptance tests: HTTP calls\n   through the front door (login,\n   chats, "
                     "documents, routing,\n   metrics...)\n• jobs that must exit cleanly\n   (data "
                     "release, indexer, eval)\n• a real browser test"),
            ("CATCHES", "repos that don't work together"),
        ]),
        ("On dev", "orange", [
            ("WHEN", "/dev-push, a comment on the PR"),
            ("WHERE", "AWS, through the public\nHTTPS address"),
            ("WHAT", "• the same acceptance tests,\n   minus the few that need\n   local access\n"
                     "• cloud-only checks: HTTPS,\n   secure cookies, the real\n   model answering"),
            ("CATCHES", "what only breaks in the cloud"),
        ]),
        ("Answer quality", "yellow", [
            ("WHEN", "/dev-eval on the PR; always\nafter /realign"),
            ("WHERE", "AWS dev"),
            ("WHAT", "a fixed set of realistic\nquestions, scored on routing,\ncitations and "
                     "answers,\nagainst thresholds"),
            ("CATCHES", "worse answers, not broken code"),
        ]),
    ]
    for k, (title, tone, rows) in enumerate(cols):
        card(40 + k * 415, 160, 390, 430, title, tone, rows)

    text(40, 625, "Where the tests are written", 20, bold=True)
    homes = [
        ("In each repo", "its unit and contract tests;\nthat repo owns them"),
        ("smoke/baseline.yaml", "the regression suite: what must\nkeep working, for every change"),
        ("changes/<n>/smoke.yaml", "this change's acceptance criteria,\nwritten before the code"),
        ("chatbot-eval", "the question set and the\nscore thresholds"),
    ]
    for k, (title, body) in enumerate(homes):
        box(40 + k * 415, 665, 390, 100, title, body, owner="white", tsize=16, bsize=14,
            align="left")
    text(40, 797, "The cross-repo tests (smoke, jobs, browser) are owned by this control repo. "
                  "They are changed here on purpose, never weakened to make a run pass.", 15,
         color=MUTED)
