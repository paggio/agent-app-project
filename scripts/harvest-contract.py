#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx>=0.27", "pyyaml>=6"]
# ///
"""Compare what a service actually serves against what contracts/ promises.

Writing OpenAPI by hand to describe an endpoint that already exists is tedious and
error-prone, and the tedium is why contracts drift. FastAPI already publishes an exact
spec at /openapi.json, so the draft can be taken from the running service rather than
retyped or inferred from source.

What this tool does NOT do is decide. The contract stays a promise the control repo
makes on behalf of every consumer; if it were auto-accepted from the implementation it
would become a description of whatever the backend happens to do — including the
accidents — and could never fail a build again, which is the entire point of
docs/adr/0001. So:

  harvest drafts, and classifies. A human decides. Breaking changes are never
  written without being named out loud first.

Direction matters when classifying, and it is the reason this is worth more than a diff:
adding a REQUIRED field to a request breaks callers, while adding one to a response is
harmless. Removing a field from a response breaks consumers, while removing one from a
request does not. The same textual change is safe in one direction and an outage in the
other.

  harvest-contract.py --diff                     what changed, and what it would break
  harvest-contract.py --write                    draft it in, refusing breaking changes
  harvest-contract.py --write --accept-breaking  ... after you have decided, deliberately
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any

import httpx
import yaml

ADDITIVE, BREAKING, INFO = "additive", "BREAKING", "note"


class Finding:
    def __init__(self, kind: str, where: str, detail: str) -> None:
        self.kind, self.where, self.detail = kind, where, detail

    def __str__(self) -> str:
        mark = {ADDITIVE: "+", BREAKING: "!", INFO: " "}[self.kind]
        return f"  {mark} {self.where}\n      {self.detail}"


def strip_property_titles(node: Any) -> Any:
    """Drop Pydantic's per-field `title`, which is noise in a promise.

    Pydantic emits a title for every field, titleized from the attribute name — `Error
    Type`, `Location`, `Msg`. It carries nothing the property name does not, and client
    generators surface it. Schema-level titles are kept: those name the type, and
    generators use them for the generated class names.
    """
    if isinstance(node, dict):
        for prop in (node.get("properties") or {}).values():
            if isinstance(prop, dict):
                prop.pop("title", None)
        for value in node.values():
            strip_property_titles(value)
    elif isinstance(node, list):
        for value in node:
            strip_property_titles(value)
    return node


def load_live(source: str) -> dict:
    if source.startswith(("http://", "https://")):
        try:
            resp = httpx.get(source, timeout=15)
            resp.raise_for_status()
        except httpx.HTTPError as exc:
            print(f"harvest: could not fetch {source}: {exc}", file=sys.stderr)
            print("harvest: is the stack up? try `make up`", file=sys.stderr)
            raise SystemExit(2)
        return strip_property_titles(resp.json())
    with open(source) as fh:
        raw = json.load(fh) if source.endswith(".json") else yaml.safe_load(fh)
    return strip_property_titles(raw)


def deref(schema: Any, spec: dict, seen: tuple = ()) -> Any:
    """Resolve $ref one level at a time, refusing to loop on recursive schemas."""
    if not isinstance(schema, dict):
        return schema
    ref = schema.get("$ref")
    if not ref or not ref.startswith("#/components/schemas/"):
        return schema
    name = ref.rsplit("/", 1)[-1]
    if name in seen:
        return {}
    target = (spec.get("components", {}).get("schemas", {}) or {}).get(name, {})
    return deref(target, spec, seen + (name,))


def body_schema(op: dict, spec: dict) -> dict:
    content = (op.get("requestBody") or {}).get("content") or {}
    return deref((content.get("application/json") or {}).get("schema") or {}, spec)


def response_schema(op: dict, status: str, spec: dict) -> dict:
    resp = (op.get("responses") or {}).get(status) or {}
    content = resp.get("content") or {}
    return deref((content.get("application/json") or {}).get("schema") or {}, spec)


def compare_fields(where: str, old: dict, new: dict, direction: str) -> list[Finding]:
    """direction is 'request' or 'response' — it decides what counts as breaking."""
    out: list[Finding] = []
    old_props = (old or {}).get("properties") or {}
    new_props = (new or {}).get("properties") or {}
    old_req = set((old or {}).get("required") or [])
    new_req = set((new or {}).get("required") or [])

    for name in sorted(set(new_props) - set(old_props)):
        if direction == "request" and name in new_req:
            out.append(Finding(BREAKING, where,
                               f"request gains REQUIRED field '{name}' — existing callers "
                               f"that do not send it would start failing"))
        else:
            out.append(Finding(ADDITIVE, where, f"{direction} gains field '{name}'"))

    for name in sorted(set(old_props) - set(new_props)):
        if direction == "response":
            out.append(Finding(BREAKING, where,
                               f"response no longer returns '{name}' — consumers reading it "
                               f"would break"))
        else:
            out.append(Finding(ADDITIVE, where, f"request no longer reads '{name}'"))

    for name in sorted(set(old_props) & set(new_props)):
        o, n = old_props[name], new_props[name]
        if o.get("type") != n.get("type"):
            out.append(Finding(BREAKING, where,
                               f"'{name}' changes type {o.get('type')} -> {n.get('type')}"))
        if o.get("const") != n.get("const") and (o.get("const") or n.get("const")):
            out.append(Finding(BREAKING, where,
                               f"'{name}' changes fixed value {o.get('const')!r} -> "
                               f"{n.get('const')!r}"))
        if direction == "request" and name not in old_req and name in new_req:
            out.append(Finding(BREAKING, where,
                               f"'{name}' becomes required in the request"))
    return out


def compare(contract: dict, live: dict) -> list[Finding]:
    out: list[Finding] = []
    c_paths = contract.get("paths") or {}
    l_paths = live.get("paths") or {}

    for path in sorted(set(l_paths) - set(c_paths)):
        methods = ", ".join(m.upper() for m in l_paths[path] if m != "parameters")
        out.append(Finding(ADDITIVE, path, f"served but never promised ({methods})"))

    for path in sorted(set(c_paths) - set(l_paths)):
        out.append(Finding(BREAKING, path,
                           "promised in the contract but NOT served — either the "
                           "implementation dropped it or this spec is for the wrong service"))

    for path in sorted(set(c_paths) & set(l_paths)):
        c_ops, l_ops = c_paths[path] or {}, l_paths[path] or {}
        for m in sorted(set(l_ops) - set(c_ops)):
            if m == "parameters":
                continue
            out.append(Finding(ADDITIVE, f"{m.upper()} {path}", "served but never promised"))
        for m in sorted(set(c_ops) - set(l_ops)):
            if m == "parameters":
                continue
            out.append(Finding(BREAKING, f"{m.upper()} {path}",
                               "promised but no longer served"))

        for m in sorted(set(c_ops) & set(l_ops)):
            if m == "parameters":
                continue
            where = f"{m.upper()} {path}"
            c_op, l_op = c_ops[m] or {}, l_ops[m] or {}

            c_status = set((c_op.get("responses") or {}))
            l_status = set((l_op.get("responses") or {}))
            for s in sorted(l_status - c_status):
                out.append(Finding(ADDITIVE, where, f"returns undeclared status {s}"))
            for s in sorted(c_status - l_status):
                out.append(Finding(BREAKING, where,
                                   f"declares status {s} that is no longer returned"))

            out += compare_fields(f"{where} (request)",
                                  body_schema(c_op, contract), body_schema(l_op, live),
                                  "request")
            for s in sorted(c_status & l_status):
                if not s.startswith("2"):
                    continue
                out += compare_fields(f"{where} -> {s}",
                                      response_schema(c_op, s, contract),
                                      response_schema(l_op, s, live),
                                      "response")
    return out


# Prose the control repo writes for consumers, which must survive a re-harvest. The
# generated equivalents describe the implementation — "Run one turn through the agent
# graph", "Successful Response", operationIds mangled from Python function names — and
# a consumer generating a client from this file should not inherit any of that.
PROSE = {"summary", "description", "operationId", "tags", "example", "examples"}


def preserve_prose(old: Any, new: Any) -> Any:
    """Structure comes from the implementation; wording stays whatever a human wrote.

    Without this, every harvest would overwrite the reviewed contract with FastAPI's
    autogenerated wording, and the review would have to be redone each time — which is
    how a tool meant to reduce drift starts causing it.
    """
    if not isinstance(old, dict) or not isinstance(new, dict):
        return new
    out = dict(new)
    for key, old_val in old.items():
        if key in PROSE and old_val not in (None, "", []):
            out[key] = old_val
        elif key in new:
            out[key] = preserve_prose(old_val, new[key])
    return out


def merge(contract: dict, live: dict) -> dict:
    """The harvest owns structure. The control repo owns the promise and its wording."""
    merged = dict(contract)
    merged["openapi"] = live.get("openapi", contract.get("openapi", "3.1.0"))
    # info and servers describe the PROMISE, not one service's build — keep ours.
    merged.setdefault("info", contract.get("info") or {})
    if contract.get("servers"):
        merged["servers"] = contract["servers"]

    merged["paths"] = preserve_prose(contract.get("paths") or {}, live.get("paths") or {})
    components = dict(contract.get("components") or {})
    components["schemas"] = preserve_prose(
        (contract.get("components") or {}).get("schemas") or {},
        (live.get("components") or {}).get("schemas") or {},
    )
    merged["components"] = components
    return merged


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--from", dest="source", default="http://localhost:8000/openapi.json",
                    help="a running service's spec URL, or a local .json/.yaml file")
    ap.add_argument("--contract", default="contracts/openapi.yaml")
    ap.add_argument("--diff", action="store_true", help="report only (the default)")
    ap.add_argument("--write", action="store_true", help="draft the changes into the contract")
    ap.add_argument("--accept-breaking", action="store_true",
                    help="allow --write to apply breaking changes, having decided to")
    ap.add_argument("--json", dest="json_out")
    args = ap.parse_args()

    live = load_live(args.source)
    contract = {}
    if os.path.exists(args.contract):
        contract = yaml.safe_load(open(args.contract)) or {}

    findings = compare(contract, live)
    breaking = [f for f in findings if f.kind == BREAKING]
    additive = [f for f in findings if f.kind == ADDITIVE]

    print(f"harvest: {args.source}")
    print(f"harvest: against {args.contract}"
          f"{' (promises nothing yet)' if not contract.get('paths') else ''}")
    print()
    if not findings:
        print("  the contract and the implementation agree.")
    if additive:
        print(f"Additive — safe to promise ({len(additive)}):")
        for f in additive:
            print(f)
        print()
    if breaking:
        print(f"BREAKING — a consumer would break ({len(breaking)}):")
        for f in breaking:
            print(f)
        print()
        print("  These are decisions, not diffs. Expand-and-contract instead: add the new")
        print("  shape alongside the old, migrate every consumer, remove the old in a later")
        print("  change. See the freeze-contract skill.")
        print()

    if args.json_out:
        with open(args.json_out, "w") as fh:
            json.dump({
                "source": args.source, "contract": args.contract,
                "ok": not breaking,
                "additive": [{"where": f.where, "detail": f.detail} for f in additive],
                "breaking": [{"where": f.where, "detail": f.detail} for f in breaking],
            }, fh, indent=2)

    if args.write:
        if breaking and not args.accept_breaking:
            print("harvest: refusing to write — the changes above are breaking.")
            print("harvest: decide first, then re-run with --accept-breaking.")
            return 1
        merged = merge(contract, live)
        with open(args.contract, "w") as fh:
            fh.write("# Frozen interface. Owned by this repo; product repos consume it.\n")
            fh.write("# Drafted with ./scripts/harvest-contract.py, then reviewed by hand —\n")
            fh.write("# the draft comes from the implementation, the promise does not.\n")
            fh.write("# Editing note: this file is rewritten on --write, so comments inside\n")
            fh.write("# it do not survive. Durable guidance belongs in contracts/README.md.\n\n")
            yaml.safe_dump(merged, fh, sort_keys=False, width=100, allow_unicode=True)
        print(f"harvest: wrote {args.contract}")
        print("harvest: review the diff, then commit it ALONE — the commit IS the freeze.")
        return 0

    return 1 if breaking else 0


if __name__ == "__main__":
    raise SystemExit(main())
