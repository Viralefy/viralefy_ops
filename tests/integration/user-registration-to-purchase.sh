#!/usr/bin/env bash
# integration · user-registration-to-purchase
# Flow ponta-a-ponta: register novo user, lista plans, escolhe gateway,
# faz POST /v1/checkout, verifica order em /v1/me/orders. Cleanup é feito
# pelo viralefy-test-cleanup.timer (hourly, alvo: emails *@viralefy.test).

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "integration · user-registration-to-purchase"

API="$(api_base)"

if ! command -v jq >/dev/null 2>&1; then
  test_skip "jq ausente"
  test_summary "integration/user-registration-to-purchase"
  exit $TEST_EXIT_CODE
fi

TS="$(date +%s%N)"
EMAIL="int-reg-${TS}@viralefy.test"
PASS="SimTest!Strong#9aZ"

# 1. Register
REG_PAYLOAD="$(jq -cn --arg e "$EMAIL" --arg p "$PASS" \
  '{name:"Int Reg", email:$e, password:$p, turnstile_token:""}')"
http_call POST "$API/v1/auth/user/register" "$REG_PAYLOAD"
if [[ ! "$HTTP_CODE" =~ ^(200|201)$ ]]; then
  test_fail "POST /v1/auth/user/register → $HTTP_CODE (esperado 201)" "$HTTP_BODY"
  test_summary "integration/user-registration-to-purchase"
  exit $TEST_EXIT_CODE
fi
test_pass "POST /v1/auth/user/register → $HTTP_CODE"

ACCESS_TOKEN="$(printf '%s' "$HTTP_BODY" | jq -r '
  (.data // .) as $d
  | $d.access_token // $d.token // empty' 2>/dev/null)"
if [[ -z "$ACCESS_TOKEN" ]]; then
  # Tentar login subsequente
  http_call POST "$API/v1/auth/user/login" \
    "$(jq -cn --arg e "$EMAIL" --arg p "$PASS" '{email:$e, password:$p, turnstile_token:""}')"
  ACCESS_TOKEN="$(printf '%s' "$HTTP_BODY" | jq -r '
    (.data // .) as $d
    | $d.access_token // $d.token // empty' 2>/dev/null)"
fi
if [[ -z "$ACCESS_TOKEN" ]]; then
  test_skip "sem access_token após register/login — pulando checkout"
  test_summary "integration/user-registration-to-purchase"
  exit $TEST_EXIT_CODE
fi
test_pass "access_token capturado"

# 2. Lista plans
http_call GET "$API/v1/plans"
if [[ "$HTTP_CODE" != "200" ]]; then
  test_fail "GET /v1/plans → $HTTP_CODE" "$HTTP_BODY"
  test_summary "integration/user-registration-to-purchase"
  exit $TEST_EXIT_CODE
fi
PLAN_ID="$(printf '%s' "$HTTP_BODY" | jq -r '
  if type=="object" and has("data") then .data[0].id
  elif type=="array" then .[0].id
  else "" end' 2>/dev/null)"
if [[ -z "$PLAN_ID" || "$PLAN_ID" == "null" ]]; then
  test_skip "nenhum plan disponível — pulando checkout"
  test_summary "integration/user-registration-to-purchase"
  exit $TEST_EXIT_CODE
fi
test_pass "plan_id capturado: $PLAN_ID"

# 3. Payment methods
http_call GET "$API/v1/plans/$PLAN_ID/payment-methods"
GW_ID=""
if [[ "$HTTP_CODE" == "200" ]]; then
  GW_ID="$(printf '%s' "$HTTP_BODY" | jq -r '
    (if type=="object" and has("data") then .data else . end)
    | (if type=="array" then (.[] | select(.gateway_id) | .gateway_id) else .gateway_id end) // ""' \
    2>/dev/null | head -1)"
fi
if [[ -z "$GW_ID" || "$GW_ID" == "null" ]]; then
  test_skip "gateway_id indisponível — pulando checkout"
  test_summary "integration/user-registration-to-purchase"
  exit $TEST_EXIT_CODE
fi
test_pass "gateway_id capturado: $GW_ID"

# 4. POST /v1/checkout
CHECKOUT=$(cat <<JSON
{
  "plan_id": "$PLAN_ID",
  "email": "$EMAIL",
  "name": "Int Reg",
  "display_currency": "USD",
  "payment_method": "gateway",
  "gateway_id": "$GW_ID",
  "pay_currency": "USDT",
  "new_profile": {"platform":"instagram","handle":"intreg","display_name":"Int"},
  "tracking": {"landing_url":"https://www.viralefy.com/us/instagram-followers"},
  "country":"us","target_country":"us"
}
JSON
)
http_call POST "$API/v1/checkout" "$CHECKOUT" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Idempotency-Key: int-reg-$TS"
if [[ "$HTTP_CODE" != "201" ]]; then
  test_fail "POST /v1/checkout → $HTTP_CODE (esperado 201)" "$HTTP_BODY"
  test_summary "integration/user-registration-to-purchase"
  exit $TEST_EXIT_CODE
fi
test_pass "POST /v1/checkout → 201"

ORDER_ID="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | .order_id // empty' 2>/dev/null)"
if [[ -n "$ORDER_ID" ]]; then
  test_pass "order_id presente ($ORDER_ID)"
else
  test_fail "order_id ausente" "$HTTP_BODY"
fi

# 5. GET /v1/me/orders → vê o novo order
http_call GET "$API/v1/me/orders" "" -H "Authorization: Bearer $ACCESS_TOKEN"
if [[ "$HTTP_CODE" == "200" ]]; then
  if printf '%s' "$HTTP_BODY" | jq -e --arg id "$ORDER_ID" '
      (.data // .) | (if type=="array" then . else [.] end) | any(.id == $id)' \
      >/dev/null 2>&1; then
    test_pass "/v1/me/orders contém o order criado"
  else
    test_fail "/v1/me/orders não retornou o order criado" "$HTTP_BODY"
  fi
else
  test_fail "GET /v1/me/orders → $HTTP_CODE" "$HTTP_BODY"
fi

test_summary "integration/user-registration-to-purchase"
exit $TEST_EXIT_CODE
