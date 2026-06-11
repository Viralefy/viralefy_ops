#!/usr/bin/env bash
# integration · 2fa-enroll-verify-flow
# User registra, enroll 2FA, computa TOTP, verify, login com 2FA partial.
# Usa python3 (stdlib hmac + base32) pra TOTP — sem deps externas.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "integration · 2fa-enroll-verify-flow"

API="$(api_base)"

if ! command -v jq >/dev/null 2>&1; then
  test_skip "jq ausente"; test_summary "integration/2fa-enroll-verify-flow"; exit $TEST_EXIT_CODE
fi
if ! command -v python3 >/dev/null 2>&1; then
  test_skip "python3 ausente — sem TOTP"; test_summary "integration/2fa-enroll-verify-flow"; exit $TEST_EXIT_CODE
fi

# TOTP RFC 6238 em python stdlib
totp() {
  local secret="$1"
  python3 - "$secret" <<'PY'
import sys, hmac, hashlib, base64, struct, time
secret = sys.argv[1].strip().replace(' ', '').upper()
# Padding base32
pad = (-len(secret)) % 8
secret += '=' * pad
try:
    key = base64.b32decode(secret, casefold=True)
except Exception as e:
    sys.exit(1)
counter = int(time.time()) // 30
msg = struct.pack('>Q', counter)
h = hmac.new(key, msg, hashlib.sha1).digest()
o = h[-1] & 0x0F
code = (struct.unpack('>I', h[o:o+4])[0] & 0x7FFFFFFF) % 1000000
print(f"{code:06d}")
PY
}

TS="$(date +%s%N)"
EMAIL="2fa-${TS}@viralefy.test"
PASS="SimTest!Strong#9aZ"

# Register
http_call POST "$API/v1/auth/user/register" \
  "$(jq -cn --arg e "$EMAIL" --arg p "$PASS" '{name:"2FA Test", email:$e, password:$p, turnstile_token:""}')"
if [[ ! "$HTTP_CODE" =~ ^(200|201)$ ]]; then
  test_skip "register falhou ($HTTP_CODE)"; test_summary "integration/2fa-enroll-verify-flow"; exit $TEST_EXIT_CODE
fi
TOKEN="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | .access_token // .token // empty' 2>/dev/null)"
if [[ -z "$TOKEN" ]]; then
  http_call POST "$API/v1/auth/user/login" \
    "$(jq -cn --arg e "$EMAIL" --arg p "$PASS" '{email:$e, password:$p, turnstile_token:""}')"
  TOKEN="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | .access_token // empty' 2>/dev/null)"
fi
if [[ -z "$TOKEN" ]]; then
  test_skip "sem access_token após register/login"; test_summary "integration/2fa-enroll-verify-flow"; exit $TEST_EXIT_CODE
fi
test_pass "user + access_token ok"

# Enroll
http_call POST "$API/v1/me/2fa/enroll" "{}" -H "Authorization: Bearer $TOKEN"
if [[ ! "$HTTP_CODE" =~ ^(200|201)$ ]]; then
  test_fail "POST /v1/me/2fa/enroll → $HTTP_CODE" "$HTTP_BODY"
  test_summary "integration/2fa-enroll-verify-flow"; exit $TEST_EXIT_CODE
fi
SECRET="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | .secret // .secret_base32 // empty' 2>/dev/null)"
if [[ -z "$SECRET" ]]; then
  test_fail "secret ausente no enroll response" "$HTTP_BODY"
  test_summary "integration/2fa-enroll-verify-flow"; exit $TEST_EXIT_CODE
fi
test_pass "enroll → secret recebido"

# Calcula TOTP
CODE="$(totp "$SECRET" 2>/dev/null || true)"
if [[ -z "$CODE" ]]; then
  test_fail "falha ao computar TOTP do secret"
  test_summary "integration/2fa-enroll-verify-flow"; exit $TEST_EXIT_CODE
fi
test_pass "TOTP computado: $CODE"

# Verify
http_call POST "$API/v1/me/2fa/verify" \
  "$(jq -cn --arg c "$CODE" '{code:$c}')" \
  -H "Authorization: Bearer $TOKEN"
if [[ "$HTTP_CODE" =~ ^(200|204)$ ]]; then
  test_pass "POST /v1/me/2fa/verify → $HTTP_CODE"
else
  test_fail "POST /v1/me/2fa/verify → $HTTP_CODE" "$HTTP_BODY"
  test_summary "integration/2fa-enroll-verify-flow"; exit $TEST_EXIT_CODE
fi

# Login subsequente exige 2FA → partial_token
http_call POST "$API/v1/auth/user/login" \
  "$(jq -cn --arg e "$EMAIL" --arg p "$PASS" '{email:$e, password:$p, turnstile_token:""}')"
PARTIAL="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | .partial_token // empty' 2>/dev/null)"
if [[ -n "$PARTIAL" ]]; then
  test_pass "login pós-2FA → partial_token presente"
else
  test_fail "login pós-2FA não retornou partial_token" "$HTTP_BODY"
  test_summary "integration/2fa-enroll-verify-flow"; exit $TEST_EXIT_CODE
fi

# Complete 2FA
sleep 1
CODE2="$(totp "$SECRET")"
http_call POST "$API/v1/auth/user/login/2fa" \
  "$(jq -cn --arg pt "$PARTIAL" --arg c "$CODE2" '{partial_token:$pt, code:$c}')"
if [[ "$HTTP_CODE" == "200" ]]; then
  test_pass "POST /v1/auth/user/login/2fa → 200"
  FULL_TOKEN="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | .access_token // empty' 2>/dev/null)"
  if [[ -n "$FULL_TOKEN" ]]; then
    test_pass "access_token final obtido"
  else
    test_fail "access_token ausente após 2FA complete" "$HTTP_BODY"
  fi
else
  test_fail "POST /v1/auth/user/login/2fa → $HTTP_CODE" "$HTTP_BODY"
fi

test_summary "integration/2fa-enroll-verify-flow"
exit $TEST_EXIT_CODE
