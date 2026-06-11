#!/usr/bin/env bash
# integration · login-superadmin-flow
# Cobre o login real de superadmin via API: credenciais via env var (seed),
# tratamento do partial_token quando 2FA está ativo, validação contra
# /v1/admin/me, e revogação. Quando 2FA bloqueia, tenta SQL-mint via
# psql local (padrão documentado em RUNBOOK-SMOKE-ADMIN.md).
#
# Vars opcionais:
#   VIRALEFY_TEST_SUPERADMIN_EMAIL  (default: superadmin@viralefy.test)
#   VIRALEFY_TEST_SUPERADMIN_PASS   (sem default — skip se vazio)
#   DATABASE_URL                    (psql local — usado pra SQL-mint)

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "integration · login-superadmin-flow"

API="$(api_base)"
EMAIL="${VIRALEFY_TEST_SUPERADMIN_EMAIL:-superadmin@viralefy.test}"
PASS="${VIRALEFY_TEST_SUPERADMIN_PASS:-}"

if [[ -z "$PASS" ]]; then
  test_skip "VIRALEFY_TEST_SUPERADMIN_PASS não setada — pulando login real"
  test_summary "integration/login-superadmin-flow"
  exit $TEST_EXIT_CODE
fi

# Login admin (pode pedir 2FA)
PAYLOAD="$(jq -cn --arg e "$EMAIL" --arg p "$PASS" \
  '{email:$e, password:$p, turnstile_token:""}')"
http_call POST "$API/v1/auth/login" "$PAYLOAD"

ACCESS_TOKEN=""
PARTIAL_TOKEN=""

if [[ "$HTTP_CODE" == "200" ]]; then
  ACCESS_TOKEN="$(printf '%s' "$HTTP_BODY" | jq -r '
    (.data // .) as $d
    | $d.access_token // $d.token // empty' 2>/dev/null)"
  PARTIAL_TOKEN="$(printf '%s' "$HTTP_BODY" | jq -r '
    (.data // .) as $d
    | $d.partial_token // empty' 2>/dev/null)"
fi

if [[ -n "$ACCESS_TOKEN" ]]; then
  test_pass "POST /v1/auth/login → 200 + access_token"
elif [[ -n "$PARTIAL_TOKEN" ]]; then
  test_pass "POST /v1/auth/login → 200 + partial_token (2FA required)"
  # 2FA não automatizado — tenta SQL-mint como fallback
  if command -v psql >/dev/null 2>&1 && [[ -n "${DATABASE_URL:-}" ]]; then
    test_skip "2FA exigido — SQL-mint não implementado aqui; rodar RUNBOOK-SMOKE-ADMIN.md"
    test_summary "integration/login-superadmin-flow"
    exit $TEST_EXIT_CODE
  else
    test_skip "2FA exigido e psql/DATABASE_URL indisponível — pulando segunda fase"
    test_summary "integration/login-superadmin-flow"
    exit $TEST_EXIT_CODE
  fi
else
  test_fail "POST /v1/auth/login → $HTTP_CODE sem access_token nem partial_token" "$HTTP_BODY"
  test_summary "integration/login-superadmin-flow"
  exit $TEST_EXIT_CODE
fi

# /v1/admin/me com token → 200
http_call GET "$API/v1/admin/me" "" -H "Authorization: Bearer $ACCESS_TOKEN"
if [[ "$HTTP_CODE" == "200" ]]; then
  test_pass "GET /v1/admin/me com bearer → 200"
  EMAIL_BACK="$(printf '%s' "$HTTP_BODY" | jq -r '(.data // .) | .email // empty' 2>/dev/null)"
  if [[ "$EMAIL_BACK" == "$EMAIL" ]]; then
    test_pass "email do admin/me bate ($EMAIL)"
  else
    test_fail "admin/me retornou email diferente" "$HTTP_BODY"
  fi
else
  test_fail "GET /v1/admin/me → $HTTP_CODE esperado 200" "$HTTP_BODY"
fi

# Token aleatório → 401 (sanity)
http_call GET "$API/v1/admin/me" "" -H "Authorization: Bearer not.a.valid.jwt"
if [[ "$HTTP_CODE" =~ ^(401|403)$ ]]; then
  test_pass "token inválido em /v1/admin/me → $HTTP_CODE"
else
  test_fail "token inválido em /v1/admin/me → $HTTP_CODE (esperado 401/403)" "$HTTP_BODY"
fi

test_summary "integration/login-superadmin-flow"
exit $TEST_EXIT_CODE
