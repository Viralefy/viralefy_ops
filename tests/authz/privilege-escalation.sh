#!/usr/bin/env bash
# authz · privilege-escalation
# Manager tenta:
#   1. POST /v1/admin/admins com role=superadmin → 403 (admins:manage block)
#      Mesmo que vaze o endpoint, defense-in-depth: o admin criado NÃO deve
#      ter role superadmin.
#   2. PUT /v1/admin/admins/<self> com role=superadmin → 403 (mass-assignment
#      em update do próprio profile não pode promover).
#
# Viewer tenta:
#   3. PUT /v1/admin/admins/<self> via /me ou direto → 403.
#
# Falha = role mass-assignment / vertical privilege escalation.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"
# shellcheck source=../lib-authz.sh
source "$_DIR/lib-authz.sh"

test_section "authz · privilege-escalation"
authz_check_prereqs

API="$(api_base)"
MANAGER_TOK="$(mint_admin_token manager | cut -f1)"
VIEWER_TOK="$(mint_admin_token viewer | cut -f1)"

# ─── Caso 1: manager cria admin com role=superadmin ──────────────────────
TRY_EMAIL="esc-target-$(date +%s)@viralefy.test"
ESC_BODY='{"email":"'"$TRY_EMAIL"'","name":"Escalated","password":"SimTest!Escalate1","role":"superadmin"}'
http_call_token POST "$API/v1/admin/admins" "$MANAGER_TOK" "$ESC_BODY"

if [[ "$HTTP_CODE" == "403" ]]; then
  test_pass "manager POST /v1/admin/admins (role=superadmin) → 403 (gate ok)"
else
  test_fail "manager POST /v1/admin/admins (role=superadmin) → $HTTP_CODE (esperado 403)" \
    "$HTTP_BODY"
fi

# Defense-in-depth: mesmo se vazou (HTTP_CODE != 403), conferir DB
ESC_ROLE="$(psql_q "SELECT role FROM admins WHERE email='$TRY_EMAIL' LIMIT 1")"
if [[ -z "$ESC_ROLE" ]]; then
  test_pass "DB: admin escalado NÃO criado"
elif [[ "$ESC_ROLE" != "superadmin" ]]; then
  test_pass "DB: admin criado mas SEM role superadmin (got=$ESC_ROLE)"
else
  test_fail "DB: PRIVILEGE ESCALATION — admin criado com role=superadmin"
fi
psql_q "DELETE FROM admins WHERE email='$TRY_EMAIL'" >/dev/null 2>&1

# ─── Caso 2: manager tenta PUT /v1/admin/admins/<self> → role superadmin ─
SELF_PROMOTE_BODY='{"role":"superadmin","name":"Manager Promoted"}'
http_call_token PUT "$API/v1/admin/admins/$AUTHZ_MANAGER_ID" "$MANAGER_TOK" "$SELF_PROMOTE_BODY"
if [[ "$HTTP_CODE" == "403" ]]; then
  test_pass "manager PUT /v1/admin/admins/<self> → 403"
else
  test_fail "manager PUT self → $HTTP_CODE (esperado 403)" "$HTTP_BODY"
fi

# DB check: role do manager continua "manager"
MANAGER_ROLE_AFTER="$(psql_q "SELECT role FROM admins WHERE id='$AUTHZ_MANAGER_ID'")"
if [[ "$MANAGER_ROLE_AFTER" == "manager" ]]; then
  test_pass "DB: manager.role permanece 'manager' após tentativa de auto-promote"
else
  test_fail "DB: manager.role mudou para '$MANAGER_ROLE_AFTER' (esperado 'manager')"
fi

# ─── Caso 3: viewer cria admin com mass-assignment (extra fields) ───────
MA_BODY='{"email":"viewer-ma@viralefy.test","name":"X","password":"SimTest!MassAssign1","role":"viewer","is_admin":true,"superadmin":true,"created_at":"1970-01-01T00:00:00Z"}'
http_call_token POST "$API/v1/admin/admins" "$VIEWER_TOK" "$MA_BODY"
if [[ "$HTTP_CODE" == "403" ]]; then
  test_pass "viewer POST /v1/admin/admins (mass-assign) → 403"
else
  test_fail "viewer POST mass-assign → $HTTP_CODE (esperado 403)" "$HTTP_BODY"
fi
psql_q "DELETE FROM admins WHERE email='viewer-ma@viralefy.test'" >/dev/null 2>&1

# ─── Caso 4: user (não admin) tentando rota admin com token user ────────
USER_TOK="$(mint_user_token "$AUTHZ_USER_A_ID" | cut -f1)"
assert_http_with_token "user_a hits /v1/admin/me (cross-realm)" "401|403" \
  GET "$API/v1/admin/me" "$USER_TOK"

test_summary "authz/privilege-escalation"
exit $TEST_EXIT_CODE
