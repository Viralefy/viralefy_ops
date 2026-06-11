#!/usr/bin/env bash
# Aplica TODOS os seeds na ordem correta de FK. Idempotente.
set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_DIR/_lib.sh"

for f in test-superadmin.sql test-manager.sql test-viewer.sql test-users.sql test-orders.sql; do
  echo "▶ $f"
  seeds_psql_file "$_DIR/$f"
done
echo "✓ seed-all aplicado (superadmin + manager + viewer + users + orders)"
