#!/usr/bin/env bash
# authz · rbac-viewer-readonly
# Viewer tem só *:read (seed.go::seedRoles). Nenhum :write/moderate/manage.
#
# Esperado:
#   - GET /v1/admin/orders     → 200
#   - GET /v1/admin/plans      → 200
#   - GET /v1/admin/tickets    → 200
#   - POST /v1/admin/plans     → 403 (sem plans:write)
#   - POST /v1/admin/coupons   → 403 (sem coupons:write)
#   - DELETE /v1/admin/gateways/X → 403 (sem gateways:write)
#
# Pré-req: viralefy test seed-viewer.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"
# shellcheck source=../lib-authz.sh
source "$_DIR/lib-authz.sh"

test_section "authz · rbac-viewer-readonly"
authz_check_prereqs

API="$(api_base)"
TOK="$(mint_admin_token viewer | cut -f1)"
if [[ -z "$TOK" ]]; then
  test_fail "mint_admin_token viewer falhou"
  test_summary "authz/rbac-viewer-readonly"
  exit $TEST_EXIT_CODE
fi

# ─── Allowed: reads ──────────────────────────────────────────────────────
assert_http_with_token "viewer GET /v1/admin/orders"     "200" GET "$API/v1/admin/orders"     "$TOK"
assert_http_with_token "viewer GET /v1/admin/plans"      "200" GET "$API/v1/admin/plans"      "$TOK"
assert_http_with_token "viewer GET /v1/admin/gateways"   "200" GET "$API/v1/admin/gateways"   "$TOK"
assert_http_with_token "viewer GET /v1/admin/tickets"    "200" GET "$API/v1/admin/tickets"    "$TOK"
assert_http_with_token "viewer GET /v1/admin/reviews"    "200" GET "$API/v1/admin/reviews"    "$TOK"
assert_http_with_token "viewer GET /v1/admin/currencies" "200" GET "$API/v1/admin/currencies" "$TOK"
# users gated por orders:read (router.go: PermOrdersRead)
assert_http_with_token "viewer GET /v1/admin/users"      "200" GET "$API/v1/admin/users"      "$TOK"

# ─── Denied: writes ──────────────────────────────────────────────────────
PLAN_BODY='{"name":"viewer-plan-fail","followers_qty":100,"price_cents":100,"currency":"BRL"}'
assert_http_with_token "viewer POST /v1/admin/plans (write blocked)" "403" \
  POST "$API/v1/admin/plans" "$TOK" "$PLAN_BODY"
# Defensivo: se vazou
psql_q "DELETE FROM plans WHERE name='viewer-plan-fail'" >/dev/null 2>&1

COUPON_BODY='{"code":"VIEWERFAIL","discount_pct":10}'
assert_http_with_token "viewer POST /v1/admin/coupons (write blocked)" "403" \
  POST "$API/v1/admin/coupons" "$TOK" "$COUPON_BODY"
psql_q "DELETE FROM coupons WHERE code='VIEWERFAIL'" >/dev/null 2>&1

# DELETE gateway: pega o primeiro gateway pra alvo. Bloqueio pela RBAC,
# não pelo Coraza (DELETE bate antes de chegar no app em prod via dispatcher
# Rust: aceita DELETE pra /v1/admin/*).
GW_ID="$(psql_q "SELECT id FROM payment_gateways LIMIT 1")"
if [[ -n "$GW_ID" ]]; then
  assert_http_with_token "viewer DELETE /v1/admin/gateways/$GW_ID (write blocked)" "403" \
    DELETE "$API/v1/admin/gateways/$GW_ID" "$TOK"
else
  test_skip "DELETE gateway (sem gateway no DB)"
fi

# POST admins (admins:manage) — viewer não tem
NEW_ADMIN_BODY='{"email":"viewer-priv-esc@viralefy.test","name":"X","password":"SimTest!Esc12345","role":"viewer"}'
assert_http_with_token "viewer POST /v1/admin/admins (admins:manage blocked)" "403" \
  POST "$API/v1/admin/admins" "$TOK" "$NEW_ADMIN_BODY"
psql_q "DELETE FROM admins WHERE email='viewer-priv-esc@viralefy.test'" >/dev/null 2>&1

test_summary "authz/rbac-viewer-readonly"
exit $TEST_EXIT_CODE
