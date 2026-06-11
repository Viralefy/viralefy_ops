#!/usr/bin/env bash
# chaos · clock-skew
# Mintar token via auth (impossível sem secret) ou usar token expirado.
# Estratégia praticável: pegar um access_token real, esperar expirar, e
# confirmar que serve com 401 (sem tolerância) OU 200 (com clock-skew window).
#
# Sem TOKEN_EXP_SECONDS conhecido, fazemos heurística: register, parse JWT,
# extrai exp, decide se conseguimos esperar (skip se > 60s).

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "chaos · clock-skew"

API="$(api_base)"

if ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  test_skip "jq/python3 ausentes"; test_summary "chaos/clock-skew"; exit $TEST_EXIT_CODE
fi

# Register
TS="$(date +%s%N)"
EMAIL="clockskew-${TS}@viralefy.test"
http_call POST "$API/v1/auth/user/register" \
  "$(jq -cn --arg e "$EMAIL" '{name:"Skew", email:$e, password:"SimTest!Strong#9aZ", turnstile_token:""}')"
TOKEN="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | .access_token // empty' 2>/dev/null)"
if [[ -z "$TOKEN" ]]; then
  test_skip "sem access_token após register"; test_summary "chaos/clock-skew"; exit $TEST_EXIT_CODE
fi

# Parse exp
EXP=$(python3 - "$TOKEN" <<'PY'
import sys, base64, json
tok = sys.argv[1]
parts = tok.split('.')
if len(parts) < 2:
    print(0); sys.exit(0)
b = parts[1] + '=' * (-len(parts[1]) % 4)
try:
    payload = json.loads(base64.urlsafe_b64decode(b))
    print(payload.get('exp', 0))
except Exception:
    print(0)
PY
)
NOW=$(date +%s)
TTL=$(( EXP - NOW ))
echo "  token exp=${EXP} ttl=${TTL}s"

# Token novo deve aceitar /v1/me/orders (200) — sanity
http_call GET "$API/v1/me/orders" "" -H "Authorization: Bearer $TOKEN"
if [[ "$HTTP_CODE" == "200" ]]; then
  test_pass "token fresco → /v1/me/orders 200"
else
  test_skip "token fresco já não autenticou ($HTTP_CODE) — não dá pra medir skew"
  test_summary "chaos/clock-skew"; exit $TEST_EXIT_CODE
fi

# Se TTL > 60s, não esperamos — skipa o segundo teste
if (( TTL > 60 || TTL <= 0 )); then
  test_skip "token TTL=${TTL}s — fora da janela testável (precisamos 1-60s)"
  test_summary "chaos/clock-skew"; exit $TEST_EXIT_CODE
fi

# Espera expirar + 5s além (cobrir possível skew window de 30s)
WAIT=$(( TTL + 35 ))
echo "  aguardando ${WAIT}s pra exceder skew window de 30s..."
sleep "$WAIT"

http_call GET "$API/v1/me/orders" "" -H "Authorization: Bearer $TOKEN"
if [[ "$HTTP_CODE" == "401" ]]; then
  test_pass "token expirado (TTL+35s) → 401 (correto)"
elif [[ "$HTTP_CODE" == "200" ]]; then
  test_fail "token expirado ainda aceito após $WAIT s — janela de skew excessiva"
else
  test_fail "token expirado → $HTTP_CODE (esperado 401)" "$HTTP_BODY"
fi

test_summary "chaos/clock-skew"
exit $TEST_EXIT_CODE
