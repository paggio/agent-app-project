#!/usr/bin/env bash
# Run one infra target with its exit code intact.
#
#   ./scripts/infra.sh <target> [VAR=value ...]     e.g.  ./scripts/infra.sh outputs ENV=dev
#
# The machine interface is `infra/bin/infra`, never `make -C infra`: GNU make exits 2 for
# any failing recipe, so `plan`'s 3 (destroys) and `outputs`' 1 (no state) never reached a
# caller. /dev-push run 35880296151 refused a first deploy on exactly that — "no state for
# dev" arrived as 2. infra/docs/adr/0003; check-docs.py [infra-invocation] holds it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/infra/bin/infra"
if [ ! -x "$BIN" ]; then
  echo "infra: $BIN is missing or not executable — the checked-out infra predates bin/infra," >&2
  echo "infra: or infra/ is not checked out. docs/infra-interface.md." >&2
  exit 2
fi
exec "$BIN" "$@"
