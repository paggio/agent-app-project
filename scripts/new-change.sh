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

# The manifest is what the scripts read, so a scaffolded change still saying 0000 would
# dispatch and verify under the wrong name.
for f in "$DEST"/*.md "$DEST"/*.yaml; do
  [ -f "$f" ] || continue
  LC_ALL=C sed -i '' -e "s/0000/$NEXT/g" -e "s/<slug>/$SLUG/g" "$f" 2>/dev/null \
    || LC_ALL=C sed -i -e "s/0000/$NEXT/g" -e "s/<slug>/$SLUG/g" "$f"
done

# Strip the TEMPLATE-ONLY blocks; manifest.py --validate now refuses a change that still
# carries one, in STATUS.md as well as BRIEF.md.
for f in "$DEST"/*.md; do
  [ -f "$f" ] || continue
  python3 - "$f" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r"<!--\s*TEMPLATE-ONLY:.*?-->\n?", "", s, flags=re.S)
open(p, "w").write(s)
PY
done
# The example directory is named 0000-example-change; the copy is NNNN-<slug>.
LC_ALL=C sed -i '' -e "s/^change: .*/change: $NEXT-$SLUG/" "$DEST/change.yaml" 2>/dev/null \
  || LC_ALL=C sed -i -e "s/^change: .*/change: $NEXT-$SLUG/" "$DEST/change.yaml"

echo "created $DEST"
echo
echo "next: /ship $NEXT-$SLUG picks up from here — brief, criteria as steps, freeze, dispatch."
