#!/usr/bin/env bash
# smoke · checkout-e2e
# POST /v1/checkout com payload real réplica do CheckoutModal. Regression
# test pra Coraza FP 942100 no campo tracking.landing_url (incidente
# 2026-06-10): CRS PL2 disparava SQLi na URL legítima
# https://www.viralefy.com/<lang>/<slug>.
#
# Test users *@viralefy.test — cleanup hourly via viralefy-test-cleanup.timer.
# Fail-soft: se /v1/plans estiver indisponível, marca fail mas segue
# (sub-checks são independentes).

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "smoke · checkout-e2e (regression Coraza FP 2026-06-10)"

API="$(api_base)"

# 1. Buscar plan_id
http_call GET "$API/v1/plans"
PLAN_ID=""
if [[ "$HTTP_CODE" == "200" ]]; then
  PLAN_ID="$(echo "$HTTP_BODY" | jq -r '
    if type=="object" and has("data") then .data[0].id
    elif type=="array" then .[0].id
    else "" end' 2>/dev/null || echo "")"
fi
if [[ -z "$PLAN_ID" || "$PLAN_ID" == "null" ]]; then
  test_fail "não consegui extrair plan_id de /v1/plans" "$HTTP_BODY"
  test_summary "smoke/checkout-e2e"
  exit $TEST_EXIT_CODE
fi
test_pass "plan_id capturado: $PLAN_ID"

# 2. Buscar gateway_id em /v1/plans/<id>/payment-methods
http_call GET "$API/v1/plans/$PLAN_ID/payment-methods"
if [[ "$HTTP_CODE" != "200" ]]; then
  test_fail "/v1/plans/$PLAN_ID/payment-methods → $HTTP_CODE" "$HTTP_BODY"
  test_summary "smoke/checkout-e2e"
  exit $TEST_EXIT_CODE
fi
GW_ID="$(echo "$HTTP_BODY" | jq -r '
  if type=="object" and has("data") then (.data[] | select(.gateway_id) | .gateway_id) // ""
  elif type=="array" then (.[] | select(.gateway_id) | .gateway_id) // ""
  else "" end' 2>/dev/null | head -1)"
if [[ -z "$GW_ID" || "$GW_ID" == "null" ]]; then
  test_fail "não consegui extrair gateway_id de payment-methods" "$HTTP_BODY"
  test_summary "smoke/checkout-e2e"
  exit $TEST_EXIT_CODE
fi
test_pass "gateway_id capturado: $GW_ID"

# 3. POST /v1/checkout — payload réplica do CheckoutModal
STAMP="$(date +%s%N)"
EMAIL="smoke-${STAMP}@viralefy.test"
PAYLOAD=$(cat <<JSON
{
  "plan_id": "$PLAN_ID",
  "email": "$EMAIL",
  "name": "Smoke Test",
  "display_currency": "USD",
  "payment_method": "gateway",
  "gateway_id": "$GW_ID",
  "pay_currency": "USDT",
  "new_profile": {
    "platform": "instagram",
    "handle": "smoketest",
    "display_name": "Smoke"
  },
  "tracking": {
    "landing_url": "https://www.viralefy.com/us/instagram-followers",
    "referrer": "https://google.com/",
    "utm_source": "google",
    "fbclid": "smoke-fbclid"
  },
  "country": "us",
  "target_country": "us"
}
JSON
)

http_call POST "$API/v1/checkout" "$PAYLOAD" \
  -H "Idempotency-Key: smoke-$STAMP"

if [[ "$HTTP_CODE" != "201" ]]; then
  test_fail "POST /v1/checkout → $HTTP_CODE (esperado 201)" "$HTTP_BODY"
  test_summary "smoke/checkout-e2e"
  exit $TEST_EXIT_CODE
fi
test_pass "POST /v1/checkout → 201"

# 4. Envelope: data.order_id + data.payment_url
ORDER_ID="$(echo "$HTTP_BODY" | jq -r '(.data // .).order_id // ""' 2>/dev/null)"
PAY_URL="$(echo "$HTTP_BODY" | jq -r '(.data // .).payment_url // ""' 2>/dev/null)"

if [[ -n "$ORDER_ID" && "$ORDER_ID" != "null" ]]; then
  test_pass "order_id presente ($ORDER_ID)"
else
  test_fail "order_id ausente no response" "$HTTP_BODY"
fi
if [[ -n "$PAY_URL" && "$PAY_URL" != "null" ]]; then
  test_pass "payment_url presente"
else
  test_fail "payment_url ausente no response" "$HTTP_BODY"
fi

test_summary "smoke/checkout-e2e"
exit $TEST_EXIT_CODE
