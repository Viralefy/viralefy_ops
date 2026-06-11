#!/usr/bin/env bash
# authz · rbac-manager-access
# Manager tem subset (seed.go::seedRoles): plans:*, gateways:*, currencies:*,
# orders:read, tickets:*, reviews:read+moderate. SEM admins:manage.
#
# Esperado:
#   - GET /v1/admin/orders            → 200
#   - GET /v1/admin/users             → 200 (gated por orders:read)
#   - POST /v1/admin/plans            → 200|201 (plans:write)
#   - GET /v1/admin/admins            → 403 (admins:manage não)
#   - DELETE /v1/admin/admins/<id>    → 403 (não pode deletar)
#
# Pré-req: viralefy test seed-manager + seed-superadmin (pra ter id alvo
# do delete).

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"
# shellcheck source=../lib-authz.sh
source "$_DIR/lib-authz.sh"

test_section "authz · rbac-manager-access"
authz_check_prereqs

API="$(api_base)"
TOK="$(mint_admin_token manager | cut -f1)"
if [[ -z "$TOK" ]]; then
  test_fail "mint_admin_token manager falhou"
  test_summary "authz/rbac-manager-access"
  exit $TEST_EXIT_CODE
fi

# ─── Allowed reads ───────────────────────────────────────────────────────
assert_http_with_token "manager GET /v1/admin/orders"     "200" GET "$API/v1/admin/orders"     "$TOK"
assert_http_with_token "manager GET /v1/admin/users"      "200" GET "$API/v1/admin/users"      "$TOK"
assert_http_with_token "manager GET /v1/admin/plans"      "200" GET "$API/v1/admin/plans"      "$TOK"
assert_http_with_token "manager GET /v1/admin/gateways"   "200" GET "$API/v1/admin/gateways"   "$TOK"
assert_http_with_token "manager GET /v1/admin/tickets"    "200" GET "$API/v1/admin/tickets"    "$TOK"
assert_http_with_token "manager GET /v1/admin/reviews"    "200" GET "$API/v1/admin/reviews"    "$TOK"
assert_http_with_token "manager GET /v1/admin/currencies" "200" GET "$API/v1/admin/currencies" "$TOK"

# ─── Allowed write: POST /v1/admin/plans ─────────────────────────────────
DISPOSABLE_PLAN_NAME="authz-manager-plan-$(date +%s)"
PLAN_BODY='{"name":"'"$DISPOSABLE_PLAN_NAME"'","followers_qty":100,"price_cents":100,"currency":"BRL","active":false,"platform":"instagram","target_type":"profile"}'
http_call_token POST "$API/v1/admin/plans" "$TOK" "$PLAN_BODY"
if [[ "$HTTP_CODE" =~ ^(200|201)$ ]]; then
  test_pass "manager POST /v1/admin/plans → $HTTP_CODE (plans:write ok)"
else
  test_fail "manager POST /v1/admin/plans → $HTTP_CODE (esperado 200|201)" "$HTTP_BODY"
fi
# Cleanup direto (PATCH/DELETE bloqueados pelo Coraza em prod)
psql_q "DELETE FROM plans WHERE name='$DISPOSABLE_PLAN_NAME'" >/dev/null 2>&1

# ─── Denied: admins:manage ──────────────────────────────────────────────
assert_http_with_token "manager GET /v1/admin/admins (admins:manage)" "403" \
  GET "$API/v1/admin/admins" "$TOK"

assert_http_with_token "manager GET /v1/admin/vendors (admins:manage)" "403" \
  GET "$API/v1/admin/vendors" "$TOK"

assert_http_with_token "manager GET /v1/admin/ab/experiments (admins:manage)" "403" \
  GET "$API/v1/admin/ab/experiments" "$TOK"

# ─── Denied: criar admin (POST /v1/admin/admins) ────────────────────────
NEW_ADMIN_BODY='{"email":"would-not-exist@viralefy.test","name":"Nope","password":"SimTest!Nope1234","role":"viewer"}'
assert_http_with_token "manager POST /v1/admin/admins (escalation block)" "403" \
  POST "$API/v1/admin/admins" "$TOK" "$NEW_ADMIN_BODY"
# Defensivo: se vazou, limpa
psql_q "DELETE FROM admins WHERE email='would-not-exist@viralefy.test'" >/dev/null 2>&1

# ─── Denied: DELETE admin existente ─────────────────────────────────────
assert_http_with_token "manager DELETE /v1/admin/admins/$AUTHZ_VIEWER_ID" "403" \
  DELETE "$API/v1/admin/admins/$AUTHZ_VIEWER_ID" "$TOK"

test_summary "authz/rbac-manager-access"
exit $TEST_EXIT_CODE
