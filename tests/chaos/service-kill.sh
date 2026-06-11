#!/usr/bin/env bash
# chaos · service-kill (DESTRUTIVO — gated por EDUCE_CHAOS_ALLOW=1)
# Para viralefy-auth, observa upstream-down do dispatcher, sobe novamente
# e mede tempo de recuperação.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "chaos · service-kill"

API="$(api_base)"

if [[ "${EDUCE_CHAOS_ALLOW:-0}" != "1" ]]; then
  test_skip "EDUCE_CHAOS_ALLOW != 1 — chaos destrutivo desabilitado"
  test_summary "chaos/service-kill"; exit $TEST_EXIT_CODE
fi
if ! command -v systemctl >/dev/null 2>&1; then
  test_skip "systemctl ausente"; test_summary "chaos/service-kill"; exit $TEST_EXIT_CODE
fi
if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
  test_skip "precisa de root/sudo pra systemctl"; test_summary "chaos/service-kill"; exit $TEST_EXIT_CODE
fi

SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

SVC="viralefy-auth"

# Estado inicial
http_call POST "$API/v1/auth/user/login" \
  '{"email":"chaos-noexist@viralefy.test","password":"x","turnstile_token":""}'
INITIAL_CODE="$HTTP_CODE"
test_pass "estado inicial: /v1/auth/user/login → $INITIAL_CODE"

# Para o service
$SUDO systemctl stop "$SVC" 2>/dev/null
sleep 2
http_call POST "$API/v1/auth/user/login" \
  '{"email":"chaos-noexist@viralefy.test","password":"x","turnstile_token":""}'
if [[ "$HTTP_CODE" =~ ^(502|503|504)$ ]]; then
  test_pass "com $SVC parado: $HTTP_CODE (upstream down)"
else
  test_fail "esperado 502/503/504 com $SVC parado, got $HTTP_CODE" "$HTTP_BODY"
fi

# Sobe de novo
$SUDO systemctl start "$SVC" 2>/dev/null

# Mede tempo de recuperação
T0=$(date +%s)
DEADLINE=$((T0 + 60))
RECOVERED=0
while (( $(date +%s) < DEADLINE )); do
  http_call POST "$API/v1/auth/user/login" \
    '{"email":"chaos-noexist@viralefy.test","password":"x","turnstile_token":""}'
  if [[ "$HTTP_CODE" == "$INITIAL_CODE" || "$HTTP_CODE" =~ ^(401|422)$ ]]; then
    RECOVERED=1
    break
  fi
  sleep 1
done
ELAPSED=$(( $(date +%s) - T0 ))

if (( RECOVERED == 1 )); then
  test_pass "recuperou em ${ELAPSED}s ($HTTP_CODE)"
else
  test_fail "não recuperou após 60s ($HTTP_CODE)" "$HTTP_BODY"
fi

test_summary "chaos/service-kill"
exit $TEST_EXIT_CODE
