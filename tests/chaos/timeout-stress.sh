#!/usr/bin/env bash
# chaos · timeout-stress
# Simula endpoints com timeout. A ferramenta abre conexão e mede o tempo
# até resposta. Esperado: resposta em < 30s mesmo em endpoints lentos.
# Hit /v1/checkout (potencialmente bate Stripe/Heleket/Woovi externos —
# pode demorar). Aceitamos qualquer status válido, mas tempo > 30s = fail.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "chaos · timeout-stress"

API="$(api_base)"
if ! command -v jq >/dev/null 2>&1; then
  test_skip "jq ausente"; test_summary "chaos/timeout-stress"; exit $TEST_EXIT_CODE
fi

# Setup minimal
http_call GET "$API/v1/plans"
PLAN_ID="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | (if type=="array" then .[0].id else .[0].id end) // ""' 2>/dev/null)"
if [[ -z "$PLAN_ID" ]]; then
  test_skip "sem plan"; test_summary "chaos/timeout-stress"; exit $TEST_EXIT_CODE
fi
http_call GET "$API/v1/plans/$PLAN_ID/payment-methods"
GW_ID="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | (if type=="array" then (.[] | select(.gateway_id) | .gateway_id) else .gateway_id end) // ""' 2>/dev/null | head -1)"
if [[ -z "$GW_ID" ]]; then
  test_skip "sem gateway"; test_summary "chaos/timeout-stress"; exit $TEST_EXIT_CODE
fi

# Mede tempo de POST checkout — externo ao Stripe pode demorar
TS="$(date +%s%N)"
BODY=$(cat <<JSON
{"plan_id":"$PLAN_ID","email":"timeout-$TS@viralefy.test","name":"To","display_currency":"USD",
 "payment_method":"gateway","gateway_id":"$GW_ID","pay_currency":"USDT",
 "new_profile":{"platform":"instagram","handle":"to","display_name":"T"},
 "tracking":{"landing_url":"https://www.viralefy.com/us/instagram-followers"},
 "country":"us","target_country":"us"}
JSON
)

T0=$(date +%s%N)
TMPB="$(mktemp)"
CODE=$(curl -sS --max-time 35 --connect-timeout 3 -o "$TMPB" -w '%{http_code}' \
  -X POST "$API/v1/checkout" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: timeout-$TS" \
  --data-raw "$BODY" 2>/dev/null || echo 000)
T1=$(date +%s%N)
rm -f "$TMPB"
CODE="${CODE: -3}"
DUR_MS=$(( (T1 - T0) / 1000000 ))
echo "  POST /v1/checkout → $CODE em ${DUR_MS}ms"

if (( DUR_MS >= 30000 )); then
  test_fail "checkout demorou ${DUR_MS}ms (≥ 30s — hang ou timeout configurado mal)"
elif [[ "$CODE" == "000" ]]; then
  test_fail "curl não obteve resposta"
elif [[ "$CODE" =~ ^(2|4)[0-9][0-9]$ || "$CODE" == "504" ]]; then
  test_pass "checkout retornou $CODE em ${DUR_MS}ms (< 30s)"
else
  test_fail "checkout código inesperado $CODE em ${DUR_MS}ms"
fi

# Hit em loop pra confirmar consistência
ITER=5
HANG=0
for i in $(seq 1 $ITER); do
  T0=$(date +%s%N)
  curl -sS --max-time 30 -o /dev/null -w '%{http_code}' "$API/v1/plans" >/dev/null 2>&1
  T1=$(date +%s%N)
  D=$(( (T1 - T0) / 1000000 ))
  if (( D >= 25000 )); then HANG=$((HANG+1)); fi
done
if (( HANG == 0 )); then
  test_pass "$ITER GETs /v1/plans sem hang"
else
  test_fail "$HANG de $ITER GETs deram hang ≥ 25s"
fi

test_summary "chaos/timeout-stress"
exit $TEST_EXIT_CODE
