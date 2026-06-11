#!/usr/bin/env bash
# Aplica tests/seeds/test-viewer.sql via psql. Idempotente.
set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_DIR/_lib.sh"
seeds_psql_file "$_DIR/test-viewer.sql"
echo "✓ seed viewer aplicado"
