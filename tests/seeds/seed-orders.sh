#!/usr/bin/env bash
# Aplica tests/seeds/test-orders.sql via psql. Idempotente.
# Pré-req: seed-users (orders referenciam users.id via FK).
set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_DIR/_lib.sh"
seeds_psql_file "$_DIR/test-orders.sql"
echo "✓ seed orders aplicado"
