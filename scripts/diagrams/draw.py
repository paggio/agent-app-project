"""Primitives and the hand-drawn renderer shared by every diagram scene."""

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
INTER = {False: os.path.join(HERE, "Inter-Regular.woff2"),  # Inter (Latin subset), SIL OFL 1.1
         True: os.path.join(HERE, "Inter-SemiBold.woff2")}

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
# The clean style's tones: (fill, stroke).
TONE = {"gray": ("#f8f9fa", "#adb5bd"), "blue": ("#e7f5ff", "#339af0"),
        "green": ("#ebfbee", "#40c057"), "yellow": ("#fff9db", "#f59f00"),
        "violet": ("#f3f0ff", "#7950f2"), "red": ("#fff5f5", "#fa5252"),
        "orange": ("#fff4e6", "#fd7e14"), "white": ("#ffffff", "#ced4da")}
# The clean style's owner accent: the strip down a card's left edge, and the legend.
ACCENT = {"frontend": "#339af0", "chatbot-backend": "#37b24d", "metrics-gateway": "#f59f00",
          "analytics-dbt": "#f03e3e", "chatbot-eval": "#7950f2", "infra": "#12b886",
          "third-party image": "#fd7e14", "AWS managed": "#868e96"}
FRAME = {"aws": "#fff4e6", "vpc": "#ebfbee", "eks": "#e7f5ff", "ns": "#f8f9fa",
         "gh": "#f3f0ff", "boot": "#f1f3f5", "edge": "#fff9db", "pub": "#ffffff"}
# The clean style's frames, keyed by the sketch fill: (fill, stroke, label colour).
FRAME_CLEAN = {"#fff4e6": ("#fffaf3", "#ffd8a8", "#d9480f"), "#ebfbee": ("#f5fcf6", "#b2f2bb", "#2b8a3e"),
               "#e7f5ff": ("#f3f9ff", "#a5d8ff", "#1864ab"), "#f8f9fa": ("#ffffff", "#dee2e6", "#495057"),
               "#f3f0ff": ("#f9f7ff", "#d0bfff", "#6741d9"), "#f1f3f5": ("#f8f9fa", "#dee2e6", "#495057"),
               "#fff9db": ("#fffdf2", "#ffe066", "#e67700"), "#ffffff": ("#ffffff", "#b2f2bb", "#2b8a3e")}

LH = 1.25                   # line height, in font sizes; build.py sets it per style
E: list[dict] = []          # the scene being drawn, in draw order
_n = 0


def reset() -> None:
    global _n
    E.clear()
    _n = 0


def _id(prefix: str) -> str:
    global _n
    _n += 1
    return f"{prefix}-{_n}"


def frame(x, y, w, h, label, fill, dashed=True, size=20):
    E.append(dict(kind="rect", id=_id("frame"), x=x, y=y, w=w, h=h, fill=fill,
                  dashed=dashed, stroke="#868e96" if dashed else INK, sw=2, frame=True))
    text(x + 14, y + 10, label, size, color="#495057", bold=True)
    E[-1]["frame_of"] = fill


def box(x, y, w, h, title, body="", owner="AWS managed", drum=False, tsize=18, bsize=13.5,
        align="center"):
    gid = _id("g")
    fill, stroke = TONE[owner] if owner in TONE else (OWNER.get(owner, owner), INK)
    E.append(dict(kind="rect", id=_id("box"), x=x, y=y, w=w, h=h, fill=fill,
                  dashed=False, stroke=stroke, sw=2, group=gid, owner=owner, drum=drum))
    top = y + 10
    if drum:                      # a datastore: the drum's lid
        E.append(dict(kind="line", id=_id("lid"), pts=[(x, y + 14), (x + w, y + 14)],
                      stroke=INK, sw=1.5, group=gid))
        top = y + 20
    tx = x + w / 2 if align == "center" else x + 16
    text(tx, top, title, tsize, align=align, group=gid, bold=True)
    if body:
        text(tx, top + tsize * LH * (title.count("\n") + 1) + 5, body, bsize, align=align,
             group=gid, color="#343a40")
    return (x, y, w, h)


def text(x, y, s, size, align="left", color=INK, group=None, bold=False):
    E.append(dict(kind="text", id=_id("t"), x=x, y=y, s=s, size=size, align=align,
                  color=color, group=group, bold=bold))


def arrow(pts, label=None, dashed=False, at=None, both=False, color=INK):
    E.append(dict(kind="arrow", id=_id("a"), pts=pts, label=label, dashed=dashed,
                  at=at, both=both, color=color))


def mid(b, side, t=0.5):
    x, y, w, h = b
    return {"l": (x, y + h * t), "r": (x + w, y + h * t),
            "t": (x + w * t, y), "b": (x + w * t, y + h)}[side]



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


def render_svg(font, font_b64, digest, W, H):
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" '
           f'height="{H}">',
           f"<!-- generated by scripts/diagrams/build.py · source-sha256: {digest} -->",
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


def _rounded(pts, r=10):
    """An orthogonal polyline with its corners rounded."""
    d = f"M{pts[0][0]:.1f} {pts[0][1]:.1f}"
    for (ax, ay), (bx, by), (cx, cy) in zip(pts, pts[1:], pts[2:]):
        l1, l2 = math.dist((ax, ay), (bx, by)), math.dist((bx, by), (cx, cy))
        k = min(r, l1 / 2, l2 / 2)
        p = (bx - (bx - ax) / l1 * k, by - (by - ay) / l1 * k) if l1 else (bx, by)
        q = (bx + (cx - bx) / l2 * k, by + (cy - by) / l2 * k) if l2 else (bx, by)
        d += f" L{p[0]:.1f} {p[1]:.1f} Q{bx:.1f} {by:.1f} {q[0]:.1f} {q[1]:.1f}"
    return d + f" L{pts[-1][0]:.1f} {pts[-1][1]:.1f}"


def _cylinder(x, y, c):
    """A small datastore glyph, 16 wide, its top-left at x, y."""
    return (f'<g fill="none" stroke="{c}" stroke-width="1.4"><ellipse cx="{x + 8}" cy="{y + 3}" '
            f'rx="8" ry="3"/><path d="M{x} {y + 3} V{y + 15} A8 3 0 0 0 {x + 16} {y + 15} V{y + 3}"/>'
            f'<path d="M{x} {y + 9} A8 3 0 0 0 {x + 16} {y + 9}"/></g>')


def render_clean_svg(fonts, fonts_b64, digest, W, H):
    """Flat rendering in Inter: soft frames, white cards with an owner strip, rounded arrows."""
    face = "".join("@font-face{font-family:Inter;font-weight:%d;src:url(data:font/woff2;base64,%s)"
                   " format('woff2');}" % (600 if b else 400, fonts_b64[b]) for b in (False, True))
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" '
           f'height="{H}">',
           f"<!-- generated by scripts/diagrams/build.py · source-sha256: {digest} -->",
           f"<defs><style>{face}text{{font-family:Inter,sans-serif;white-space:pre}}</style>"
           '<filter id="sh" x="-10%" y="-10%" width="120%" height="130%"><feDropShadow dx="0" '
           'dy="1.5" stdDeviation="2.2" flood-color="#1b2a3a" flood-opacity="0.10"/></filter></defs>',
           f'<rect width="{W}" height="{H}" fill="#ffffff"/>']
    n = 0
    for e in E:
        if e["kind"] == "rect" and e.get("frame"):
            fill, stroke, _ = FRAME_CLEAN.get(e["fill"], (e["fill"], "#dee2e6", INK))
            dash = ' stroke-dasharray="7 6"' if e["dashed"] and e["fill"] in ("#ffffff", "#f8f9fa") else ""
            out.append(f'<rect x="{e["x"]}" y="{e["y"]}" width="{e["w"]}" height="{e["h"]}" rx="18" '
                       f'fill="{fill}" stroke="{stroke}" stroke-width="1.5"{dash}/>')
        elif e["kind"] == "rect" and e.get("owner") in ACCENT:
            n += 1
            x, y, w, h, c = e["x"], e["y"], e["w"], e["h"], ACCENT[e["owner"]]
            out.append(f'<clipPath id="c{n}"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10"/>'
                       f'</clipPath><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" '
                       f'fill="#ffffff" stroke="#dee2e6" stroke-width="1" filter="url(#sh)"/>'
                       f'<rect x="{x}" y="{y}" width="5" height="{h}" fill="{c}" clip-path="url(#c{n})"/>')
            if e.get("drum"):
                out.append(_cylinder(x + w - 28, y + 12, c))
        elif e["kind"] == "rect":
            dash = ' stroke-dasharray="6 6"' if e["dashed"] else ""
            out.append(f'<rect x="{e["x"]}" y="{e["y"]}" width="{e["w"]}" height="{e["h"]}" rx="12" '
                       f'fill="{e["fill"]}" stroke="{e["stroke"]}" stroke-width="1.5"{dash}/>')
        elif e["kind"] == "line":
            if e["id"].startswith("lid"):
                continue                          # a datastore is the glyph on its card
            (x1, y1), (x2, y2) = e["pts"]
            out.append(f'<path d="M{x1} {y1} L{x2} {y2}" stroke="{e["stroke"]}" stroke-width="1"/>')
        elif e["kind"] == "text":
            anchor = "middle" if e["align"] == "center" else "start"
            color = FRAME_CLEAN[e["frame_of"]][2] if e.get("frame_of") in FRAME_CLEAN else e["color"]
            lh = e["size"] * LH
            tsp = "".join(f'<tspan x="{e["x"]:.1f}" y="{e["y"] + e["size"] + i * lh:.1f}">'
                          f'{esc(ln)}</tspan>' for i, ln in enumerate(e["s"].split("\n")))
            out.append(f'<text font-size="{e["size"]}" font-weight="{600 if e.get("bold") else 400}" '
                       f'fill="{color}" text-anchor="{anchor}">{tsp}</text>')
        elif e["kind"] == "arrow":
            pts, c = e["pts"], e.get("color", INK)
            c = "#495057" if c == INK else c
            (ax, ay), (bx, by) = pts[-2], pts[-1]
            ang = math.atan2(by - ay, bx - ax)
            ex, ey = bx - 9 * math.cos(ang), by - 9 * math.sin(ang)
            dash = ' stroke-dasharray="6 5"' if e["dashed"] else ""
            out.append(f'<path d="{_rounded(pts[:-1] + [(ex, ey)])}" fill="none" stroke="{c}" '
                       f'stroke-width="1.8" stroke-linejoin="round" stroke-linecap="round"{dash}/>')
            hx = [(bx, by)] + [(bx - 12 * math.cos(ang + s * 0.42), by - 12 * math.sin(ang + s * 0.42))
                               for s in (1, -1)]
            out.append(f'<path d="M{hx[0][0]:.1f} {hx[0][1]:.1f} L{hx[1][0]:.1f} {hx[1][1]:.1f} '
                       f'L{hx[2][0]:.1f} {hx[2][1]:.1f} Z" fill="{c}"/>')
            if e["label"]:
                lx, ly = label_pos(e)
                tw = fonts[False].width(e["label"], 13)
                out.append(f'<rect x="{lx - tw / 2 - 8:.1f}" y="{ly - 11:.1f}" width="{tw + 16:.1f}" '
                           f'height="22" fill="#ffffff" stroke="#e9ecef" rx="11"/>')
                out.append(f'<text font-size="13" fill="{c}" text-anchor="middle">'
                           f'<tspan x="{lx:.1f}" y="{ly + 4.5:.1f}">{esc(e["label"])}</tspan></text>')
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
    return {"type": "excalidraw", "version": 2, "source": "scripts/diagrams/build.py",
            "elements": els, "appState": {"viewBackgroundColor": "#ffffff", "gridSize": None},
            "files": {}}


