#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["fonttools>=4.50", "brotli>=1.1"]
# ///
"""The dev architecture diagram: this file is its only source.

Writes architecture.svg (rendered hand-drawn, Excalifont embedded, what README.md shows) and
architecture.excalidraw (the same scene, to open at excalidraw.com). `make architecture`.
check-docs.py [architecture] fails when a repo or a chart workload is missing from the scene,
or when the SVG was not rebuilt from this file. Edit the layout below, never the outputs.
"""
from __future__ import annotations

import base64
import hashlib
import io
import json
import math
import os
import random
import sys

from fontTools import subset
from fontTools.ttLib import TTFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
FONT = os.path.join(HERE, "Excalifont-Regular.woff2")  # Excalidraw's Excalifont (Latin subset), SIL OFL 1.1

# Excalidraw's palette. Fill = the repo that owns the workload (the legend).
INK = "#1e1e1e"
OWNER = {
    "frontend": "#a5d8ff",
    "chatbot-backend": "#b2f2bb",
    "metrics-gateway": "#ffec99",
    "analytics-dbt": "#ffc9c9",
    "chatbot-eval": "#d0bfff",
    "infra": "#e9ecef",
    "third-party image": "#ffd8a8",
    "AWS managed": "#ffffff",
}
FRAME = {"aws": "#fff4e6", "vpc": "#ebfbee", "eks": "#e7f5ff", "ns": "#f8f9fa",
         "gh": "#f3f0ff", "boot": "#f1f3f5", "edge": "#fff9db", "pub": "#ffffff"}

E: list[dict] = []          # the scene, in draw order
_n = 0


def _id(prefix: str) -> str:
    global _n
    _n += 1
    return f"{prefix}-{_n}"


def frame(x, y, w, h, label, fill, dashed=True, size=20):
    E.append(dict(kind="rect", id=_id("frame"), x=x, y=y, w=w, h=h, fill=fill,
                  dashed=dashed, stroke="#868e96" if dashed else INK, sw=2))
    text(x + 14, y + 10, label, size, color="#495057")


def box(x, y, w, h, title, body="", owner="AWS managed", drum=False, tsize=18, bsize=13.5):
    gid = _id("g")
    E.append(dict(kind="rect", id=_id("box"), x=x, y=y, w=w, h=h, fill=OWNER[owner],
                  dashed=False, stroke=INK, sw=2, group=gid))
    top = y + 10
    if drum:                      # a datastore: the drum's lid
        E.append(dict(kind="line", id=_id("lid"), pts=[(x, y + 14), (x + w, y + 14)],
                      stroke=INK, sw=1.5, group=gid))
        top = y + 20
    text(x + w / 2, top, title, tsize, align="center", group=gid)
    if body:
        text(x + w / 2, top + tsize * 1.25 * (title.count("\n") + 1) + 5, body, bsize, align="center", group=gid,
             color="#343a40")
    return (x, y, w, h)


def text(x, y, s, size, align="left", color=INK, group=None):
    E.append(dict(kind="text", id=_id("t"), x=x, y=y, s=s, size=size, align=align,
                  color=color, group=group))


def arrow(pts, label=None, dashed=False, at=None, both=False):
    E.append(dict(kind="arrow", id=_id("a"), pts=pts, label=label, dashed=dashed,
                  at=at, both=both))


def mid(b, side, t=0.5):
    x, y, w, h = b
    return {"l": (x, y + h * t), "r": (x + w, y + h * t),
            "t": (x + w * t, y), "b": (x + w * t, y + h)}[side]


# ---------------------------------------------------------------- the scene ------------
W, H = 2660, 1720

text(40, 28, "agentapp · dev architecture", 40)
text(42, 84, "What /dev-push deploys to AWS dev, as of change 0009 (governed metrics spoke). "
             "Fill = the repo that owns it. Source: scripts/architecture/build.py", 17,
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

arrow([mid(alb, "r", .15), (930, mid(alb, "r", .15)[1]), (930, 400), (1575, 400), mid(phx, "t")],
      "Host = Phoenix domain", at=(1330, 400))
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
text(40, LY, "Fill = owning repo", 20)
lx = 40
for name, fill in OWNER.items():
    E.append(dict(kind="rect", id=_id("key"), x=lx, y=LY + 40, w=34, h=24, fill=fill,
                  dashed=False, stroke=INK, sw=1.5))
    text(lx + 44, LY + 41, name, 16)
    lx += 60 + len(name) * 9.5
arrow([(40, LY + 100), (110, LY + 100)])
text(122, LY + 89, "request / data", 16)
arrow([(290, LY + 100), (360, LY + 100)], dashed=True)
text(372, LY + 89, "telemetry · image pull", 16)
E.append(dict(kind="rect", id=_id("key"), x=600, y=LY + 86, w=40, h=30, fill="#ffffff",
              dashed=False, stroke=INK, sw=1.5))
E.append(dict(kind="line", id=_id("lid"), pts=[(600, LY + 94), (640, LY + 94)], stroke=INK, sw=1.5))
text(652, LY + 89, "holds state", 16)
text(40, LY + 140, "Every arrow inside the namespace is a NetworkPolicy allow rule. "
     "Prose and reasons: docs/deployment.md · infra/docs/architecture.md", 16, color="#495057")

box(1700, LY - 5, 925, 150, "Keeping it current",
    "This picture is generated: edit scripts/architecture/build.py, then make architecture.\n"
    "check-docs.py [architecture] fails when a repo in .gitmodules or a workload in\n"
    "infra's chart is missing from it, or when this SVG was not rebuilt from the script.\n"
    "/ship and /realign run that check. Open architecture.excalidraw to zoom and pan.",
    owner="infra", bsize=15, tsize=19)


# ---------------------------------------------------------------- rendering ------------------
class Font:
    def __init__(self, path):
        self.f = TTFont(path)
        self.cmap = self.f.getBestCmap()
        self.hmtx = self.f["hmtx"]
        self.upm = self.f["head"].unitsPerEm

    def width(self, s, size):
        w = 0
        for ch in s:
            g = self.cmap.get(ord(ch))
            w += (self.hmtx[g][0] if g else 0.6 * self.upm)
        return w * size / self.upm


def rough_line(rng, x1, y1, x2, y2, rough=1.0):
    """roughjs' _line, twice: the hand-drawn double stroke."""
    length = math.hypot(x2 - x1, y2 - y1)
    gain = 1 if length < 200 else 0.4 if length > 500 else -0.0016668 * length + 1.233334
    off = 2.0
    if off * off * 100 > length * length:
        off = length / 10
    out = []
    for o in (off, off / 2):
        def r(v):
            return rough * gain * (rng.random() * 2 * v - v)
        mdx = 1 * 2 * (y2 - y1) / 200 + r(off)
        mdy = 1 * 2 * (x1 - x2) / 200 + r(off)
        d = 0.2 + rng.random() * 0.2
        out.append(f"M{x1 + r(o):.1f} {y1 + r(o):.1f} C{mdx + x1 + (x2 - x1) * d + r(o):.1f} "
                   f"{mdy + y1 + (y2 - y1) * d + r(o):.1f} {mdx + x1 + 2 * (x2 - x1) * d + r(o):.1f} "
                   f"{mdy + y1 + 2 * (y2 - y1) * d + r(o):.1f} {x2 + r(o):.1f} {y2 + r(o):.1f}")
    return " ".join(out)


def rough_rect(rng, x, y, w, h):
    r = min(14, w / 4, h / 4)
    sides = [(x + r, y, x + w - r, y), (x + w, y + r, x + w, y + h - r),
             (x + w - r, y + h, x + r, y + h), (x, y + h - r, x, y + r)]
    corners = [((x + w - r, y), (x + w, y), (x + w, y + r)),
               ((x + w, y + h - r), (x + w, y + h), (x + w - r, y + h)),
               ((x + r, y + h), (x, y + h), (x, y + h - r)),
               ((x, y + r), (x, y), (x + r, y))]
    parts = [rough_line(rng, *s) for s in sides]
    for (a, c, b) in corners:
        for _ in range(2):
            j = lambda: rng.uniform(-0.8, 0.8)
            parts.append(f"M{a[0] + j():.1f} {a[1] + j():.1f} Q{c[0] + j():.1f} {c[1] + j():.1f} "
                         f"{b[0] + j():.1f} {b[1] + j():.1f}")
    fill = (f"M{x + r} {y} H{x + w - r} Q{x + w} {y} {x + w} {y + r} V{y + h - r} "
            f"Q{x + w} {y + h} {x + w - r} {y + h} H{x + r} Q{x} {y + h} {x} {y + h - r} "
            f"V{y + r} Q{x} {y} {x + r} {y} Z")
    return fill, " ".join(parts)


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def label_pos(e):
    if e["at"]:
        return e["at"]
    pts = e["pts"]
    segs = list(zip(pts, pts[1:]))
    a, b = max(segs, key=lambda s: math.dist(*s))
    return ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)


def render_svg(font, font_b64, digest):
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" '
           f'height="{H}">',
           f"<!-- generated by scripts/architecture/build.py · source-sha256: {digest} -->",
           "<defs><style>@font-face{font-family:Excalifont;src:url(data:font/woff2;base64,"
           f"{font_b64}) format('woff2');}}"
           "text{font-family:Excalifont,'Segoe UI Emoji',sans-serif;white-space:pre}</style></defs>",
           f'<rect width="{W}" height="{H}" fill="#ffffff"/>']
    for e in E:
        rng = random.Random(e["id"])
        if e["kind"] == "rect":
            fill, stroke = rough_rect(rng, e["x"], e["y"], e["w"], e["h"])
            dash = ' stroke-dasharray="10 8"' if e["dashed"] else ""
            out.append(f'<path d="{fill}" fill="{e["fill"]}" stroke="none"/>')
            out.append(f'<path d="{stroke}" fill="none" stroke="{e["stroke"]}" '
                       f'stroke-width="{e["sw"] * 0.75}" stroke-linecap="round"{dash}/>')
        elif e["kind"] == "line":
            (x1, y1), (x2, y2) = e["pts"]
            out.append(f'<path d="{rough_line(rng, x1, y1, x2, y2)}" fill="none" '
                       f'stroke="{e["stroke"]}" stroke-width="{e["sw"] * 0.75}"/>')
        elif e["kind"] == "text":
            anchor = "middle" if e["align"] == "center" else "start"
            lines = e["s"].split("\n")
            lh = e["size"] * 1.25
            tsp = "".join(f'<tspan x="{e["x"]:.1f}" y="{e["y"] + e["size"] + i * lh:.1f}">'
                          f'{esc(ln)}</tspan>' for i, ln in enumerate(lines))
            out.append(f'<text font-size="{e["size"]}" fill="{e["color"]}" '
                       f'text-anchor="{anchor}">{tsp}</text>')
        elif e["kind"] == "arrow":
            pts = e["pts"]
            dash = ' stroke-dasharray="8 7"' if e["dashed"] else ""
            d = " ".join(rough_line(rng, *a, *b) for a, b in zip(pts, pts[1:]))
            (ax, ay), (bx, by) = pts[-2], pts[-1]
            ang = math.atan2(by - ay, bx - ax)
            head = " ".join(rough_line(rng, bx, by, bx - 14 * math.cos(ang + s * 0.45),
                                       by - 14 * math.sin(ang + s * 0.45), 0.4) for s in (1, -1))
            out.append(f'<path d="{d}" fill="none" stroke="{INK}" stroke-width="1.6" '
                       f'stroke-linecap="round"{dash}/>')
            out.append(f'<path d="{head}" fill="none" stroke="{INK}" stroke-width="1.6" '
                       f'stroke-linecap="round"/>')
            if e["label"]:
                lx, ly = label_pos(e)
                tw = font.width(e["label"], 14)
                out.append(f'<rect x="{lx - tw / 2 - 5:.1f}" y="{ly - 11:.1f}" width="{tw + 10:.1f}" '
                           f'height="22" fill="#ffffff" fill-opacity="0.9" rx="4"/>')
                out.append(f'<text font-size="14" fill="{INK}" text-anchor="middle">'
                           f'<tspan x="{lx:.1f}" y="{ly + 5:.1f}">{esc(e["label"])}</tspan></text>')
    out.append("</svg>")
    return "\n".join(out) + "\n"


def render_excalidraw(font):
    els = []
    seed = lambda i: int(hashlib.sha256(i.encode()).hexdigest()[:8], 16)

    def base(e, typ, x, y, w, h):
        return dict(id=e["id"], type=typ, x=x, y=y, width=w, height=h, angle=0,
                    strokeColor=INK, backgroundColor="transparent", fillStyle="solid",
                    strokeWidth=2, strokeStyle="solid", roughness=1, opacity=100,
                    groupIds=[e["group"]] if e.get("group") else [], frameId=None,
                    roundness=None, seed=seed(e["id"]), version=1, versionNonce=seed(e["id"] + "n"),
                    isDeleted=False, boundElements=None, updated=1, link=None, locked=False)

    def textel(e, s, size, x, y, align, color, container=None):
        lines = s.split("\n")
        w = max(font.width(ln, size) for ln in lines)
        h = size * 1.25 * len(lines)
        t = base(e, "text", x - (w / 2 if align == "center" else 0), y, w, h)
        t.update(strokeColor=color, text=s, originalText=s, fontSize=size, fontFamily=5,
                 textAlign=align, verticalAlign="top", containerId=container, lineHeight=1.25,
                 autoResize=True)
        return t

    for e in E:
        if e["kind"] == "rect":
            r = base(e, "rectangle", e["x"], e["y"], e["w"], e["h"])
            r.update(backgroundColor=e["fill"], strokeColor=e["stroke"], roundness={"type": 3},
                     strokeStyle="dashed" if e["dashed"] else "solid",
                     strokeWidth=1 if e["sw"] < 2 else 2)
            els.append(r)
        elif e["kind"] == "line":
            (x1, y1), (x2, y2) = e["pts"]
            ln = base(e, "line", x1, y1, x2 - x1, y2 - y1)
            ln.update(points=[[0, 0], [x2 - x1, y2 - y1]], lastCommittedPoint=None,
                      startBinding=None, endBinding=None, startArrowhead=None, endArrowhead=None,
                      strokeWidth=1)
            els.append(ln)
        elif e["kind"] == "text":
            els.append(textel(e, e["s"], e["size"], e["x"], e["y"], e["align"], e["color"]))
        elif e["kind"] == "arrow":
            (x0, y0) = e["pts"][0]
            xs = [p[0] for p in e["pts"]]
            ys = [p[1] for p in e["pts"]]
            a = base(e, "arrow", x0, y0, max(xs) - min(xs), max(ys) - min(ys))
            a.update(points=[[p[0] - x0, p[1] - y0] for p in e["pts"]], lastCommittedPoint=None,
                     startBinding=None, endBinding=None, startArrowhead=None,
                     endArrowhead="arrow", strokeStyle="dashed" if e["dashed"] else "solid")
            els.append(a)
            if e["label"]:
                lx, ly = label_pos(e)
                lab = textel(dict(id=e["id"] + "-label"), e["label"], 14, lx, ly - 9, "center",
                             INK, container=e["id"])
                a["boundElements"] = [{"id": lab["id"], "type": "text"}]
                els.append(lab)
    return {"type": "excalidraw", "version": 2, "source": "scripts/architecture/build.py",
            "elements": els, "appState": {"viewBackgroundColor": "#ffffff", "gridSize": None},
            "files": {}}


def main() -> int:
    font = Font(FONT)
    digest = hashlib.sha256(open(__file__, "rb").read() + open(FONT, "rb").read()).hexdigest()

    # Every box's text must fit its box: a clipped label is the failure nobody sees in review.
    bad = []
    boxes = [e for e in E if e["kind"] == "rect"]
    for t in (e for e in E if e["kind"] == "text" and e.get("group")):
        b = next(e for e in boxes if e.get("group") == t["group"])
        for ln in t["s"].split("\n"):
            if font.width(ln, t["size"]) > b["w"] - 12:
                bad.append(f"{ln!r} ({font.width(ln, t['size']):.0f}px) overflows a {b['w']}px box")
        if t["y"] + t["size"] * 1.25 * len(t["s"].split("\n")) > b["y"] + b["h"] + 2:
            bad.append(f"{t['s'][:30]!r}… overflows the bottom of its box")
    if bad:
        print("architecture: text does not fit:\n  " + "\n  ".join(bad), file=sys.stderr)
        return 1

    chars = "".join(sorted({c for e in E for c in (e.get("s") or e.get("label") or "")}))
    opts = subset.Options()
    opts.flavor = "woff2"
    opts.layout_features = ["*"]
    sub = subset.Subsetter(opts)
    f = TTFont(FONT)
    sub.populate(text=chars)
    sub.subset(f)
    buf = io.BytesIO()
    f.flavor = "woff2"
    f.save(buf)
    font_b64 = base64.b64encode(buf.getvalue()).decode()

    with open(os.path.join(ROOT, "architecture.svg"), "w") as fh:
        fh.write(render_svg(font, font_b64, digest))
    with open(os.path.join(ROOT, "architecture.excalidraw"), "w") as fh:
        json.dump(render_excalidraw(font), fh, indent=1)
        fh.write("\n")
    print(f"architecture: wrote architecture.svg and architecture.excalidraw ({digest[:12]})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
