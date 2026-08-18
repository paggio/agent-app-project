#!/usr/bin/env bash
# Scaffold changes/NNNN-<slug>/ from the example change.
set -euo pipefail

SLUG="${1:?usage: new-change.sh <slug>}"
TEMPLATE="changes/0000-example-change"
[ -d "$TEMPLATE" ] || { echo "missing template: $TEMPLATE" >&2; exit 1; }

LAST="$(ls -1 changes 2>/dev/null | grep -Eo '^[0-9]{4}' | sort -n | tail -1)"
NEXT="$(printf '%04d' $(( 10#${LAST:-0} + 1 )))"
DEST="changes/$NEXT-$SLUG"

[ -e "$DEST" ] && { echo "already exists: $DEST" >&2; exit 1; }

cp -R "$TEMPLATE" "$DEST"
rm -rf "$DEST/runs"   # the template may carry a previous run's evidence; the copy must not

# change.yaml and smoke.yaml get the same substitution as the prose. The manifest is what
# the scripts read, so a scaffolded change that still said 0000 would dispatch and verify
# under the wrong name.
for f in "$DEST"/*.md "$DEST"/*.yaml; do
  [ -f "$f" ] || continue
  LC_ALL=C sed -i '' -e "s/0000/$NEXT/g" -e "s/<slug>/$SLUG/g" "$f" 2>/dev/null \
    || LC_ALL=C sed -i -e "s/0000/$NEXT/g" -e "s/<slug>/$SLUG/g" "$f"
done
# The example directory is named 0000-example-change; the copy is NNNN-<slug>.
LC_ALL=C sed -i '' -e "s/^change: .*/change: $NEXT-$SLUG/" "$DEST/change.yaml" 2>/dev/null \
  || LC_ALL=C sed -i -e "s/^change: .*/change: $NEXT-$SLUG/" "$DEST/change.yaml"

echo "created $DEST"
echo
echo "next:"
echo "  1. fill in BRIEF.md, and delete the slices that do not apply"
echo "  2. prune change.yaml: slices, and deploy.infra if this needs a real infra deploy"
echo "  3. write smoke.yaml — the acceptance criteria, as steps, each with an owner"
echo "  4. freeze the contract, then record the commit as freeze_sha in change.yaml"
echo
echo "then: ./scripts/iterate.sh $NEXT-$SLUG"
