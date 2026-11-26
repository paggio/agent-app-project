"""CI/CD: how a change travels from an idea to dev. The spirit, not the detail.

The detail lives in docs/ and scripts/. check-docs.py [diagrams] fails when a workflow or a lane
appears or disappears that REVIEWED_AGAINST does not list: look at the picture, redraw it if the
story changed, then update the list and `make diagrams`.
"""
from draw import E, arrow, box, mid, text

STYLE = "clean"
W, H = 1720, 1080

# Every workflow (<repo>/<file>) and lane this picture was last checked against.
REVIEWED_AGAINST = [
    "agent-app-project/ci.yml", "agent-app-project/dev-down.yml", "agent-app-project/dev-eval.yml",
    "agent-app-project/dev-push.yml", "agent-app-project/release-prod.yml",
    "analytics-dbt/ci.yml", "analytics-dbt/dev-push.yml", "chatbot-backend/ci.yml",
    "chatbot-eval/ci.yml", "frontend/ci.yml", "frontend/dev-push.yml", "infra/ci.yml",
    "infra/dev-push.yml", "metrics-gateway/ci.yml", "metrics-gateway/dev-push.yml",
    "/realign", "/ship", "/ship-correct", "/ship-iterate",
]

MUTED = "#868e96"
RED = "#e03131"


def note(b, s):
    """The 'started by' line at the foot of a stage card."""
    x, y, w, h = b
    gid = next(e["group"] for e in reversed(E) if e["kind"] == "rect")
    text(x + 16, y + h - 30, s, 13, color=MUTED, group=gid)


def stack(x, y, w, steps, tone):
    """A vertical run of one-line steps joined by arrows; returns the bottom y."""
    prev = None
    for s in steps:
        b = box(x, y, w, 46, s, owner=tone, tsize=15, align="left")
        if prev:
            arrow([mid(prev, "b"), mid(b, "t")])
        prev, y = b, y + 46 + 20
    return y - 20


def scene():
    text(40, 28, "How a change reaches dev", 30, bold=True)
    text(40, 74, "The spirit of it. The details live in docs/ and scripts/; dig there when you "
                 "need them.", 16, color=MUTED)

    stages = [
        ("1  Plan", "Write what you want and\nhow we'll know it works.\nFreeze the API between\n"
         "the repos first.", "violet", "started by you: /ship"),
        ("2  Build", "One agent per repo builds\nits part, inside that repo,\nagainst the frozen "
         "API.", "blue", "automatic"),
        ("3  Test together", "Every repo runs as one\nsystem on Docker, and the\nacceptance tests "
         "run\nagainst it.", "green", "automatic (iterate.sh)"),
        ("4  Deploy to dev", "CI builds the images,\nupdates AWS, then runs\nthe same tests on "
         "the\nlive URL.", "orange", "a /dev-push PR comment"),
        ("5  Score the answers", "A fixed set of questions\nis asked to dev; the\nscores must "
         "clear their\nthresholds.", "yellow", "a /dev-eval PR comment"),
        ("6  Review and merge", "You read the green PRs\nand merge them. /realign\nthen brings "
         "this repo\nup to date, re-checked.", "gray", "you"),
    ]
    cards = []
    for k, (title, body, tone, by) in enumerate(stages):
        b = box(40 + k * 280, 130, 240, 200, title, body, owner=tone, tsize=18, bsize=14.5,
                align="left")
        note(b, by)
        cards.append(b)
    for a, b in zip(cards, cards[1:]):
        arrow([mid(a, "r"), mid(b, "l")])

    # The two loops back to the repo that owns the failure.
    x2 = cards[1][0] + 120
    arrow([mid(cards[2], "b"), (cards[2][0] + 120, 365), (x2 + 20, 365), (x2 + 20, 330)],
          "a test fails: back to the repo that owns it", color=RED, at=(cards[2][0] - 10, 365))
    arrow([mid(cards[3], "b"), (cards[3][0] + 120, 400), (x2 - 20, 400), (x2 - 20, 330)],
          "red on dev: fix in that repo, redeploy", color=RED, at=(cards[3][0] - 150, 400))

    box(40, 440, 1640, 64, "Always on, outside the lanes: every pull request in every repo runs "
        "its own CI", "lint, types, unit tests, and a check that the repo still speaks the agreed "
        "API. No AWS. A PR that changes the API is refused there and sent to /ship.",
        owner="white", tsize=16, bsize=14, align="left")

    # Zoom panels.
    text(40, 548, "Inside step 4: what a /dev-push does", 20, bold=True)
    bottom = stack(40, 588, 800, [
        "Pick the code: each repo at its PR branch, the others at the last known-good version",
        "Build the images that do not exist yet",
        "Update AWS: Terraform for the infrastructure, Helm for the apps",
        "Run the tests through the public URL, as a browser would",
        "Post the verdict, and exactly which versions ran, on the PR",
    ], "orange")

    text(880, 548, "Inside step 4, when the dbt models change", 20, bold=True)
    stack(880, 588, 800, [
        "Helm first runs the release job: rebuild the data, publish the new metric definitions",
        "The indexer re-embeds the metrics, so questions can find them",
        "Only then does the gateway switch to the new release, with no downtime",
    ], "red")
    box(880, 788, 800, 46, "Separately, every night: refresh the searchable values (states, "
        "categories...)", owner="white", tsize=15, align="left")

    y = bottom + 50
    notes = [
        ("Access", "make login, then make push-gh-creds: lends CI a\nshort-lived AWS session. "
         "GitHub keeps no keys."),
        ("On and off", "make dev-up starts dev from the known-good\nversions (~25 min). "
         "make dev-down stops it."),
        ("Production", "Not built yet: release-prod.yml is a\nplaceholder until a prod "
         "environment exists."),
    ]
    for k, (title, body) in enumerate(notes):
        box(40 + k * 555, y, 530, 100, title, body, owner="gray", tsize=16, bsize=14,
            align="left")
