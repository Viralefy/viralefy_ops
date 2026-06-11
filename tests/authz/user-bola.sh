#!/usr/bin/env bash
# authz · user-bola
# BOLA = Broken Object Level Authorization (OWASP API1:2023).
# User A logado tenta ler dados de User B:
#   - GET /v1/me/orders/<order_id_de_B>      → 403 ou 404
#   - GET /v1/me/orders/<id>/proof-url       → 403 ou 404
#   - DELETE /v1/me/profiles/<profile_id_de_B> → 403 ou 404
#
# Falha = data leak entre usuários (BOLA clássico).
#
# Pré-req: viralefy test seed-users + seed-orders.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"
# shellcheck source=../lib-authz.sh
source "$_DIR/lib-authz.sh"

test_section "authz · user-bola"
authz_check_prereqs

API="$(api_base)"
TOK_A="$(mint_user_token "$AUTHZ_USER_A_ID" | cut -f1)"
TOK_B="$(mint_user_token "$AUTHZ_USER_B_ID" | cut -f1)"

# ─── Confirmação: A vê seus próprios orders ──────────────────────────────
http_call_token GET "$API/v1/me/orders" "$TOK_A"
if [[ "$HTTP_CODE" == "200" ]]; then
  COUNT_A="$(echo "$HTTP_BODY" | jq -r '(.data // .) | length' 2>/dev/null || echo 0)"
  if [[ "$COUNT_A" =~ ^[0-9]+$ ]] && (( COUNT_A >= 1 )); then
    test_pass "user_a GET /v1/me/orders retorna $COUNT_A item(s)"
  else
    test_skip "user_a GET /v1/me/orders vazio (seed-orders pode não ter rodado)"
  fi
else
  test_fail "user_a GET /v1/me/orders → $HTTP_CODE (esperado 200)" "$HTTP_BODY"
fi

# ─── A tenta ler order de B por ID ───────────────────────────────────────
assert_http_with_token "user_a GET /v1/me/orders/<B's pending>" "403|404" \
  GET "$API/v1/me/orders/$AUTHZ_ORDER_B_PENDING" "$TOK_A"

# Caso vaze 200, conferir se o corpo NÃO inclui dados de B
if [[ "$HTTP_CODE" == "200" ]]; then
  if echo "$HTTP_BODY" | grep -q "$AUTHZ_USER_B_ID\|user-b@viralefy.test"; then
    test_fail "BOLA: user_a leu order de user_b (id ou email leaked)" "$HTTP_BODY"
  fi
fi

# ─── A tenta proof-url do order de B ────────────────────────────────────
assert_http_with_token "user_a GET /v1/me/orders/<B's order>/proof-url" "403|404" \
  GET "$API/v1/me/orders/$AUTHZ_ORDER_B_PENDING/proof-url" "$TOK_A"

# ─── A tenta DELETE profile de B ────────────────────────────────────────
assert_http_with_token "user_a DELETE /v1/me/profiles/<B's profile>" "403|404" \
  DELETE "$API/v1/me/profiles/$AUTHZ_PROFILE_B" "$TOK_A"

# Defense-in-depth: profile de B ainda existe?
B_PROFILE_OK="$(psql_q "SELECT id FROM profiles WHERE id='$AUTHZ_PROFILE_B'")"
if [[ -n "$B_PROFILE_OK" ]]; then
  test_pass "DB: profile de B preservado após DELETE de A"
else
  test_fail "DB: profile de B foi DELETADO via BOLA"
fi

# ─── A tenta review/ler ticket de B ─────────────────────────────────────
assert_http_with_token "user_a GET /v1/me/reviews/by-order/<B's order>" "403|404" \
  GET "$API/v1/me/reviews/by-order/$AUTHZ_ORDER_B_PENDING" "$TOK_A"

# ─── Reverse: B não vê orders de A ──────────────────────────────────────
assert_http_with_token "user_b GET /v1/me/orders/<A's paid_1>" "403|404" \
  GET "$API/v1/me/orders/$AUTHZ_ORDER_A_PAID_1" "$TOK_B"

# ─── User C (sem orders) listing retorna vazio, não erro ────────────────
TOK_C="$(mint_user_token "$AUTHZ_USER_C_ID" | cut -f1)"
http_call_token GET "$API/v1/me/orders" "$TOK_C"
if [[ "$HTTP_CODE" == "200" ]]; then
  COUNT_C="$(echo "$HTTP_BODY" | jq -r '(.data // .) | length' 2>/dev/null || echo "?")"
  if [[ "$COUNT_C" == "0" ]]; then
    test_pass "user_c (sem orders) → 200 + []"
  else
    test_fail "user_c GET /v1/me/orders retornou $COUNT_C items (esperado 0)" "$HTTP_BODY"
  fi
else
  test_fail "user_c GET /v1/me/orders → $HTTP_CODE (esperado 200)" "$HTTP_BODY"
fi

test_summary "authz/user-bola"
exit $TEST_EXIT_CODE
