"""The dev architecture: what /dev-push deploys to AWS dev."""
import draw
from draw import ACCENT, E, FRAME, _id, arrow, frame, mid, text

STYLE = "clean"
W, H = 2660, 1720


def box(*a, **k):
    """Cards read left-aligned, title over body."""
    return draw.box(*a, align="left", **k)



def scene() -> None:

    text(40, 28, "agentapp · dev architecture", 40, bold=True)
    text(42, 84, "What /dev-push deploys to AWS dev, as of change 0009 (governed metrics spoke). "
                 "Colour = the repo that owns it. Source: scripts/diagrams/architecture.py", 17,
         color="#495057")

    # Outside AWS -------------------------------------------------------------------------------
    browser = box(60, 330, 250, 90, "Browser", "the chat app\noperator@agentapp.test")
    devr = box(60, 470, 250, 90, "Developer", "Phoenix: traces, experiments\nadmin@localhost")

    frame(40, 640, 290, 590, "GitHub · Paggio/*", FRAME["gh"])
    pr = box(60, 690, 250, 80, "control repo PR", "comment /dev-push or /dev-eval")
    push = box(60, 805, 250, 165, "dev-push.yml", "deploy set: slices at feat/<change>,\n"
               "the rest at repos.lock\nbuild images -> ECR\nterraform apply · helm upgrade\n"
               "smoke via CloudFront", owner="infra", bsize=13)
    evalb = box(60, 1005, 250, 125, "dev-eval.yml", "chatbot-eval: 44 questions\nover HTTPS /api"
                "\nfixture calls -> SQS\nexperiment -> Phoenix", owner="chatbot-eval", bsize=13)
    repos = box(60, 1150, 250, 62, "6 product repos", "submodules · repos.lock", bsize=13)
    arrow([mid(pr, "b"), mid(push, "t")])
    arrow([mid(pr, "l", .7), (48, 750), (48, 1060), mid(evalb, "l", .45)])

    # AWS -----------------------------------------------------------------------------------------
    frame(370, 126, 2255, 1314, "AWS · account 740172916922 · eu-west-1 · agentapp-dev", FRAME["aws"],
          size=22)

    frame(390, 290, 265, 320, "CloudFront (global)", FRAME["edge"])
    cfa = box(405, 335, 235, 110, "app distribution", "HTTPS · HSTS · headers\n/assets/* cached\n"
              "/api/* + default: no cache", bsize=13)
    cfp = box(405, 470, 235, 115, "Phoenix distribution", "its own domain: the app's\n"
              "session cookie never\nreaches Phoenix", bsize=13)
    arrow([mid(browser, "r"), mid(cfa, "l", .4)], "HTTPS")
    arrow([mid(devr, "r"), mid(cfp, "l", .4)], "HTTPS")

    frame(680, 170, 1585, 1080, "VPC 10.42.0.0/16 · 2 AZs · nodes in eu-west-1a only", FRAME["vpc"])
    frame(700, 210, 1545, 92, "public subnets 10.42.128.0/24 · 10.42.129.0/24", FRAME["pub"], size=16)
    nat = box(2005, 220, 230, 74, "NAT gateway", "the only one · all egress", bsize=13)
    text(1150, 1215, "private subnets 10.42.0.0/19 · 10.42.32.0/19 (everything below the public band)", 16,
         color="#495057")

    vpco = box(700, 345, 200, 85, "CloudFront\nVPC origin", "", tsize=16)
    alb = box(700, 480, 200, 160, "Internal ALB :80", "admits only CloudFront's\norigin-facing prefix\n"
              "list · Host rule:\napp -> proxy\nPhoenix -> phoenix", bsize=13)
    arrow([mid(cfa, "r", .5), mid(vpco, "l", .35)])
    arrow([mid(cfp, "r", .5), mid(vpco, "l", .75)])
    arrow([mid(vpco, "b"), mid(alb, "t")])

    # EKS ---------------------------------------------------------------------------------------
    frame(920, 320, 1055, 890, "EKS agentapp-dev · Kubernetes 1.36", FRAME["eks"])
    frame(940, 362, 1015, 658, "namespace agentapp · NetworkPolicy: default-deny ingress", FRAME["ns"],
          size=17)
    C = [955, 1210, 1465, 1720]          # columns
    CW = 220
    R1, R2, R3, R4 = 420, 560, 715, 875  # rows

    proxy = box(C[0], R1, CW, 100, "proxy ×2", "Caddy :8080\n/api/* -> backend (strips /api)\n"
                "else -> frontend", owner="frontend", bsize=13)
    fe = box(C[0], R2, CW, 115, "frontend ×2", "nginx :8080\nReact SPA\ndeep links -> index.html",
             owner="frontend")
    mdb = box(C[0], R3, CW, 120, "metrics-db Job", "pre-install/upgrade hook\nas the RDS master:\n"
              "roles, DBs olist and\nsemantic_index", owner="infra", bsize=13)
    pjobs = box(C[0], R4, CW, 125, "phoenix-db ·\nphoenix-admin", "hook Jobs: Phoenix's DB,\n"
                "re-apply admin password", owner="infra", tsize=16, bsize=13)

    be = box(C[1], R1, CW, 255, "backend ×2–4", "FastAPI + LangGraph :8000\nHPA on CPU 70%\n\n"
             "coordinator picks a spoke:\ndocuments · calls\nmetrics · general\n\n"
             "chats, sessions -> RDS\nuploads -> S3 documents\nLLM -> Bedrock (via NAT)",
             owner="chatbot-backend", bsize=13)
    gw = box(C[1], R3, CW, 120, "metrics-gateway", "MCP :8080/mcp · 6 tools\nMetricFlow per project\n"
             "hybrid search\npolls current.json / 30 s", owner="metrics-gateway", tsize=17, bsize=13)
    rel = box(C[1], R4, CW, 125, "metrics-release Job", "post-hook, weight 0\nload -> dbt build -> "
              "validate\npublish <project>/<sha>/\n(analytics-dbt image)", owner="analytics-dbt",
              tsize=17, bsize=13)

    phx = box(C[2], R1, CW, 100, "phoenix ×1", ":6006 HTTP · :4317 gRPC\nprojects: chatbot-backend,\n"
              "-calls, metrics-gateway, -eval", owner="third-party image", bsize=12.5)
    osr = box(C[2], R2, CW, 115, "opensearch ×1", "StatefulSet · 2.19.1\nkb-chunks · calls-chunks\n"
              "PVC 10Gi gp3 · no auth", owner="third-party image", drum=True, bsize=13)
    trino = box(C[2], R3, CW, 120, "trino 484", "coordinator + 1 worker\non node group lake\n"
                "catalog lake = Iceberg\nmetrics_gateway: 60 s cap", owner="third-party image",
                bsize=13)
    idx = box(C[2], R4, CW, 125, "metrics-index Job", "post-hook, weight 10:\nindex, then flip "
              "current.json\nCronJob metrics-index-values\n03:17 UTC, values only",
              owner="metrics-gateway", tsize=17, bsize=12.5)

    sec = box(C[3], R1, CW, 100, "Kubernetes Secrets", "backend · db-admin · phoenix\nmetrics-db · "
              "from External\nSecrets", owner="infra", tsize=17, bsize=13)
    sim = box(C[3], R2, CW, 115, "call-simulator ×1", "backend image\nCallCompleted v1 / 60 s\n"
              "no ingress, no datastore", owner="chatbot-backend", tsize=17)
    wrk = box(C[3], R3, CW, 120, "call-worker ×1", "backend image · no HTTP\nvalidate, chunk, embed\n"
              "(bge-small, in-process)\n-> RDS calls + OpenSearch", owner="chatbot-backend", bsize=13)
    pid = box(C[3], R4, CW, 125, "Pod Identity -> IAM", "backend: S3 docs, Bedrock\nworker: SQS, DLQ, "
              "Bedrock\nsimulator: SQS send only\ntrino, release, indexer,\ngateway: buckets, Glue",
              owner="infra", tsize=17, bsize=12.5)

    arrow([mid(alb, "r", .15), (930, mid(alb, "r", .15)[1]), (930, 357), (1575, 357), mid(phx, "t")],
          "Host = Phoenix domain", at=(1460, 357))
    arrow([mid(alb, "r", .4), (C[0] - 15, mid(alb, "r", .4)[1]), (C[0] - 15, R1 + 65), (C[0], R1 + 65)])
    arrow([mid(proxy, "r", .4), (C[1], R1 + 40)], )
    arrow([mid(proxy, "b"), mid(fe, "t")])
    arrow([(C[1] + CW, R1 + 50), (C[2], R1 + 50)], dashed=True)
    arrow([(C[1] + CW, R2 + 55), (C[2], R2 + 55)])
    arrow([mid(be, "b"), mid(gw, "t")], "/mcp")
    arrow([(C[1] + CW, R3 + 60), (C[2], R3 + 60)], "SQL")
    arrow([(C[1] + CW, R4 + 30), (C[2] + 20, R3 + 120)])
    arrow([(C[3], R3 + 30), (C[2] + CW, R2 + 85)])
    text(C[1] + CW + 2, R1 + 30, "OTLP", 12, color="#495057")

    oth = [box(940, 1040, 315, 85, "external-secrets", "Secrets Manager\n-> Kubernetes Secrets",
               owner="infra", bsize=13),
           box(1270, 1040, 335, 85, "kube-system", "AWS LB controller · CoreDNS\nVPC CNI · EBS CSI · "
               "Pod Identity", owner="infra", bsize=13),
           box(1620, 1040, 335, 85, "amazon-cloudwatch", "Fluent Bit -> CloudWatch Logs\n"
               "CloudWatch agent", owner="infra", bsize=13)]
    box(940, 1140, 495, 65, "node group default", "2× Spot t3a.large (min 2, max 3)", bsize=13,
        tsize=16)
    box(1460, 1140, 495, 65, "node group lake", "1× Spot *.xlarge · taint dedicated=lake · Trino",
        bsize=13, tsize=16)

    # Data tier inside the VPC ---------------------------------------------------------------------
    rds = box(2005, 715, 240, 270, "RDS PostgreSQL 17", "db.t4g.micro · 20 GB\n\nchatbot <- backend,\n"
              "call-worker\nphoenix <- phoenix\nolist <- release (writer),\ngateway (reader)\n"
              "semantic_index <- indexer\n(writer), gateway (reader)", drum=True, bsize=13)
    s3ep = box(2005, 1035, 240, 80, "S3 gateway endpoint", "S3 never leaves the VPC", bsize=13,
               tsize=17)
    arrow([(1955, R4 + 15), (2005, R4 + 15)], "5432")
    arrow([(1975, 1075), (2005, 1075)], "S3")
    arrow([(1900, 320), mid(nat, "b", .3)], "egress")

    # Regional AWS services ------------------------------------------------------------------------
    RX, RW = 2310, 290
    bedrock = box(RX, 200, RW, 95, "Amazon Bedrock", "Claude Haiku 4.5 (eu profile)\nchat, routing, "
                  "eval judge", bsize=13)
    smgr = box(RX, 320, RW, 115, "Secrets Manager", "RDS master · phoenix-secret\nphoenix-api-key · "
               "signup code\nagentapp/dev/metrics/* (4)", bsize=13)
    sqs = box(RX, 465, RW, 140, "SQS", "agentapp-dev-calls (4 days)\nagentapp-dev-calls-dlq (14 days)"
              "\nSSE · DLQ after 3 receives", bsize=13, drum=True)
    glue = box(RX, 640, RW, 80, "AWS Glue", "agentapp_dev_funnel\n(Iceberg table catalog)", bsize=13)
    s3d = box(RX, 750, RW, 75, "S3 documents", "uploads · system of record", drum=True, bsize=13,
              tsize=17)
    s3r = box(RX, 845, RW, 95, "S3 semantic-releases", "<project>/<sha>/ bundles\n"
              "<project>/current.json", drum=True, bsize=13, tsize=17)
    s3w = box(RX, 960, RW, 75, "S3 iceberg-warehouse", "funnel Iceberg data", drum=True, bsize=13,
              tsize=17)
    cw = box(RX, 1060, RW, 90, "CloudWatch Logs", "/aws/containerinsights/\nagentapp-dev/application "
             "· 7 days", bsize=13, tsize=17)
    arrow([mid(nat, "r"), mid(bedrock, "l", .5)])
    arrow([mid(sim, "r", .45), (RX, mid(sim, "r", .45)[1])], "SendMessage", at=(2120, 597))
    arrow([(RX, 590), (C[3] + CW, R3 + 22)], "long poll", at=(2110, 650))
    arrow([mid(s3ep, "r", .3), mid(s3d, "l")])
    arrow([mid(s3ep, "r", .5), mid(s3r, "l")])
    arrow([mid(s3ep, "r", .7), mid(s3w, "l")])

    # Bootstrap ----------------------------------------------------------------------------------
    frame(390, 1270, 2215, 150, "bootstrap · survives make dev-down · cents a month", FRAME["boot"])
    BX, BW, BY = [405, 772, 1139, 1506, 1873, 2240], 352, 1310
    box(BX[0], BY, BW, 95, "S3 tfstate", "agentapp-tfstate-<account>-eu-west-1", bsize=13)
    ecr = box(BX[1], BY, BW, 95, "ECR agentapp/*", "chatbot-backend · frontend · frontend-proxy\n"
              "analytics-dbt · metrics-gateway", bsize=13)
    box(BX[2], BY, BW, 95, "IAM deployer role", "assumed by CI with your SSO session\n"
        "(make login && make push-gh-creds)", bsize=13)
    box(BX[3], BY, BW, 95, "Budget · cost export", "CUR -> S3 cost bucket\nAthena + Glue "
        "agentapp_cost", bsize=13)
    box(BX[4], BY, BW, 95, "operator-password", "Secrets Manager\nthe one dev login (app + Phoenix)",
        bsize=13)
    box(BX[5], BY, BW - 2, 95, "resource group", "+ CloudWatch dashboard", bsize=13)

    arrow([mid(push, "r", .25), (920, 846)], "terraform apply · helm upgrade --wait", at=(660, 832))
    arrow([mid(push, "r", .7), (ecr[0] + 60, BY)], "build + push images", at=(610, 1095))
    arrow([(1100, 1210), (ecr[0] + 250, BY)], "pull images", dashed=True, at=(1080, 1240))

    # Legend and upkeep ----------------------------------------------------------------------------
    LY = 1470
    text(40, LY, "Colour = owning repo", 20, bold=True)
    lx = 40
    for name, fill in ACCENT.items():
        E.append(dict(kind="rect", id=_id("key"), x=lx, y=LY + 44, w=18, h=18, fill=fill,
                      dashed=False, stroke=fill, sw=1.5))
        text(lx + 44, LY + 41, name, 16)
        lx += 60 + len(name) * 9.5
    arrow([(40, LY + 100), (110, LY + 100)])
    text(122, LY + 89, "request / data", 16)
    arrow([(290, LY + 100), (360, LY + 100)], dashed=True)
    text(372, LY + 89, "telemetry · image pull", 16)
    E.append(dict(kind="rect", id=_id("key"), x=600, y=LY + 82, w=40, h=36, fill="#ffffff",
                  dashed=False, stroke="#dee2e6", sw=1, owner="AWS managed", drum=True))
    text(652, LY + 89, "holds state", 16)
    text(40, LY + 140, "Every arrow inside the namespace is a NetworkPolicy allow rule. "
         "Prose and reasons: docs/deployment.md · infra/docs/architecture.md", 16, color="#495057")

    box(1700, LY - 5, 925, 150, "Keeping it current",
        "This picture is generated: edit scripts/diagrams/architecture.py, then make diagrams.\n"
        "check-docs.py [diagrams] fails when a repo in .gitmodules or a workload in\n"
        "infra's chart is missing from it, or when this SVG was not rebuilt from the script.\n"
        "make check and /realign run that check. The hand-drawn version: tag diagrams/architecture-sketch-v1.",
        owner="infra", bsize=15, tsize=19)

