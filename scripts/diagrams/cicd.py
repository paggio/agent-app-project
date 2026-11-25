"""CI/CD: every workflow, lane and make target that moves code toward dev, and what each does."""
from draw import E, FRAME, INK, arrow, box, frame, mid, text

W, H = 2700, 2140

# Fill = what a step is for (the legend).
KIND = {
    "trigger": "#d0bfff",
    "guard": "#ffc9c9",
    "resolve": "#a5d8ff",
    "build": "#ffec99",
    "deploy": "#b2f2bb",
    "assert": "#ffd8a8",
    "report": "#e9ecef",
    "state": "#ffffff",
}

# The product repos whose own dev-push.yml calls the control one (check-docs [diagrams]
# compares this with the repos that carry the file).
CALLERS = ["analytics-dbt", "frontend", "infra", "metrics-gateway"]


def scene() -> None:
    text(40, 28, "agentapp · CI/CD", 40)
    text(42, 84, "Every workflow, lane and make target that moves code toward dev, and what it "
                 "does. Fill = what a step is for. Source: scripts/diagrams/cicd.py", 17,
         color="#495057")

    # 0 — on the laptop ---------------------------------------------------------------------
    frame(40, 130, 830, 300, "Before a deploy · your laptop", FRAME["gh"])
    login = box(60, 175, 240, 120, "make login", "AWS SSO in the browser\nsession -> "
                "stack/secrets.env\n(hours, never a key)", owner=KIND["trigger"], bsize=13)
    creds = box(320, 175, 260, 120, "make push-gh-creds", "copies the session into\nevery "
                "repo's DEV_AWS_*\nsecrets + its expiry", owner=KIND["trigger"], bsize=13,
                tsize=17)
    setup = box(600, 175, 250, 120, "make gh-setup", "one-time: a deploy key per\nrepo "
                "(DEPLOY_KEY_*) in\nevery repo + the role ARN", owner=KIND["trigger"], bsize=13)
    arrow([mid(login, "r"), mid(creds, "l")])
    text(60, 318, "No long-lived AWS key exists in GitHub: CI chains your SSO session into\n"
                  "the bootstrap deployer role (1 h, re-assumed before every AWS stage).\n"
                  "make dev-bootstrap made that role, ECR and the state bucket, once.", 15,
         color="#343a40")

    frame(890, 130, 1770, 300, "The lanes · claude, in the control repo", FRAME["gh"])
    ship = box(910, 175, 300, 205, "/ship", "plan: BRIEF, smoke.yaml,\none slice per repo\n"
               "freeze contracts/ (alone)\n/ship-correct, /ship-iterate\nre-enter the loop\n"
               "ends with harness-retro", owner=KIND["trigger"], bsize=13)
    itr = box(1230, 175, 370, 205, "scripts/iterate.sh", "claude -p per slice, inside\n"
              "its repo (its own CLAUDE.md, gates)\njoined docker stack, one origin\n"
              "baseline + change smoke (local)\na failure goes back to the\nstep's owner, bounded",
              owner=KIND["assert"], bsize=13)
    prs = box(1620, 175, 230, 205, "scripts/prs.sh", "on verified-local:\none PR per repo,\n"
              "plus the control PR\nfeat/<change>", owner=KIND["report"], bsize=13)
    dps = box(1870, 175, 330, 205, "dev-push.sh · dev-eval.sh", "comments /dev-push or\n"
              "/dev-eval on the control PR,\nwaits for the run, pulls\nits evidence into\n"
              "changes/<c>/runs/", owner=KIND["trigger"], bsize=13, tsize=17)
    rea = box(2220, 175, 420, 205, "/realign", "after you merge the product PRs:\nbump submodules + "
              "repos.lock\nre-check contracts vs served\nbaseline smoke, realign PR\n"
              "-> /dev-push, then /dev-eval", owner=KIND["trigger"], bsize=13)
    arrow([mid(ship, "r"), mid(itr, "l")])
    arrow([mid(itr, "r"), mid(prs, "l")])
    arrow([mid(prs, "r"), mid(dps, "l")])
    arrow([mid(rea, "l", .85), (2210, mid(rea, "l", .85)[1]), (2210, 395), (2035, 395),
           mid(dps, "b")])

    # 1 — /dev-push -------------------------------------------------------------------------
    frame(40, 460, 2620, 500, "/dev-push · .github/workflows/dev-push.yml (main's copy) · "
          "concurrency env-dev, never cancelled", FRAME["eks"], size=22)
    arrow([mid(dps, "b", .3), (1970, 445), (300, 445), (300, 505)], "PR comment",
          at=(1100, 445))
    callers = box(60, 505, 330, 190, "product-repo callers", "dev-push.yml in " +
                  ",\n".join(CALLERS) + "\n= workflow_call of the control\none; /dev-push-<repo> "
                  "on a\nproduct PR", owner=KIND["trigger"], bsize=13)
    trig = box(410, 505, 420, 190, "trigger", "/dev-push on the control PR\n/dev-push-<repo>: "
               "rebuild one,\ncarry the rest at what dev runs\n--allow-destroy\n"
               "workflow_dispatch: lock=true\n(make dev-up) or change=", owner=KIND["trigger"],
               bsize=13)
    guard = box(850, 505, 330, 190, "guard", "commenter is OWNER,\nMEMBER or COLLABORATOR\n"
                "pushed session >= 30 min\nelse exit 2: refused,\nnot failed", owner=KIND["guard"],
                bsize=13)
    cred = box(1200, 505, 330, 190, "credentials", "DEV_AWS_* session\n-> assume the deployer"
               "\nrole (role chaining)\nrepo deploy keys:\none ssh alias per repo", owner=KIND["guard"],
               bsize=13)
    dset = box(1550, 505, 560, 190, "deploy set · scripts/deploy-set.py", "control PR feat/<c>: "
               "each slice at feat/<c>,\nevery other repo at repos.lock\nproduct PR: that repo at "
               "its head, rest at main's lock\n--only <repo>: the others carried at the tags "
               "dev\nruns (outputs read first) -> deployed-partial", owner=KIND["resolve"], bsize=13)
    chk = box(2130, 505, 510, 190, "check out what is built", "scripts/ci-checkout.sh: every "
              "repo at\nthe resolved commit; terraform 1.14,\nhelm 4, kubectl 1.36, buildx, uv\n"
              "infra at the commit that reads\nthe current state", owner=KIND["resolve"], bsize=13)
    for a, b in ((callers, trig), (trig, guard), (guard, cred), (cred, dset), (dset, chk)):
        arrow([mid(a, "r"), mid(b, "l")])

    Y2, H2 = 760, 180
    st = [
        (60, 220, "preflight", "suites well-formed,\ncheckouts match the\nset, contracts\n"
         "promise outputs", "guard"),
        (295, 250, "publish", "build + push to ECR\nonly images not\nthere yet; tag =\ncommit "
         "(dbt: full sha)", "build"),
        (560, 250, "infra: plan", "bin/infra plan\nsaved .tfplan\ndestroy or replace\n"
         "refused w/o flag", "deploy"),
        (825, 330, "infra: deploy", "terraform apply (that plan)\nhelm upgrade --install --wait"
         "\n(runs the hooks below)\nfailure: evidence, rollback", "deploy"),
        (1170, 270, "outputs, cross-checks", "outputs vs\ncontracts/infra-outputs\nimages, targets "
         "healthy,\nboth logins sign in", "assert"),
        (1455, 220, "readiness", "polls the\nCloudFront origin\nuntil it serves", "assert"),
        (1690, 280, "smoke · remote", "smoke/baseline.yaml\n+ changes/<c>/smoke.yaml\nexcept "
         "local-tagged\nfailure -> its owner", "assert"),
        (1985, 220, "still deployed?", "dev re-read: a run\nthat was replaced\nmid-suite is "
         "refused", "assert"),
        (2220, 420, "verdict -> PR comment", "verified · deployed-partial · failed\ncommits "
         "deployed per repo, sign-in\nevidence artifact (30 days)\nverify-remote.json is the "
         "oracle", "report"),
    ]
    prev = None
    for x, w, title, body, kind in st:
        b = box(x, Y2, w, H2, title, body, owner=KIND[kind], bsize=13, tsize=17)
        if prev:
            arrow([mid(prev, "r"), mid(b, "l")])
        prev = b
        if title == "infra: deploy":
            deploy = b
    arrow([mid(chk, "b"), (2385, 728), (170, 728), (170, Y2)], "scripts/verify-remote.sh",
          at=(1300, 728))

    # 2 — the metrics release, inside helm upgrade --------------------------------------------
    frame(40, 990, 2620, 400, "Inside infra: deploy · helm hooks: a dbt change reaches the "
          "metrics gateway (change 0009)", FRAME["vpc"], size=22)
    arrow([mid(deploy, "b"), (990, 990)], "helm upgrade", dashed=True, at=(990, 972))
    why = box(60, 1035, 340, 170, "how a dbt change ships", "merge on analytics-dbt\n-> /realign "
              "(or /dev-push\non its PR): new image,\ntag = commit = release sha\nno other path "
              "to dev", owner=KIND["trigger"], bsize=13, tsize=17)
    hooks = [
        (420, 260, "metrics-db Job", "pre-hook · as RDS master\nroles + passwords\nDBs olist, "
         "semantic_index\nidempotent", "deploy"),
        (700, 250, "rollout", "everything else,\nTrino and the gateway\nReady (--wait)",
         "deploy"),
        (970, 420, "metrics-release Job · post, weight 0", "analytics-dbt image, RELEASE_SHA = tag"
         "\nload: olist CSV -> Postgres, funnel -> Iceberg\ndbt build (Postgres, Trino) · mf "
         "validate\npublish <project>/<sha>/ (kept if it exists)", "build"),
        (1410, 420, "metrics-index Job · post, weight 10", "metrics-gateway image: indexer\n"
         "migrations · embed MiniLM 384-d into\npgvector semantic_index · values\nthen flip "
         "<project>/current.json · prune", "build"),
        (1850, 380, "metrics-gateway swaps", "polls current.json every 30 s\nnew sha: fetch "
         "bundle, verify\nsha256, new MetricFlow worker\nswap; old drains, retires", "deploy"),
        (2250, 390, "CronJob metrics-index-values", "03:17 UTC daily:\nindexer --values-only\n"
         "re-reads dimension values\n(no release, no flip)", "build"),
    ]
    prev = why
    hb = {}
    for x, w, title, body, kind in hooks:
        b = box(x, 1035, w, 170, title, body, owner=KIND[kind], bsize=13, tsize=17)
        arrow([mid(prev, "r"), mid(b, "l")])
        prev = b
        hb[title.split()[0]] = b
    E[-1]["dashed"] = True  # swap -> CronJob is a schedule, not a step
    olist = box(900, 1265, 230, 95, "RDS olist", "warehouse for olist", drum=True, bsize=13,
                owner=KIND["state"])
    lake = box(1150, 1265, 250, 95, "Trino -> Iceberg", "S3 warehouse + Glue", drum=True,
               bsize=13, owner=KIND["state"])
    rel = box(1420, 1265, 330, 95, "S3 semantic-releases", "<project>/<sha>/bundle.tar.gz\n"
              "<project>/current.json", drum=True, bsize=13, tsize=17, owner=KIND["state"])
    idx = box(1770, 1265, 300, 95, "RDS semantic_index", "pgvector: objects, values,\n"
              "audit.tool_call", drum=True, bsize=13, owner=KIND["state"])
    r, i, g = hb["metrics-release"], hb["metrics-index"], hb["metrics-gateway"]
    arrow([mid(r, "b", .15), mid(olist, "t")])
    arrow([mid(r, "b", .45), mid(lake, "t")])
    arrow([mid(r, "b", .85), mid(rel, "t", .2)], "bundle")
    arrow([mid(rel, "t", .6), mid(i, "b", .3)], "reads")
    arrow([mid(i, "b", .9), mid(idx, "t", .1)])
    arrow([mid(g, "b", .4), mid(idx, "t", .85)], "search", dashed=True)
    text(2100, 1275, "The release sha names the bundle,\nthe index rows and every number the\n"
                     "gateway returns: a query in flight\nfinishes on the release it started on.",
         14, color="#343a40")

    # 3 — /dev-eval -------------------------------------------------------------------------
    frame(40, 1420, 2620, 300, "/dev-eval · .github/workflows/dev-eval.yml · deploys nothing · "
          "concurrency dev-eval", FRAME["edge"], size=22)
    ev = [
        (60, 330, "trigger", "/dev-eval on a PR\n(--judge heuristic: no\nBedrock); product "
         "PRs\nvia workflow_call", "trigger"),
        (410, 330, "guard", "main's harness, the PR's\ncommits read as data\nsame commenter "
         "and\nsession checks", "guard"),
        (760, 400, "what runs where", "eval at feat/<c> if chatbot-eval\nis a slice, else its "
         "gitlink\nvs deployed-set.json (state\nbucket): warns when dev != PR", "resolve"),
        (1180, 360, "scripts/eval-remote.sh", "infra outputs, Phoenix API\nkey, signup code "
         "(masked)\nfresh eval account\nthe stack/dev.env defaults", "resolve"),
        (1560, 480, "chatbot-eval · 44 questions", "seed documents · fixture calls -> SQS\n"
         "one fresh chat per question, HTTPS /api\njudge: Bedrock Haiku 4.5 · experiment\n"
         "in Phoenix; dev re-read after", "assert"),
        (2060, 580, "verdict -> PR comment", "per evaluator: mean vs threshold\n(routing 0.8, "
         "recall 0.6), per route,\ncoordinator confusion matrix\nexit 0 met · 1 breached · 2 "
         "refused", "report"),
    ]
    prev = None
    for x, w, title, body, kind in ev:
        b = box(x, 1470, w, 190, title, body, owner=KIND[kind], bsize=13, tsize=17)
        if prev:
            arrow([mid(prev, "r"), mid(b, "l")])
        prev = b

    # 4 — PR checks and the rest ---------------------------------------------------------------
    frame(40, 1750, 1560, 300, "Every PR and push to main · each repo's ci.yml · no AWS",
          FRAME["boot"], size=20)
    checks = [
        ("agent-app-project", "docs: check-docs.py, guard\nprobes · manifests: every\nchange "
         "validates · actionlint"),
        ("chatbot-backend", "lint, format, mypy, unit +\ngraph tests, docs moved,\ncontract; "
         "integration stack"),
        ("frontend", "docs moved, format, lint,\ntypecheck, unit + component,\ncontract; app + "
         "proxy images"),
        ("infra", "validate (terraform,\nkubeconform) · lint (trivy)\ntest: bin/infra vs "
         "contracts"),
        ("metrics-gateway", "make check: ruff, mypy,\npytest + search eval\nimage builds · "
         "secret scan"),
        ("analytics-dbt", "make check · stack-test:\nload, build, publish on\ncompose · "
         "secret scan"),
        ("chatbot-eval", "lint, typecheck, tests,\ncontract, docs moved\nsecret scan"),
    ]
    for k, (repo, body) in enumerate(checks):
        x = 60 + (k % 4) * 385
        y = 1795 + (k // 4) * 125
        box(x, y, 370, 112, repo + " · ci.yml", body, owner=KIND["assert"], bsize=12.5,
            tsize=16)
    box(60 + 3 * 385, 1920, 370, 112, "the gate that matters", "a product PR touching contract"
        "\nsurface fails its own CI:\ncome back for /ship", owner=KIND["guard"], bsize=12.5,
        tsize=16)

    frame(1630, 1750, 1030, 300, "Up, down, status · make, from the control repo", FRAME["boot"],
          size=20)
    rest = [
        ("make dev-down", "dev-down.yml when VIA=ci\n(workflow_dispatch, confirm)\ndestroy with "
         "the infra that\ndeployed dev, then prove\nnothing billable is left", KIND["deploy"]),
        ("make dev-up", "dev-push.yml dispatched with\nlock=true: every repo at\nmain's "
         "repos.lock\n(a cold start ~25 min)", KIND["deploy"]),
        ("make dev-status · dev-index", "last deploys and teardowns,\nwhat dev runs now;\n"
         "OpenSearch counts", KIND["report"]),
        ("release-prod.yml", "VACANT: one account, it is\ndev; only main may release\nthe day "
         "prod exists", KIND["report"]),
    ]
    box(1650, 1795, 330, 240, rest[0][0], rest[0][1], owner=rest[0][2], bsize=13)
    box(1995, 1795, 315, 240, rest[1][0], rest[1][1], owner=rest[1][2], bsize=13)
    box(2325, 1795, 315, 112, rest[2][0], rest[2][1], owner=rest[2][2], bsize=12.5, tsize=16)
    box(2325, 1922, 315, 112, rest[3][0], rest[3][1], owner=rest[3][2], bsize=12.5, tsize=16)

    # Legend ------------------------------------------------------------------------------------
    LY = 2075
    lx = 40
    for name, fill in KIND.items():
        E.append(dict(kind="rect", id=f"key-{name}", x=lx, y=LY, w=34, h=24, fill=fill,
                      dashed=False, stroke=INK, sw=1.5))
        text(lx + 44, LY + 1, name, 16)
        lx += 70 + len(name) * 9
    text(lx + 30, LY + 1, "Exit codes everywhere: 0 pass · 1 the thing under test failed · "
                          "2 the harness refused (docs/adr/0003)", 16, color="#495057")
