#!/usr/bin/env bash
# DELETE de TODAS as personas/dados de teste com email @viralefy.test.
# Ordem importa por FK: reviews → orders → profiles → subscriptions →
# credit_accounts → users → admins.
# Idempotente: re-rodar não erra.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_DIR/_lib.sh"

echo "▶ limpando seeds @viralefy.test"

# tables que podem não existir em ambientes antigos — try/skip silencioso.
# (-v ON_ERROR_STOP=1 não está setado aqui pra cada query ser independente).
psql_try() {
  local sql="$1"
  if [[ -n "${VIRALEFY_DB_URL:-}" ]]; then
    psql "$VIRALEFY_DB_URL" -Atc "$sql" 2>/dev/null || true
  else
    PGPASSWORD="${PGPASSWORD:-}" psql \
      -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" \
      -U "${PGUSER:-viralefy}" -d "${PGDATABASE:-viralefy}" \
      -Atc "$sql" 2>/dev/null || true
  fi
}

psql_try "DELETE FROM reviews         WHERE user_id IN (SELECT id FROM users  WHERE email LIKE '%@viralefy.test')"
psql_try "DELETE FROM orders          WHERE user_id IN (SELECT id FROM users  WHERE email LIKE '%@viralefy.test')"
psql_try "DELETE FROM profiles        WHERE user_id IN (SELECT id FROM users  WHERE email LIKE '%@viralefy.test')"
psql_try "DELETE FROM subscriptions   WHERE user_id IN (SELECT id FROM users  WHERE email LIKE '%@viralefy.test')"
psql_try "DELETE FROM credit_transactions WHERE user_id IN (SELECT id FROM users WHERE email LIKE '%@viralefy.test')"
psql_try "DELETE FROM credit_accounts WHERE user_id IN (SELECT id FROM users WHERE email LIKE '%@viralefy.test')"
psql_try "DELETE FROM invoices        WHERE user_id IN (SELECT id FROM users  WHERE email LIKE '%@viralefy.test')"
psql_try "DELETE FROM users           WHERE email LIKE '%@viralefy.test'"
psql_try "DELETE FROM admins          WHERE email LIKE '%@viralefy.test'"
psql_try "DELETE FROM revoked_jtis    WHERE revoked_reason LIKE 'authz-test-%'"

echo "✓ clean-seeds completo"
