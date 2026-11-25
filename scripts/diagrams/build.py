#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["fonttools>=4.50", "brotli>=1.1"]
# ///
"""Draw every diagram the README shows: `make diagrams`.

Each scene is a module here (architecture.py, cicd.py) and is the only source of its picture.
Writes <scene>.svg (hand-drawn, Excalifont embedded) and <scene>.excalidraw (the same scene,
to open at excalidraw.com) at the repo root. check-docs.py [diagrams] fails when an SVG was
not rebuilt from these files, or a scene leaves out something it must draw.
"""
from __future__ import annotations

import base64
import glob
import hashlib
import io
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fontTools import subset  # noqa: E402
from fontTools.ttLib import TTFont  # noqa: E402

import architecture  # noqa: E402
import cicd  # noqa: E402
import draw  # noqa: E402

SCENES = {"architecture": architecture, "cicd": cicd}


def digest() -> str:
    """What check-docs recomputes: every source file here, by name, in order."""
    h = hashlib.sha256()
    for p in sorted(glob.glob(os.path.join(draw.HERE, "*.py")) + [draw.FONT]):
        h.update(os.path.basename(p).encode() + b"\0" + open(p, "rb").read())
    return h.hexdigest()


def overflows(font: draw.Font) -> list[str]:
    """Every box's text must fit its box: a clipped label is the failure nobody sees in review."""
    bad = []
    boxes = [e for e in draw.E if e["kind"] == "rect"]
    for t in (e for e in draw.E if e["kind"] == "text" and e.get("group")):
        b = next(e for e in boxes if e.get("group") == t["group"])
        lines = t["s"].split("\n")
        for ln in lines:
            if font.width(ln, t["size"]) > b["w"] - 12:
                bad.append(f"{ln!r} ({font.width(ln, t['size']):.0f}px) overflows a {b['w']}px box")
        if t["y"] + t["size"] * 1.25 * len(lines) > b["y"] + b["h"] + 2:
            bad.append(f"{t['s'][:40]!r}… overflows the bottom of its box")
    return bad


def embedded_font(chars: str) -> str:
    opts = subset.Options()
    opts.flavor = "woff2"
    opts.layout_features = ["*"]
    f = TTFont(draw.FONT)
    sub = subset.Subsetter(opts)
    sub.populate(text=chars)
    sub.subset(f)
    buf = io.BytesIO()
    f.flavor = "woff2"
    f.save(buf)
    return base64.b64encode(buf.getvalue()).decode()


def main() -> int:
    font = draw.Font(draw.FONT)
    d = digest()
    for name, mod in SCENES.items():
        draw.reset()
        mod.scene()
        bad = overflows(font)
        if bad:
            print(f"diagrams: {name}: text does not fit:\n  " + "\n  ".join(bad), file=sys.stderr)
            return 1
        chars = "".join(sorted({c for e in draw.E for c in (e.get("s") or e.get("label") or "")}))
        with open(os.path.join(draw.ROOT, f"{name}.svg"), "w") as fh:
            fh.write(draw.render_svg(font, embedded_font(chars), d, mod.W, mod.H))
        with open(os.path.join(draw.ROOT, f"{name}.excalidraw"), "w") as fh:
            json.dump(draw.render_excalidraw(font), fh, indent=1)
            fh.write("\n")
        print(f"diagrams: wrote {name}.svg and {name}.excalidraw ({d[:12]})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
