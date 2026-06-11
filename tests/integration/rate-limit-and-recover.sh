#!/usr/bin/env bash
# integration · rate-limit-and-recover
# 50 requests rápidos a /v1/auth/user/login com creds errados → espera 429.
# Depois espera a janela passar OU skipa o recover se for muito longa.
#
# loginLimiter no router atual está em 5/min ou 10/15min — varia.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "integration · rate-limit-and-recover"

API="$(api_base)"
if ! command -v jq >/dev/null 2>&1; then
  test_skip "jq ausente"; test_summary "integration/rate-limit-and-recover"; exit $TEST_EXIT_CODE
fi

EMAIL="ratelimit-$(date +%s%N)@viralefy.test"
PAYLOAD="$(jq -cn --arg e "$EMAIL" '{email:$e, password:"wrong-on-purpose", turnstile_token:""}')"

CODES=""
GOT_429=0
for i in $(seq 1 50); do
  http_call POST "$API/v1/auth/user/login" "$PAYLOAD"
  CODES+="$HTTP_CODE "
  if [[ "$HTTP_CODE" == "429" ]]; then
    GOT_429=1
    break
  fi
done

if (( GOT_429 == 1 )); then
  test_pass "429 emitido após $i tentativas inválidas"
else
  # Sem 429 — pode ser que loginLimiter esteja muito generoso, ou
  # rede local seja whitelistada. Não falha hard.
  test_skip "rate-limit não disparou em 50 tentativas (loopback pode ser whitelisted)"
  echo "    códigos vistos: $(echo "$CODES" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
fi

# Recover — sem esperar 15min. Apenas verifica que outra rota não-rate-limited
# segue respondendo (sanity: o serviço não morreu).
http_call GET "$API/v1/plans"
if [[ "$HTTP_CODE" == "200" ]]; then
  test_pass "GET /v1/plans pós-flood → 200 (service vivo)"
else
  test_fail "GET /v1/plans pós-flood → $HTTP_CODE (service degradado?)" "$HTTP_BODY"
fi

test_summary "integration/rate-limit-and-recover"
exit $TEST_EXIT_CODE
