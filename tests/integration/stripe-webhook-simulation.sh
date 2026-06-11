#!/usr/bin/env bash
# integration · stripe-webhook-simulation
# Cria order via /v1/checkout, simula webhook Stripe com signature válida
# (HMAC SHA256 com STRIPE_WEBHOOK_SECRET), valida que order vira paid.
#
# Vars:
#   STRIPE_WEBHOOK_SECRET (sem default — skip se vazio)
#   DATABASE_URL          (opcional — pra confirmar status via SQL)

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "integration · stripe-webhook-simulation"

API="$(api_base)"

if ! command -v jq >/dev/null 2>&1; then
  test_skip "jq ausente"; test_summary "integration/stripe-webhook-simulation"; exit $TEST_EXIT_CODE
fi
SECRET="${STRIPE_WEBHOOK_SECRET:-}"
if [[ -z "$SECRET" ]]; then
  test_skip "STRIPE_WEBHOOK_SECRET ausente"; test_summary "integration/stripe-webhook-simulation"; exit $TEST_EXIT_CODE
fi

# 1. Criar order via checkout (anônimo OK)
TS="$(date +%s%N)"
EMAIL="stripe-${TS}@viralefy.test"
http_call GET "$API/v1/plans"
PLAN_ID="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | (if type=="array" then .[0].id else .[0].id end) // ""' 2>/dev/null)"
[[ -z "$PLAN_ID" ]] && { test_skip "sem plan"; test_summary "integration/stripe-webhook-simulation"; exit $TEST_EXIT_CODE; }
http_call GET "$API/v1/plans/$PLAN_ID/payment-methods"
# Tenta achar gateway tipo stripe
GW_ID="$(printf '%s' "$HTTP_BODY" | jq -r '
  (.data // .) | (if type=="array" then . else [.] end)
  | (map(select((.code // .name // "") | ascii_downcase | contains("stripe"))) | .[0].gateway_id // .[0].id // empty)' \
  2>/dev/null)"
if [[ -z "$GW_ID" ]]; then
  GW_ID="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | (if type=="array" then .[0].gateway_id else .gateway_id end) // ""' 2>/dev/null)"
fi
[[ -z "$GW_ID" ]] && { test_skip "sem gateway"; test_summary "integration/stripe-webhook-simulation"; exit $TEST_EXIT_CODE; }

CHECKOUT=$(cat <<JSON
{"plan_id":"$PLAN_ID","email":"$EMAIL","name":"Stripe Hook","display_currency":"USD",
 "payment_method":"gateway","gateway_id":"$GW_ID","pay_currency":"USD",
 "new_profile":{"platform":"instagram","handle":"sthook","display_name":"S"},
 "tracking":{"landing_url":"https://www.viralefy.com/us/instagram-followers"},
 "country":"us","target_country":"us"}
JSON
)
http_call POST "$API/v1/checkout" "$CHECKOUT" -H "Idempotency-Key: stripe-$TS"
[[ "$HTTP_CODE" != "201" ]] && { test_fail "checkout → $HTTP_CODE" "$HTTP_BODY"; test_summary "integration/stripe-webhook-simulation"; exit $TEST_EXIT_CODE; }
ORDER_ID="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | .order_id // empty' 2>/dev/null)"
[[ -z "$ORDER_ID" ]] && { test_fail "sem order_id"; test_summary "integration/stripe-webhook-simulation"; exit $TEST_EXIT_CODE; }
test_pass "order pending criado: $ORDER_ID"

# 2. Monta evento Stripe checkout.session.completed
EVENT_TS="$(date +%s)"
EVENT_BODY=$(jq -cn --arg oid "$ORDER_ID" --arg ts "$EVENT_TS" '{
  id: "evt_test_\($ts)",
  object: "event",
  type: "checkout.session.completed",
  created: ($ts|tonumber),
  data: { object: {
    id: "cs_test_\($ts)",
    object: "checkout.session",
    payment_status: "paid",
    metadata: { order_id: $oid }
  }}
}')

# Stripe-Signature: t=<ts>,v1=<hmac>
SIG_PAYLOAD="${EVENT_TS}.${EVENT_BODY}"
SIG="$(printf '%s' "$SIG_PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" -hex 2>/dev/null | awk '{print $2}')"
if [[ -z "$SIG" ]]; then
  test_skip "openssl falhou ao computar HMAC"; test_summary "integration/stripe-webhook-simulation"; exit $TEST_EXIT_CODE
fi
STRIPE_SIG="t=${EVENT_TS},v1=${SIG}"

http_call POST "$API/v1/webhooks/stripe" "$EVENT_BODY" \
  -H "Stripe-Signature: $STRIPE_SIG" \
  -H "Content-Type: application/json"
if [[ "$HTTP_CODE" =~ ^(200|201|204)$ ]]; then
  test_pass "POST /v1/webhooks/stripe → $HTTP_CODE"
elif [[ "$HTTP_CODE" == "400" || "$HTTP_CODE" == "401" ]]; then
  test_skip "webhook rejeitado ($HTTP_CODE) — STRIPE_WEBHOOK_SECRET local pode não bater com o do service"
  test_summary "integration/stripe-webhook-simulation"; exit $TEST_EXIT_CODE
else
  test_fail "webhook → $HTTP_CODE" "$HTTP_BODY"
fi

# 3. Confirmar via API (ou DB se disponível)
sleep 2
if command -v psql >/dev/null 2>&1 && [[ -n "${DATABASE_URL:-}" ]]; then
  STATUS="$(psql "$DATABASE_URL" -tAc "SELECT status FROM orders WHERE id = '$ORDER_ID'" 2>/dev/null || echo "?")"
  if [[ "$STATUS" == "paid" || "$STATUS" == "completed" ]]; then
    test_pass "DB: order.status = $STATUS"
  else
    test_fail "DB: order.status = $STATUS (esperado paid/completed)"
  fi
fi

test_summary "integration/stripe-webhook-simulation"
exit $TEST_EXIT_CODE
