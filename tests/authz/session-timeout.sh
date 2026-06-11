#!/usr/bin/env bash
# authz · session-timeout
# Token access expira após TTL (default 15min em prod). Aqui não esperamos
# 16min — mintamos token com TTL curto e validamos:
#   - imediato → 200
#   - após sleep > TTL → 401
#
# TTL=8s dá folga pra throttle_pause (~1.1s) + curl roundtrip via TLS
# público (~1-2s) + jitter. Esperamos 13s antes do 2º hit (TTL+5).
# Total do script: ~30s (3 casos × ~10s).
#
# Complementa pentest/jwt-tampering — foco aqui é exp claim respeitado.
#
# Falha = exp ignorado / clock skew permissivo / TTL infinito.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"
# shellcheck source=../lib-authz.sh
source "$_DIR/lib-authz.sh"

test_section "authz · session-timeout"
authz_check_prereqs

API="$(api_base)"

SHORT_TTL=8
WAIT_FOR_EXPIRE=$((SHORT_TTL + 5))

# ─── Caso 1: token user com TTL curto ───────────────────────────────────
USER_TOK_SHORT="$(mint_user_token "$AUTHZ_USER_A_ID" "$SHORT_TTL" | cut -f1)"
if [[ -z "$USER_TOK_SHORT" ]]; then
  test_fail "mint_user_token TTL=${SHORT_TTL}s falhou"
  test_summary "authz/session-timeout"
  exit $TEST_EXIT_CODE
fi

# Imediato → 200
http_call_token GET "$API/v1/me/orders" "$USER_TOK_SHORT"
if [[ "$HTTP_CODE" == "200" ]]; then
  test_pass "user token TTL=${SHORT_TTL}s imediato → 200"
else
  test_fail "user token TTL=${SHORT_TTL}s imediato → $HTTP_CODE (esperado 200)" "$HTTP_BODY"
fi

sleep "$WAIT_FOR_EXPIRE"

# Pós-TTL → 401
http_call_token GET "$API/v1/me/orders" "$USER_TOK_SHORT"
if [[ "$HTTP_CODE" == "401" ]]; then
  test_pass "user token pós-${WAIT_FOR_EXPIRE}s → 401 (exp respeitado)"
else
  test_fail "user token pós-${WAIT_FOR_EXPIRE}s → $HTTP_CODE (esperado 401)" "$HTTP_BODY"
fi

# ─── Caso 2: token admin com TTL curto ──────────────────────────────────
ADMIN_TOK_SHORT="$(mint_admin_token superadmin "$SHORT_TTL" | cut -f1)"
http_call_token GET "$API/v1/admin/me" "$ADMIN_TOK_SHORT"
if [[ "$HTTP_CODE" == "200" ]]; then
  test_pass "admin token TTL=${SHORT_TTL}s imediato → 200"
else
  test_fail "admin token TTL=${SHORT_TTL}s imediato → $HTTP_CODE (esperado 200)" "$HTTP_BODY"
fi

sleep "$WAIT_FOR_EXPIRE"

http_call_token GET "$API/v1/admin/me" "$ADMIN_TOK_SHORT"
if [[ "$HTTP_CODE" == "401" ]]; then
  test_pass "admin token pós-${WAIT_FOR_EXPIRE}s → 401 (exp respeitado)"
else
  test_fail "admin token pós-${WAIT_FOR_EXPIRE}s → $HTTP_CODE (esperado 401)" "$HTTP_BODY"
fi

# ─── Caso 3: token com exp no passado direto ────────────────────────────
EXPIRED_TOK="$(mint_admin_token superadmin -60 | cut -f1)"
http_call_token GET "$API/v1/admin/me" "$EXPIRED_TOK"
if [[ "$HTTP_CODE" == "401" ]]; then
  test_pass "admin token com exp -60s → 401 (sem clock-skew leniency)"
else
  test_fail "admin token com exp -60s → $HTTP_CODE (esperado 401, clock skew?)" "$HTTP_BODY"
fi

test_summary "authz/session-timeout"
exit $TEST_EXIT_CODE
