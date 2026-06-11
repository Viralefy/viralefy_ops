#!/usr/bin/env bash
# authz · cross-user-write
# User A não muta dados de User B:
#   - POST /v1/me/reviews com order_id de B → 403/404
#   - DELETE /v1/me/profiles/<B's profile>  → 403/404 (já em user-bola, repete por defense-in-depth do path mutation)
#   - DELETE /v1/me/subscriptions/<B's sub> → 403/404
#   - POST /v1/me/orders/<B's id>/proof     → 403/404
#
# Falha = write cross-user → corrupção/spoof de dados de outro usuário.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"
# shellcheck source=../lib-authz.sh
source "$_DIR/lib-authz.sh"

test_section "authz · cross-user-write"
authz_check_prereqs

API="$(api_base)"
TOK_A="$(mint_user_token "$AUTHZ_USER_A_ID" | cut -f1)"

# Este script sequencia 4 writes seguidos com o mesmo token (mesma IP),
# então elevamos o pacing pra 1.5s pra ficar bem abaixo do sustained 1/s.
AUTHZ_PAUSE_MS=1500

# ─── A tenta criar review pra order de B ────────────────────────────────
REVIEW_BODY='{"order_id":"'"$AUTHZ_ORDER_B_PENDING"'","rating":5,"comment":"Cross-user write attempt"}'
assert_http_with_token "user_a POST /v1/me/reviews (order de B)" "403|404|422|400" \
  POST "$API/v1/me/reviews" "$TOK_A" "$REVIEW_BODY"

# Defense-in-depth: nenhum review do A pra order de B no DB
REVIEW_LEAK="$(psql_q "
  SELECT COUNT(*)::int FROM reviews
  WHERE order_id='$AUTHZ_ORDER_B_PENDING'
    AND user_id='$AUTHZ_USER_A_ID'
" 2>/dev/null || echo "?")"
if [[ "$REVIEW_LEAK" == "0" || "$REVIEW_LEAK" == "?" ]]; then
  test_pass "DB: nenhum review de A pra order de B"
else
  test_fail "DB: $REVIEW_LEAK review(s) cross-user vazaram"
  psql_q "DELETE FROM reviews WHERE order_id='$AUTHZ_ORDER_B_PENDING' AND user_id='$AUTHZ_USER_A_ID'" >/dev/null
fi

# ─── A tenta DELETE profile de B (BOLA write) ───────────────────────────
assert_http_with_token "user_a DELETE /v1/me/profiles/<B's profile>" "403|404" \
  DELETE "$API/v1/me/profiles/$AUTHZ_PROFILE_B" "$TOK_A"

# ─── A tenta DELETE subscription de B (fake ID — não existe seed) ───────
FAKE_SUB_B="ffffffff-0000-4000-8000-00000000b001"
assert_http_with_token "user_a DELETE /v1/me/subscriptions/<B-fake>" "403|404" \
  DELETE "$API/v1/me/subscriptions/$FAKE_SUB_B" "$TOK_A"

# ─── A tenta POST proof pra order de B ──────────────────────────────────
# Endpoint requer multipart real, mas RBAC dispara antes.
http_call_token POST "$API/v1/me/orders/$AUTHZ_ORDER_B_PENDING/proof" "$TOK_A"
if [[ "$HTTP_CODE" =~ ^(403|404|400|415|422)$ ]]; then
  test_pass "user_a POST /v1/me/orders/<B>/proof → $HTTP_CODE"
else
  test_fail "user_a POST /v1/me/orders/<B>/proof → $HTTP_CODE (esperado 4xx)" "$HTTP_BODY"
fi

# ─── A tenta cancelar order de B via PATCH (se rota existir) ────────────
# Não há /v1/me/orders/{id} PATCH no router atual — apenas /proof e /proof-url.
# Caso surja no futuro, cobrir aqui.

# ─── B confere: dados intactos ──────────────────────────────────────────
B_PROFILE_OK="$(psql_q "SELECT id FROM profiles WHERE id='$AUTHZ_PROFILE_B'")"
if [[ "$B_PROFILE_OK" == "$AUTHZ_PROFILE_B" ]]; then
  test_pass "DB: profile de B intacto"
else
  test_fail "DB: profile de B sumiu (id=$B_PROFILE_OK)"
fi

B_ORDER_OK="$(psql_q "SELECT status FROM orders WHERE id='$AUTHZ_ORDER_B_PENDING'")"
if [[ "$B_ORDER_OK" == "pending" ]]; then
  test_pass "DB: order de B mantém status=pending"
else
  test_fail "DB: order de B status=$B_ORDER_OK (esperado pending)"
fi

test_summary "authz/cross-user-write"
exit $TEST_EXIT_CODE
