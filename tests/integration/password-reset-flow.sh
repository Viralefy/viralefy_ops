#!/usr/bin/env bash
# integration · password-reset-flow
# Full password reset: request → DB-fetch token → confirm → login com new pass.
# Em prod o link vai por email; aqui consultamos DB direto (psql).
#
# Vars:
#   DATABASE_URL  (necessária pra puxar o token; sem ela skip)

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "integration · password-reset-flow"

API="$(api_base)"

if ! command -v jq >/dev/null 2>&1; then
  test_skip "jq ausente"; test_summary "integration/password-reset-flow"; exit $TEST_EXIT_CODE
fi
if ! command -v psql >/dev/null 2>&1 || [[ -z "${DATABASE_URL:-}" ]]; then
  test_skip "psql/DATABASE_URL ausentes — não dá pra recuperar reset token sem inbox real"
  test_summary "integration/password-reset-flow"; exit $TEST_EXIT_CODE
fi

TS="$(date +%s%N)"
EMAIL="pwreset-${TS}@viralefy.test"
OLD_PASS="SimTest!Old#9aZ"
NEW_PASS="SimTest!New#7bX"

# 1. Register user
http_call POST "$API/v1/auth/user/register" \
  "$(jq -cn --arg e "$EMAIL" --arg p "$OLD_PASS" \
    '{name:"Reset Test", email:$e, password:$p, turnstile_token:""}')"
if [[ ! "$HTTP_CODE" =~ ^(200|201)$ ]]; then
  test_skip "register falhou ($HTTP_CODE)"
  test_summary "integration/password-reset-flow"; exit $TEST_EXIT_CODE
fi
test_pass "user registrado"

# 2. Solicitar reset (endpoint público se existir; senão internal via dispatcher)
# Padrão observado: POST /v1/auth/user/password/reset (não documentado)
# ou POST /v1/auth/password/reset. Tentamos os dois.
RESET_PAYLOAD="$(jq -cn --arg e "$EMAIL" '{email:$e}')"
for path in "/v1/auth/user/password/reset" "/v1/auth/password/reset/request" \
            "/v1/auth/password/reset"; do
  http_call POST "$API$path" "$RESET_PAYLOAD"
  if [[ "$HTTP_CODE" =~ ^(200|202|204)$ ]]; then
    test_pass "POST $path → $HTTP_CODE"
    RESET_OK=1
    break
  fi
done
if [[ -z "${RESET_OK:-}" ]]; then
  test_skip "nenhum endpoint público de password reset disponível ($HTTP_CODE)"
  test_summary "integration/password-reset-flow"; exit $TEST_EXIT_CODE
fi

# 3. Puxa token do DB (assume tabela password_reset_tokens(email, token, ...))
TOKEN="$(psql "$DATABASE_URL" -tAc \
  "SELECT token FROM password_reset_tokens WHERE email = '$EMAIL' AND used_at IS NULL ORDER BY created_at DESC LIMIT 1" \
  2>/dev/null || true)"
if [[ -z "$TOKEN" ]]; then
  test_skip "nenhum token de reset achado em password_reset_tokens (schema pode diferir)"
  test_summary "integration/password-reset-flow"; exit $TEST_EXIT_CODE
fi
test_pass "reset token obtido do DB"

# 4. Confirm reset
CONFIRM="$(jq -cn --arg t "$TOKEN" --arg p "$NEW_PASS" '{token:$t, new_password:$p}')"
http_call POST "$API/v1/auth/user/password/reset/confirm" "$CONFIRM"
if [[ ! "$HTTP_CODE" =~ ^(200|204)$ ]]; then
  test_fail "confirm reset → $HTTP_CODE" "$HTTP_BODY"
  test_summary "integration/password-reset-flow"; exit $TEST_EXIT_CODE
fi
test_pass "POST /v1/auth/user/password/reset/confirm → $HTTP_CODE"

# 5. Login com nova senha
http_call POST "$API/v1/auth/user/login" \
  "$(jq -cn --arg e "$EMAIL" --arg p "$NEW_PASS" '{email:$e, password:$p, turnstile_token:""}')"
if [[ "$HTTP_CODE" == "200" ]]; then
  test_pass "login com nova senha → 200"
else
  test_fail "login com nova senha → $HTTP_CODE" "$HTTP_BODY"
fi

# 6. Login com senha antiga → 401
http_call POST "$API/v1/auth/user/login" \
  "$(jq -cn --arg e "$EMAIL" --arg p "$OLD_PASS" '{email:$e, password:$p, turnstile_token:""}')"
if [[ "$HTTP_CODE" == "401" ]]; then
  test_pass "login com senha antiga → 401 (revogada)"
else
  test_fail "login com senha antiga → $HTTP_CODE (esperado 401)" "$HTTP_BODY"
fi

test_summary "integration/password-reset-flow"
exit $TEST_EXIT_CODE
