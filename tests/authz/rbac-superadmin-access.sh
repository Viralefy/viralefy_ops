#!/usr/bin/env bash
# authz · rbac-superadmin-access
# Superadmin tem bypass total em Principal.Can — esperamos 2xx em
# CRUD admin completo (GET tudo, POST admins, POST plans, etc.).
#
# Falha = bypass quebrado OU RBAC apertado demais.
#
# Pré-req: viralefy test seed-superadmin.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"
# shellcheck source=../lib-authz.sh
source "$_DIR/lib-authz.sh"

test_section "authz · rbac-superadmin-access"
authz_check_prereqs

API="$(api_base)"
TOK="$(mint_admin_token superadmin | cut -f1)"
if [[ -z "$TOK" ]]; then
  test_fail "mint_admin_token superadmin falhou"
  test_summary "authz/rbac-superadmin-access"
  exit $TEST_EXIT_CODE
fi

# ─── Reads (todas devem ser 200) ─────────────────────────────────────────
for route in \
  /v1/admin/me \
  /v1/admin/roles \
  /v1/admin/admins \
  /v1/admin/plans \
  /v1/admin/gateways \
  /v1/admin/orders \
  /v1/admin/users \
  /v1/admin/currencies \
  /v1/admin/tickets \
  /v1/admin/reviews \
  /v1/admin/coupons \
  /v1/admin/invoices \
  /v1/admin/fraud/signals \
  /v1/admin/ab/experiments \
  /v1/admin/vendors \
  /v1/admin/metrics/summary \
  /v1/admin/proofs/pending; do
  assert_http_with_token "superadmin GET $route" "200" GET "$API$route" "$TOK"
done

# ─── Writes (cria + delete um admin descartável) ─────────────────────────
DISPOSABLE_EMAIL="disposable-$(date +%s)@viralefy.test"
BODY='{"email":"'"$DISPOSABLE_EMAIL"'","name":"Disposable","password":"SimTest!Disposable123","role":"viewer"}'
http_call_token POST "$API/v1/admin/admins" "$TOK" "$BODY"
if [[ "$HTTP_CODE" =~ ^(200|201|204)$ ]]; then
  test_pass "superadmin POST /v1/admin/admins → $HTTP_CODE"
  # Pega o ID e DELETE
  NEW_ID="$(echo "$HTTP_BODY" | jq -r '.id // .data.id // .admin.id // empty' 2>/dev/null)"
  if [[ -n "$NEW_ID" ]]; then
    assert_http_with_token "superadmin DELETE /v1/admin/admins/$NEW_ID" "200|204" \
      DELETE "$API/v1/admin/admins/$NEW_ID" "$TOK"
  else
    # Cleanup direto via SQL — DELETE em prod é blocked por Coraza WAF
    # (rule 911100, métodos fora do set padrão).
    psql_q "DELETE FROM admins WHERE email='$DISPOSABLE_EMAIL'" >/dev/null
    test_skip "DELETE admin (id não retornado, cleanup via SQL)"
  fi
else
  test_fail "superadmin POST /v1/admin/admins → $HTTP_CODE (esperado 2xx)" "$HTTP_BODY"
  psql_q "DELETE FROM admins WHERE email='$DISPOSABLE_EMAIL'" >/dev/null 2>&1
fi

test_summary "authz/rbac-superadmin-access"
exit $TEST_EXIT_CODE
