#!/usr/bin/env bash
# authz · hot-set-revocation-authz
# Token revogado em revoked_jtis + NOTIFY 'revoked_jtis_inserted' deve
# bloquear o token em <5s (dispatcher Rust faz LISTEN).
#
# Regression test — já validado em RUNBOOK-SMOKE-ADMIN.md mas vale ter aqui
# pra trigger no `viralefy test authz` (e portanto no PR check).
#
# Falha = revocation lenta ou ignorada → ataque pós-logout.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"
# shellcheck source=../lib-authz.sh
source "$_DIR/lib-authz.sh"

test_section "authz · hot-set-revocation-authz"
authz_check_prereqs

API="$(api_base)"

# Mint token superadmin com JTI capturado
MINT_OUT="$(mint_admin_token superadmin)"
TOK="$(mint_token "$MINT_OUT")"
REV_JTI="$(mint_jti "$MINT_OUT")"
if [[ -z "$TOK" || -z "$REV_JTI" || "$TOK" == "$REV_JTI" ]]; then
  test_fail "mint_admin_token / jti capture falhou (out=$MINT_OUT)"
  test_summary "authz/hot-set-revocation-authz"
  exit $TEST_EXIT_CODE
fi

# Step 1: token funciona. Governor pode estar saturado se outros scripts
# rodaram antes — fazemos retry com backoff exponencial até 30s.
HTTP_CODE=""
for delay in 1 2 4 8 15; do
  sleep "$delay"
  http_call GET "$API/v1/admin/me" "" -H "Authorization: Bearer $TOK"
  [[ "$HTTP_CODE" != "429" ]] && break
done
if [[ "$HTTP_CODE" == "200" ]]; then
  test_pass "pre-revoke: token funciona (200)"
else
  test_fail "pre-revoke: $HTTP_CODE (esperado 200)" "$HTTP_BODY"
  test_summary "authz/hot-set-revocation-authz"
  exit $TEST_EXIT_CODE
fi

# Step 2: revoke
T_START="$(date +%s%N)"
revoke_jti "$REV_JTI" "authz-test-hotset"

# Step 3: polling até bloquear ou timeout
BLOCKED=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  http_call GET "$API/v1/admin/me" "" -H "Authorization: Bearer $TOK"
  if [[ "$HTTP_CODE" == "401" ]]; then
    BLOCKED=1
    break
  fi
  sleep 0.5
done
T_END="$(date +%s%N)"
ELAPSED_MS=$(( (T_END - T_START) / 1000000 ))

if (( BLOCKED == 1 )); then
  if (( ELAPSED_MS < 5000 )); then
    test_pass "post-revoke: 401 em ${ELAPSED_MS}ms (< 5s)"
  else
    test_fail "post-revoke: 401 mas em ${ELAPSED_MS}ms (esperado < 5000ms)"
  fi
else
  test_fail "post-revoke: token ainda válido após 5s (último HTTP_CODE=$HTTP_CODE)"
fi

# Cleanup
psql_q "DELETE FROM revoked_jtis WHERE jti='$REV_JTI'" >/dev/null 2>&1

test_summary "authz/hot-set-revocation-authz"
exit $TEST_EXIT_CODE
