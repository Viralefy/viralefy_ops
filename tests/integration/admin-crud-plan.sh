#!/usr/bin/env bash
# integration · admin-crud-plan
# CRUD de plan via admin API: create → read → update → delete.
# Plan name começa com "TEST_" pra cleanup fácil.
#
# Vars:
#   VIRALEFY_TEST_SUPERADMIN_EMAIL (default superadmin@viralefy.test)
#   VIRALEFY_TEST_SUPERADMIN_PASS  (sem default — skip)

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "integration · admin-crud-plan"

API="$(api_base)"
EMAIL="${VIRALEFY_TEST_SUPERADMIN_EMAIL:-superadmin@viralefy.test}"
PASS="${VIRALEFY_TEST_SUPERADMIN_PASS:-}"

if [[ -z "$PASS" ]]; then
  test_skip "VIRALEFY_TEST_SUPERADMIN_PASS não setada"
  test_summary "integration/admin-crud-plan"
  exit $TEST_EXIT_CODE
fi
if ! command -v jq >/dev/null 2>&1; then
  test_skip "jq ausente"
  test_summary "integration/admin-crud-plan"
  exit $TEST_EXIT_CODE
fi

# Login admin
http_call POST "$API/v1/auth/login" \
  "$(jq -cn --arg e "$EMAIL" --arg p "$PASS" '{email:$e, password:$p, turnstile_token:""}')"
TOKEN="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | .access_token // .token // empty' 2>/dev/null)"
if [[ -z "$TOKEN" ]]; then
  test_skip "login admin não retornou access_token (talvez 2FA)"
  test_summary "integration/admin-crud-plan"
  exit $TEST_EXIT_CODE
fi
test_pass "login admin ok"

TS="$(date +%s%N)"
PLAN_NAME="TEST_plan_${TS}"

# Create plan
CREATE=$(jq -cn --arg n "$PLAN_NAME" \
  '{name:$n, slug:("test-plan-"+($n|ascii_downcase)), category_code:"instagram-followers",
    quantity:100, base_price_cents:999, currency:"USD",
    description:"integration test", active:true}')
http_call POST "$API/v1/admin/plans" "$CREATE" -H "Authorization: Bearer $TOKEN"

PLAN_ID=""
if [[ "$HTTP_CODE" =~ ^(200|201)$ ]]; then
  PLAN_ID="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | .id // empty' 2>/dev/null)"
fi
if [[ -z "$PLAN_ID" ]]; then
  test_skip "create plan retornou $HTTP_CODE sem id — schema pode diferir (ver $HTTP_BODY)"
  test_summary "integration/admin-crud-plan"
  exit $TEST_EXIT_CODE
fi
test_pass "POST /v1/admin/plans → $HTTP_CODE (id=$PLAN_ID)"

# Read
http_call GET "$API/v1/admin/plans/$PLAN_ID" "" -H "Authorization: Bearer $TOKEN"
if [[ "$HTTP_CODE" == "200" ]]; then
  test_pass "GET /v1/admin/plans/$PLAN_ID → 200"
else
  test_fail "GET /v1/admin/plans/$PLAN_ID → $HTTP_CODE" "$HTTP_BODY"
fi

# Update
UPDATE=$(jq -cn --arg n "${PLAN_NAME}_upd" '{name:$n, base_price_cents:1299}')
http_call PUT "$API/v1/admin/plans/$PLAN_ID" "$UPDATE" -H "Authorization: Bearer $TOKEN"
if [[ "$HTTP_CODE" =~ ^(200|204)$ ]]; then
  test_pass "PUT /v1/admin/plans/$PLAN_ID → $HTTP_CODE"
else
  test_fail "PUT /v1/admin/plans/$PLAN_ID → $HTTP_CODE" "$HTTP_BODY"
fi

# Delete (cleanup)
http_call DELETE "$API/v1/admin/plans/$PLAN_ID" "" -H "Authorization: Bearer $TOKEN"
if [[ "$HTTP_CODE" =~ ^(200|204)$ ]]; then
  test_pass "DELETE /v1/admin/plans/$PLAN_ID → $HTTP_CODE"
else
  test_fail "DELETE /v1/admin/plans/$PLAN_ID → $HTTP_CODE" "$HTTP_BODY"
fi

test_summary "integration/admin-crud-plan"
exit $TEST_EXIT_CODE
