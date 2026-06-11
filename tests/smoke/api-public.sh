#!/usr/bin/env bash
# smoke · api-public
# Endpoints públicos (sem auth) do dispatcher: /v1/plans, /v1/categories,
# /v1/currencies. Esperado: 200 + envelope {"data": [...]} (ou array raw em
# legacy). Pelo menos /v1/plans tem que ter > 0 items pra checkout ser
# possível em prod.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "smoke · api-public"

API="$(api_base)"

check_envelope() {
  local route="$1" require_nonempty="${2:-0}"
  http_call GET "$API$route"
  if [[ "$HTTP_CODE" != "200" ]]; then
    test_fail "$route → $HTTP_CODE (esperado 200)" "$HTTP_BODY"
    return
  fi
  # Pode ser {"data": [...]} ou [...] raw.
  local n
  n="$(echo "$HTTP_BODY" | jq -r '
    if type=="object" and has("data") then (.data | if type=="array" then length else -1 end)
    elif type=="array" then length
    else -1 end' 2>/dev/null || echo -1)"
  if [[ "$n" =~ ^-?[0-9]+$ ]] && (( n >= 0 )); then
    if (( require_nonempty == 1 )) && (( n == 0 )); then
      test_fail "$route → 200 mas array vazio (esperado > 0)" "$HTTP_BODY"
    else
      test_pass "$route → 200 + JSON array (len=$n)"
    fi
  else
    test_fail "$route → 200 mas corpo não é array/envelope" "$HTTP_BODY"
  fi
}

check_envelope "/v1/plans"       1
check_envelope "/v1/categories"  0
check_envelope "/v1/currencies"  0

test_summary "smoke/api-public"
exit $TEST_EXIT_CODE
