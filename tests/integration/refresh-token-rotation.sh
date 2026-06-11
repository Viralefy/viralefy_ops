#!/usr/bin/env bash
# integration · refresh-token-rotation
# Login → refresh chain → verify família revogada quando há reuso.
# CONTEXTO: o stack atual NÃO expõe POST /v1/auth/refresh público (rota
# vive em /internal/v1/refresh do viralefy_auth, gated por X-Internal-Token).
# Este script tenta os paths público/dispatcher conhecidos; se nenhum
# responde, skipa graciosamente com NÃO IMPLEMENTADO — sem falhar.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "integration · refresh-token-rotation"

API="$(api_base)"
if ! command -v jq >/dev/null 2>&1; then
  test_skip "jq ausente"; test_summary "integration/refresh-token-rotation"; exit $TEST_EXIT_CODE
fi

TS="$(date +%s%N)"
EMAIL="rot-${TS}@viralefy.test"
PASS="SimTest!Strong#9aZ"

# Register pra ter um refresh_token novo
http_call POST "$API/v1/auth/user/register" \
  "$(jq -cn --arg e "$EMAIL" --arg p "$PASS" '{name:"Rotation Test", email:$e, password:$p, turnstile_token:""}')"
if [[ ! "$HTTP_CODE" =~ ^(200|201)$ ]]; then
  test_skip "register falhou ($HTTP_CODE)"; test_summary "integration/refresh-token-rotation"; exit $TEST_EXIT_CODE
fi
REFRESH_A="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | .refresh_token // empty' 2>/dev/null)"
if [[ -z "$REFRESH_A" ]]; then
  http_call POST "$API/v1/auth/user/login" \
    "$(jq -cn --arg e "$EMAIL" --arg p "$PASS" '{email:$e, password:$p, turnstile_token:""}')"
  REFRESH_A="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | .refresh_token // empty' 2>/dev/null)"
fi
if [[ -z "$REFRESH_A" ]]; then
  test_skip "refresh_token não exposto pela API pública — feature pode estar gated"
  test_summary "integration/refresh-token-rotation"; exit $TEST_EXIT_CODE
fi
test_pass "refresh A capturado"

# Tenta endpoints conhecidos pra refresh público
PAYLOAD_A="$(jq -cn --arg r "$REFRESH_A" '{refresh_token:$r}')"
REFRESH_B=""; REFRESH_PATH=""
for path in "/v1/auth/refresh" "/v1/auth/user/refresh" "/v1/auth/token/refresh"; do
  http_call POST "$API$path" "$PAYLOAD_A"
  if [[ "$HTTP_CODE" == "200" ]]; then
    REFRESH_B="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | .refresh_token // empty' 2>/dev/null)"
    REFRESH_PATH="$path"
    break
  fi
done

if [[ -z "$REFRESH_B" || -z "$REFRESH_PATH" ]]; then
  test_skip "nenhum endpoint público de refresh respondeu — stack atual só tem internal/v1/refresh"
  test_summary "integration/refresh-token-rotation"; exit $TEST_EXIT_CODE
fi
test_pass "POST $REFRESH_PATH com A → 200 + refresh B"

# Rotação 2: refresh com B → C
http_call POST "$API$REFRESH_PATH" "$(jq -cn --arg r "$REFRESH_B" '{refresh_token:$r}')"
if [[ "$HTTP_CODE" != "200" ]]; then
  test_fail "refresh com B → $HTTP_CODE" "$HTTP_BODY"
  test_summary "integration/refresh-token-rotation"; exit $TEST_EXIT_CODE
fi
REFRESH_C="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | .refresh_token // empty' 2>/dev/null)"
[[ -n "$REFRESH_C" ]] && test_pass "rotação B → C ok" || test_fail "rotação B → C: refresh_token vazio" "$HTTP_BODY"

# Reuso de A → 401 + família revogada
http_call POST "$API$REFRESH_PATH" "$PAYLOAD_A"
if [[ "$HTTP_CODE" =~ ^(401|403)$ ]]; then
  test_pass "reuso de A → $HTTP_CODE (revogado)"
else
  test_fail "reuso de A → $HTTP_CODE (esperado 401/403)" "$HTTP_BODY"
fi

# C deve estar revogado também (família inteira)
if [[ -n "$REFRESH_C" ]]; then
  http_call POST "$API$REFRESH_PATH" "$(jq -cn --arg r "$REFRESH_C" '{refresh_token:$r}')"
  if [[ "$HTTP_CODE" =~ ^(401|403)$ ]]; then
    test_pass "C revogado após reuse de A → $HTTP_CODE"
  else
    test_fail "C deveria estar revogado → $HTTP_CODE" "$HTTP_BODY"
  fi
fi

test_summary "integration/refresh-token-rotation"
exit $TEST_EXIT_CODE
