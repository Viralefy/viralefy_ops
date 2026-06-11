#!/usr/bin/env bash
# authz · rbac-negative
# Combinações non-allowed:
#   - viewer tentando admin actions → 403
#   - manager tentando superadmin-only (admins:manage) → 403
#   - support tentando write (sem :write) → 403
#   - token expirado → 401
#   - token sem role → 401|403
#
# Falha = RBAC mais frouxo do que o seed.go::seedRoles declara.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"
# shellcheck source=../lib-authz.sh
source "$_DIR/lib-authz.sh"

test_section "authz · rbac-negative"
authz_check_prereqs

API="$(api_base)"

VIEWER_TOK="$(mint_admin_token viewer | cut -f1)"
MANAGER_TOK="$(mint_admin_token manager | cut -f1)"
SUPPORT_TOK="$(mint_admin_token support | cut -f1)"

# ─── Viewer tenta writes ────────────────────────────────────────────────
assert_http_with_token "viewer PUT /v1/admin/currencies/USD (write)" "403" \
  PUT "$API/v1/admin/currencies/USD" "$VIEWER_TOK" '{"base_rate":"5.0"}'

assert_http_with_token "viewer PATCH /v1/admin/reviews/x (moderate)" "403|404" \
  PATCH "$API/v1/admin/reviews/00000000-0000-0000-0000-000000000000" \
  "$VIEWER_TOK" '{"visible":false}'

# ─── Manager tenta admins:manage ────────────────────────────────────────
assert_http_with_token "manager GET /v1/admin/admins (manage)" "403" \
  GET "$API/v1/admin/admins" "$MANAGER_TOK"

assert_http_with_token "manager POST /v1/admin/users/x/credits/adjust (manage)" "403" \
  POST "$API/v1/admin/users/$AUTHZ_USER_A_ID/credits/adjust" "$MANAGER_TOK" \
  '{"amount_cents":1000,"reason":"test"}'

assert_http_with_token "manager POST /v1/admin/vendors (manage)" "403" \
  POST "$API/v1/admin/vendors" "$MANAGER_TOK" '{"name":"X","slug":"x"}'

# ─── Support tenta writes ───────────────────────────────────────────────
# support tem plans:read mas não plans:write
SUP_PLAN_BODY='{"name":"sup-fail","followers_qty":100,"price_cents":100,"currency":"BRL"}'
assert_http_with_token "support POST /v1/admin/plans (write)" "403" \
  POST "$API/v1/admin/plans" "$SUPPORT_TOK" "$SUP_PLAN_BODY"
psql_q "DELETE FROM plans WHERE name='sup-fail'" >/dev/null 2>&1

# ─── Token expirado ─────────────────────────────────────────────────────
EXP_TOK="$(mint_admin_token superadmin -1 | cut -f1)"
if [[ -n "$EXP_TOK" ]]; then
  assert_http_with_token "token expirado → 401" "401" \
    GET "$API/v1/admin/me" "$EXP_TOK"
else
  test_skip "mint token expirado falhou"
fi

# ─── Token mal-formado / role inválida ──────────────────────────────────
BAD_TOK="not.a.valid.jwt"
assert_http_with_token "token mal-formado → 401" "401" \
  GET "$API/v1/admin/me" "$BAD_TOK"

test_summary "authz/rbac-negative"
exit $TEST_EXIT_CODE
