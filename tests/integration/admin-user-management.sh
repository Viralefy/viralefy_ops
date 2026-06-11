#!/usr/bin/env bash
# integration · admin-user-management
# Admin lista, busca, ajusta credits de usuários via /v1/admin/users.
# Requer um user de teste pré-existente (registramos um aqui pra garantir).

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "integration · admin-user-management"

API="$(api_base)"
EMAIL="${VIRALEFY_TEST_SUPERADMIN_EMAIL:-superadmin@viralefy.test}"
PASS="${VIRALEFY_TEST_SUPERADMIN_PASS:-}"

if [[ -z "$PASS" ]]; then
  test_skip "VIRALEFY_TEST_SUPERADMIN_PASS não setada"
  test_summary "integration/admin-user-management"
  exit $TEST_EXIT_CODE
fi
if ! command -v jq >/dev/null 2>&1; then
  test_skip "jq ausente"
  test_summary "integration/admin-user-management"
  exit $TEST_EXIT_CODE
fi

# 1. Cria user teste (target do management)
TS="$(date +%s%N)"
TARGET_EMAIL="adm-mgmt-${TS}@viralefy.test"
http_call POST "$API/v1/auth/user/register" \
  "$(jq -cn --arg e "$TARGET_EMAIL" \
    '{name:"Adm Mgmt Target", email:$e, password:"SimTest!Strong#9aZ", turnstile_token:""}')"
if [[ ! "$HTTP_CODE" =~ ^(200|201)$ ]]; then
  test_skip "register target falhou ($HTTP_CODE)"
  test_summary "integration/admin-user-management"
  exit $TEST_EXIT_CODE
fi
test_pass "target user criado ($TARGET_EMAIL)"

# 2. Login admin
http_call POST "$API/v1/auth/login" \
  "$(jq -cn --arg e "$EMAIL" --arg p "$PASS" '{email:$e, password:$p, turnstile_token:""}')"
TOKEN="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | .access_token // .token // empty' 2>/dev/null)"
if [[ -z "$TOKEN" ]]; then
  test_skip "login admin não retornou access_token"
  test_summary "integration/admin-user-management"
  exit $TEST_EXIT_CODE
fi
test_pass "login admin ok"

# 3. GET /v1/admin/users?email=<target>
http_call GET "$API/v1/admin/users?email=$TARGET_EMAIL" "" -H "Authorization: Bearer $TOKEN"
USER_ID=""
if [[ "$HTTP_CODE" == "200" ]]; then
  USER_ID="$(printf '%s' "$HTTP_BODY" | jq -r '
    (.data // .) as $d
    | (if ($d|type)=="array" then $d[0].id else $d.id // empty end)' 2>/dev/null)"
  if [[ -n "$USER_ID" && "$USER_ID" != "null" ]]; then
    test_pass "GET /v1/admin/users?email=... → 200 (id=$USER_ID)"
  else
    test_fail "user_id não extraído" "$HTTP_BODY"
  fi
else
  test_fail "GET /v1/admin/users → $HTTP_CODE" "$HTTP_BODY"
fi

if [[ -z "$USER_ID" || "$USER_ID" == "null" ]]; then
  test_summary "integration/admin-user-management"
  exit $TEST_EXIT_CODE
fi

# 4. POST /v1/admin/users/<id>/credits/adjust
ADJUST="$(jq -cn '{amount:100, reason:"integration test"}')"
http_call POST "$API/v1/admin/users/$USER_ID/credits/adjust" "$ADJUST" \
  -H "Authorization: Bearer $TOKEN"
if [[ "$HTTP_CODE" =~ ^(200|201|204)$ ]]; then
  test_pass "POST /v1/admin/users/$USER_ID/credits/adjust → $HTTP_CODE"
else
  test_fail "credits/adjust → $HTTP_CODE" "$HTTP_BODY"
fi

# 5. GET /v1/admin/users/<id> → confirma user existe
http_call GET "$API/v1/admin/users/$USER_ID" "" -H "Authorization: Bearer $TOKEN"
if [[ "$HTTP_CODE" == "200" ]]; then
  test_pass "GET /v1/admin/users/$USER_ID → 200"
else
  test_fail "GET /v1/admin/users/$USER_ID → $HTTP_CODE" "$HTTP_BODY"
fi

test_summary "integration/admin-user-management"
exit $TEST_EXIT_CODE
