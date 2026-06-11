#!/usr/bin/env bash
# smoke · cors-preflight
# OPTIONS em /v1/* com Origin permitido deve retornar 204 (ou 200) +
# Access-Control-Allow-Origin. Falha = front fica sem conseguir falar com
# api (preflight blocked).

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "smoke · cors-preflight"

API="$(api_base)"
ORIGIN="${VIRALEFY_TEST_ORIGIN:-https://www.viralefy.com}"

# CORS preflight é injetado pelo Caddy upstream (handle_path + header set)
# em prod. O dispatcher loopback (:8090) responde 405 a OPTIONS porque o
# router só conhece GET — comportamento correto pra um upstream interno.
# Smoke distingue os casos:
#   - API base é https://  → testa preflight REAL no Caddy edge (deve passar)
#   - API base é http://127… → skip silencioso (não é o lugar pra avaliar CORS)
if [[ "$API" != https://* ]]; then
  test_skip "cors-preflight" "API base é loopback ($API) — CORS é responsabilidade do edge (Caddy). Setar VIRALEFY_TEST_API_BASE=https://api.viralefy.com pra cobrir."
  test_summary "smoke/cors-preflight"
  exit $TEST_EXIT_CODE
fi

http_call OPTIONS "$API/v1/plans" "" \
  -H "Origin: $ORIGIN" \
  -H "Access-Control-Request-Method: GET" \
  -H "Access-Control-Request-Headers: Content-Type"

# Preflight: 204 canônico, 200 também aceito.
if [[ "$HTTP_CODE" == "204" || "$HTTP_CODE" == "200" ]]; then
  test_pass "OPTIONS /v1/plans → $HTTP_CODE"
else
  test_fail "OPTIONS /v1/plans → $HTTP_CODE (esperado 204|200)" "$HTTP_BODY"
fi

# Access-Control-Allow-Origin presente
if echo "$HTTP_HEADERS" | grep -qiE '^access-control-allow-origin:'; then
  test_pass "header Access-Control-Allow-Origin presente"
else
  test_fail "header Access-Control-Allow-Origin ausente" "$HTTP_HEADERS"
fi

# Allow-Methods deve listar GET (e idealmente POST + OPTIONS)
if echo "$HTTP_HEADERS" | grep -qiE '^access-control-allow-methods:.*GET'; then
  test_pass "Access-Control-Allow-Methods inclui GET"
else
  test_fail "Access-Control-Allow-Methods sem GET" "$HTTP_HEADERS"
fi

test_summary "smoke/cors-preflight"
exit $TEST_EXIT_CODE
