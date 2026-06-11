#!/usr/bin/env bash
# Security · password-hash-format
# Verifica que password_hash na tabela users segue formato seguro:
#   - bcrypt cost ≥ 12: prefixo `$2a$12$` / `$2b$12$` / `$2y$12$` (ou maior).
#   - ou argon2id:       prefixo `$argon2id$`.
# Esperado: 100% dos hashes em formato seguro; 0 plaintext / md5 / sha1.
# Falha = hash fraco ou plaintext armazenado.
#
# Requer acesso ao Postgres (psql + DB env vars). Skip se psql ausente.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "Security · password-hash-format"

if ! command -v psql >/dev/null 2>&1; then
  test_skip "psql ausente" "instale postgresql-client"
  test_summary "security/password-hash-format"
  exit $TEST_EXIT_CODE
fi

# DB env: prefere VIRALEFY_* já configurado, fallback PG* padrão.
PGHOST="${VIRALEFY_DB_HOST:-${PGHOST:-127.0.0.1}}"
PGPORT="${VIRALEFY_DB_PORT:-${PGPORT:-5432}}"
PGUSER="${VIRALEFY_DB_USER:-${PGUSER:-viralefy}}"
PGDATABASE="${VIRALEFY_DB_NAME:-${PGDATABASE:-viralefy}}"
PGPASSWORD="${VIRALEFY_DB_PASSWORD:-${PGPASSWORD:-}}"
export PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD

# Probe rápido de conectividade.
if ! psql -tAc 'SELECT 1' >/dev/null 2>&1; then
  test_skip "psql sem conectividade" "host=$PGHOST port=$PGPORT db=$PGDATABASE"
  test_summary "security/password-hash-format"
  exit $TEST_EXIT_CODE
fi

# Descobre qual tabela tem password_hash (pode ser users / admin_users).
tables="$(psql -tAc "
  SELECT table_schema || '.' || table_name
  FROM information_schema.columns
  WHERE column_name='password_hash'
    AND table_schema NOT IN ('pg_catalog','information_schema');
" 2>/dev/null | tr -d ' ')"

if [[ -z "$tables" ]]; then
  test_skip "nenhuma tabela com coluna password_hash" "schema ainda não migrado?"
  test_summary "security/password-hash-format"
  exit $TEST_EXIT_CODE
fi

while IFS= read -r tbl; do
  [[ -z "$tbl" ]] && continue
  total="$(psql -tAc "SELECT count(*) FROM $tbl WHERE password_hash IS NOT NULL" 2>/dev/null | tr -d ' ')"
  if [[ -z "$total" || "$total" == "0" ]]; then
    test_skip "$tbl sem registros com password_hash"
    continue
  fi

  # Formatos aceitos: bcrypt cost ≥ 12 OU argon2id.
  ok="$(psql -tAc "
    SELECT count(*) FROM $tbl
    WHERE password_hash ~ '^\$2[aby]\$(1[2-9]|[2-9][0-9])\\\$'
       OR password_hash ~ '^\$argon2id\$';
  " 2>/dev/null | tr -d ' ')"

  weak="$((total - ok))"

  if (( weak == 0 )); then
    test_pass "$tbl: $total/$total hashes em formato seguro"
  else
    # Amostra dos prefixos suspeitos pra diagnose (não vaza hash inteiro).
    sample="$(psql -tAc "
      SELECT DISTINCT substring(password_hash from 1 for 10)
      FROM $tbl
      WHERE password_hash IS NOT NULL
        AND password_hash !~ '^\$2[aby]\$(1[2-9]|[2-9][0-9])\\\$'
        AND password_hash !~ '^\$argon2id\$'
      LIMIT 5;
    " 2>/dev/null)"
    test_fail "$tbl: $weak/$total hashes em formato fraco" "prefixos: $sample"
  fi
done <<< "$tables"

test_summary "security/password-hash-format"
exit $TEST_EXIT_CODE
