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
for f in "$DEST"/*.md; do
  LC_ALL=C sed -i '' -e "s/0000/$NEXT/g" -e "s/<slug>/$SLUG/g" "$f" 2>/dev/null \
    || LC_ALL=C sed -i -e "s/0000/$NEXT/g" -e "s/<slug>/$SLUG/g" "$f"
done

echo "created $DEST"
echo "next: fill in BRIEF.md, delete the slices that do not apply, then freeze the contract"
