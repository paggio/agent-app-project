#!/usr/bin/env python3
"""The product repos, read from .gitmodules — the one list. docs/adr/0020.

  repos.py names            the submodule paths, space-separated
  repos.py owner            the GitHub owner every submodule url shares
  repos.py images <repo>    that repo's images, space-separated (may be empty)
  repos.py json             {"owner": ..., "repos": {path: {"url", "images"}}}

Per submodule, `.gitmodules` carries one key git itself ignores:

  images = backend                       built from <path>/Dockerfile
  images = frontend proxy:Dockerfile.proxy   <image>[:<dockerfile>], default Dockerfile

Stdlib only, on purpose: CI reads it before uv exists, and the write guard reads the same
file. Exit 2 = .gitmodules is unreadable or inconsistent.
"""
from __future__ import annotations

import configparser
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GITMODULES = os.path.join(ROOT, ".gitmodules")


def refuse(msg: str) -> None:
    print(f"repos: {msg}", file=sys.stderr)
    raise SystemExit(2)


def load(path: str = GITMODULES) -> dict:
    cp = configparser.ConfigParser(interpolation=None)
    try:
        with open(path) as f:
            cp.read_file(f)
    except (OSError, configparser.Error) as e:
        refuse(f"cannot read {path}: {e}")
    repos: dict[str, dict] = {}
    for section in cp.sections():
        if not section.startswith("submodule "):
            continue
        s = cp[section]
        if "path" not in s or "url" not in s:
            refuse(f"[{section}] needs path and url")
        images = {}
        for tok in (s.get("images") or "").split():
            name, _, dockerfile = tok.partition(":")
            images[name] = dockerfile or "Dockerfile"
        repos[s["path"]] = {"url": s["url"], "images": images}
    return dict(sorted(repos.items()))


REPOS_INFO = load()
REPOS = tuple(REPOS_INFO)


def owner(info: dict = REPOS_INFO) -> str:
    owners = set()
    for path, r in info.items():
        m = re.search(r"github\.com[:/]([^/]+)/", r["url"])
        if not m:
            refuse(f"{path}: url {r['url']} is not a GitHub url")
        owners.add(m.group(1))
    if len(owners) != 1:
        refuse(f"submodule urls name more than one owner: {', '.join(sorted(owners))}")
    return owners.pop()


def images(repo: str) -> dict[str, str]:
    """{image: dockerfile} for one repo."""
    if repo not in REPOS_INFO:
        refuse(f"{repo} is not a submodule (one of {', '.join(REPOS)})")
    return REPOS_INFO[repo]["images"]


def all_images() -> dict[str, tuple[str, str]]:
    """{image: (repo, dockerfile)} across every repo."""
    return {img: (repo, df) for repo, r in REPOS_INFO.items() for img, df in r["images"].items()}


def main(argv: list[str]) -> None:
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "names":
        print(" ".join(REPOS))
    elif cmd == "owner":
        print(owner())
    elif cmd == "images" and len(argv) == 3:
        print(" ".join(images(argv[2])))
    elif cmd == "json":
        print(json.dumps({"owner": owner(), "repos": REPOS_INFO}, indent=2))
    else:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        raise SystemExit(2)


if __name__ == "__main__":
    main(sys.argv)
