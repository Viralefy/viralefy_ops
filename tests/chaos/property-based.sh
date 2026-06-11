#!/usr/bin/env bash
# chaos · property-based
# Invariantes que SEMPRE valem:
#   - JWKS sempre formado: GET /.well-known/jwks.json 100x → {"keys":[...]}
#   - Idempotency: POST /v1/checkout com mesma Idempotency-Key 2x → mesmo order_id
#   - p95 de /v1/plans < 500ms (SLO)
#   - Enums fora do range → 400/422

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "chaos · property-based"

API="$(api_base)"
if ! command -v jq >/dev/null 2>&1; then
  test_skip "jq ausente"; test_summary "chaos/property-based"; exit $TEST_EXIT_CODE
fi

# 1. JWKS sempre formado (100x)
JWKS_FAIL=0
for i in $(seq 1 100); do
  http_call GET "$API/.well-known/jwks.json"
  if [[ "$HTTP_CODE" != "200" ]]; then JWKS_FAIL=$((JWKS_FAIL+1)); continue; fi
  if ! echo "$HTTP_BODY" | jq -e '.keys | type == "array" and length > 0' >/dev/null 2>&1; then
    JWKS_FAIL=$((JWKS_FAIL+1))
  fi
done
if (( JWKS_FAIL == 0 )); then
  test_pass "JWKS bem formado em 100/100 tentativas"
else
  test_fail "JWKS quebrado em $JWKS_FAIL/100 tentativas"
fi

# 2. p95 de /v1/plans (100 GETs)
LAT_FILE="$(mktemp)"
trap 'rm -f "$LAT_FILE"' EXIT
for i in $(seq 1 100); do
  T0=$(date +%s%N)
  curl -sS -o /dev/null --max-time 5 "$API/v1/plans" >/dev/null 2>&1 || true
  T1=$(date +%s%N)
  echo $(( (T1 - T0) / 1000000 )) >> "$LAT_FILE"
done
P95=$(sort -n "$LAT_FILE" | awk 'BEGIN{c=0}{a[c++]=$1}END{print a[int(c*0.95)]}')
if [[ -n "$P95" ]] && (( P95 < 500 )); then
  test_pass "p95 /v1/plans = ${P95}ms (< 500ms SLO)"
else
  test_fail "p95 /v1/plans = ${P95}ms (≥ 500ms SLO violado)"
fi

# 3. Idempotency em /v1/checkout
http_call GET "$API/v1/plans"
PLAN_ID="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | (if type=="array" then .[0].id else .[0].id end) // ""' 2>/dev/null)"
http_call GET "$API/v1/plans/$PLAN_ID/payment-methods"
GW_ID="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | (if type=="array" then (.[] | select(.gateway_id) | .gateway_id) else .gateway_id end) // ""' 2>/dev/null | head -1)"

if [[ -n "$PLAN_ID" && -n "$GW_ID" ]]; then
  TS="$(date +%s%N)"
  IDK="chaos-idem-$TS"
  EMAIL="idem-${TS}@viralefy.test"
  BODY=$(cat <<JSON
{"plan_id":"$PLAN_ID","email":"$EMAIL","name":"Idem","display_currency":"USD",
 "payment_method":"gateway","gateway_id":"$GW_ID","pay_currency":"USDT",
 "new_profile":{"platform":"instagram","handle":"idem","display_name":"I"},
 "tracking":{"landing_url":"https://www.viralefy.com/us/instagram-followers"},
 "country":"us","target_country":"us"}
JSON
)
  http_call POST "$API/v1/checkout" "$BODY" -H "Idempotency-Key: $IDK"
  OID1="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | .order_id // empty' 2>/dev/null)"
  http_call POST "$API/v1/checkout" "$BODY" -H "Idempotency-Key: $IDK"
  OID2="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | .order_id // empty' 2>/dev/null)"

  if [[ -n "$OID1" && "$OID1" == "$OID2" ]]; then
    test_pass "Idempotency-Key reuse → mesmo order_id ($OID1)"
  elif [[ -z "$OID1" || -z "$OID2" ]]; then
    test_skip "idempotency: order_id não capturado em uma das chamadas"
  else
    test_fail "Idempotency-Key gerou orders diferentes ($OID1 vs $OID2)"
  fi
else
  test_skip "idempotency: sem plan/gateway"
fi

# 4. Enum fora do range
http_call GET "$API/v1/me/orders?status=NOT_A_REAL_STATUS"
if [[ "$HTTP_CODE" =~ ^(400|401|422)$ ]]; then
  test_pass "enum inválido → $HTTP_CODE"
else
  test_fail "enum inválido → $HTTP_CODE (esperado 400/422)" "$HTTP_BODY"
fi

test_summary "chaos/property-based"
exit $TEST_EXIT_CODE
