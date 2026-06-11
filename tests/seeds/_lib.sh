#!/usr/bin/env bash
# tests/seeds/_lib.sh — helper compartilhado pelos wrappers seed-*.sh.
# Roda psql contra Postgres local (ou VIRALEFY_DB_URL) com ON_ERROR_STOP.

set -uo pipefail

seeds_psql_file() {
  local f="${1:?sql file required}"
  if [[ ! -f "$f" ]]; then
    echo "seeds: arquivo não encontrado: $f" >&2
    return 2
  fi
  if [[ -n "${VIRALEFY_DB_URL:-}" ]]; then
    psql "$VIRALEFY_DB_URL" -v ON_ERROR_STOP=1 -f "$f"
  else
    PGPASSWORD="${PGPASSWORD:-}" psql \
      -h "${PGHOST:-localhost}" \
      -p "${PGPORT:-5432}" \
      -U "${PGUSER:-viralefy}" \
      -d "${PGDATABASE:-viralefy}" \
      -v ON_ERROR_STOP=1 -f "$f"
  fi
}

seeds_psql_q() {
  local sql="${1:?sql required}"
  if [[ -n "${VIRALEFY_DB_URL:-}" ]]; then
    psql "$VIRALEFY_DB_URL" -v ON_ERROR_STOP=1 -Atc "$sql"
  else
    PGPASSWORD="${PGPASSWORD:-}" psql \
      -h "${PGHOST:-localhost}" \
      -p "${PGPORT:-5432}" \
      -U "${PGUSER:-viralefy}" \
      -d "${PGDATABASE:-viralefy}" \
      -v ON_ERROR_STOP=1 -Atc "$sql"
  fi
}

# vim: set ft=bash et sw=2:
