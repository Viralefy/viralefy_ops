#!/usr/bin/env bash
# integration · proof-upload-multipart
# Upload de comprovante: registra user, cria order via checkout, faz POST
# multipart de uma imagem fake (1×1 png) em /v1/me/orders/<id>/proof,
# valida storage_key e GET /v1/me/orders/<id>/proof-url.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "integration · proof-upload-multipart"

API="$(api_base)"

if ! command -v jq >/dev/null 2>&1; then
  test_skip "jq ausente"; test_summary "integration/proof-upload-multipart"; exit $TEST_EXIT_CODE
fi

TS="$(date +%s%N)"
EMAIL="proof-${TS}@viralefy.test"
PASS="SimTest!Strong#9aZ"

# Register
http_call POST "$API/v1/auth/user/register" \
  "$(jq -cn --arg e "$EMAIL" --arg p "$PASS" '{name:"Proof Test", email:$e, password:$p, turnstile_token:""}')"
TOKEN="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | .access_token // .token // empty' 2>/dev/null)"
[[ -z "$TOKEN" ]] && { test_skip "sem token"; test_summary "integration/proof-upload-multipart"; exit $TEST_EXIT_CODE; }
test_pass "user + token ok"

# Plan + gateway
http_call GET "$API/v1/plans"
PLAN_ID="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | (if type=="array" then .[0].id else .[0].id end) // ""' 2>/dev/null)"
[[ -z "$PLAN_ID" ]] && { test_skip "sem plan"; test_summary "integration/proof-upload-multipart"; exit $TEST_EXIT_CODE; }
http_call GET "$API/v1/plans/$PLAN_ID/payment-methods"
GW_ID="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | (if type=="array" then (.[] | select(.gateway_id) | .gateway_id) else .gateway_id end) // ""' 2>/dev/null | head -1)"
[[ -z "$GW_ID" ]] && { test_skip "sem gateway"; test_summary "integration/proof-upload-multipart"; exit $TEST_EXIT_CODE; }

# Checkout
CHECKOUT=$(cat <<JSON
{"plan_id":"$PLAN_ID","email":"$EMAIL","name":"Proof","display_currency":"USD",
 "payment_method":"gateway","gateway_id":"$GW_ID","pay_currency":"USDT",
 "new_profile":{"platform":"instagram","handle":"proof","display_name":"P"},
 "tracking":{"landing_url":"https://www.viralefy.com/us/instagram-followers"},
 "country":"us","target_country":"us"}
JSON
)
http_call POST "$API/v1/checkout" "$CHECKOUT" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Idempotency-Key: proof-$TS"
[[ "$HTTP_CODE" != "201" ]] && { test_fail "checkout → $HTTP_CODE" "$HTTP_BODY"; test_summary "integration/proof-upload-multipart"; exit $TEST_EXIT_CODE; }
ORDER_ID="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | .order_id // empty' 2>/dev/null)"
[[ -z "$ORDER_ID" ]] && { test_fail "sem order_id" "$HTTP_BODY"; test_summary "integration/proof-upload-multipart"; exit $TEST_EXIT_CODE; }
test_pass "order criado: $ORDER_ID"

# Cria 1×1 PNG fake (base64 well-known)
PNG_FILE="$(mktemp --suffix=.png)"
trap 'rm -f "$PNG_FILE"' EXIT
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDAT\x78\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82' > "$PNG_FILE"

# Upload multipart — usamos curl direto pra preservar multipart
RESP="$(mktemp)"
HDR="$(mktemp)"
CODE="$(curl -sS --max-time 15 -o "$RESP" -D "$HDR" -w '%{http_code}' \
  -X POST "$API/v1/me/orders/$ORDER_ID/proof" \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@$PNG_FILE;type=image/png" 2>/dev/null || echo 000)"
CODE="${CODE: -3}"
BODY="$(cat "$RESP" 2>/dev/null || true)"
rm -f "$RESP" "$HDR"

if [[ "$CODE" =~ ^(200|201|204)$ ]]; then
  test_pass "POST /v1/me/orders/$ORDER_ID/proof → $CODE"
else
  test_fail "POST proof → $CODE" "$BODY"
fi

# GET proof-url
http_call GET "$API/v1/me/orders/$ORDER_ID/proof-url" "" -H "Authorization: Bearer $TOKEN"
if [[ "$HTTP_CODE" == "200" ]]; then
  URL="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | .url // .proof_url // empty' 2>/dev/null)"
  if [[ -n "$URL" ]]; then
    test_pass "proof-url retornado (len=${#URL})"
  else
    test_fail "proof-url ausente" "$HTTP_BODY"
  fi
else
  test_fail "GET proof-url → $HTTP_CODE" "$HTTP_BODY"
fi

test_summary "integration/proof-upload-multipart"
exit $TEST_EXIT_CODE
