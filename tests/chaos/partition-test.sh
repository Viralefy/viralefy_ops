#!/usr/bin/env bash
# chaos · partition-test (DESTRUTIVO — gated por EDUCE_CHAOS_ALLOW=1)
# Bloqueia tráfego loopback pra porta do viralefy-core via iptables.
# Validamos que o dispatcher mascarata bem (502/503), não 500/hang.
# Sempre garante unblock no EXIT.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "chaos · partition-test"

API="$(api_base)"
CORE_PORT="${VIRALEFY_TEST_CORE_PORT:-8084}"

if [[ "${EDUCE_CHAOS_ALLOW:-0}" != "1" ]]; then
  test_skip "EDUCE_CHAOS_ALLOW != 1"; test_summary "chaos/partition-test"; exit $TEST_EXIT_CODE
fi
if ! command -v iptables >/dev/null 2>&1; then
  test_skip "iptables ausente"; test_summary "chaos/partition-test"; exit $TEST_EXIT_CODE
fi
if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
  test_skip "root/sudo requerido"; test_summary "chaos/partition-test"; exit $TEST_EXIT_CODE
fi
SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"

# Sanity inicial
http_call GET "$API/v1/plans"
INIT_CODE="$HTTP_CODE"
if [[ "$INIT_CODE" != "200" ]]; then
  test_skip "/v1/plans não 200 antes ($INIT_CODE)"; test_summary "chaos/partition-test"; exit $TEST_EXIT_CODE
fi
test_pass "estado inicial: /v1/plans → 200"

cleanup() {
  $SUDO iptables -D OUTPUT -p tcp --dport "$CORE_PORT" -j DROP 2>/dev/null || true
  $SUDO iptables -D INPUT  -p tcp --dport "$CORE_PORT" -j DROP 2>/dev/null || true
}
trap cleanup EXIT

# Bloqueia
$SUDO iptables -A OUTPUT -p tcp --dport "$CORE_PORT" -j DROP
$SUDO iptables -A INPUT  -p tcp --dport "$CORE_PORT" -j DROP
sleep 2

http_call GET "$API/v1/plans"
if [[ "$HTTP_CODE" =~ ^(502|503|504)$ ]]; then
  test_pass "particionado: dispatcher → core → $HTTP_CODE (correto)"
elif [[ "$HTTP_CODE" =~ ^5 ]]; then
  test_fail "particionado: 5xx mas não 502/503/504 ($HTTP_CODE)" "$HTTP_BODY"
else
  test_fail "particionado: $HTTP_CODE inesperado" "$HTTP_BODY"
fi

# Desbloqueia
cleanup
trap - EXIT
sleep 3

RECOVERED=0
for i in $(seq 1 15); do
  http_call GET "$API/v1/plans"
  [[ "$HTTP_CODE" == "200" ]] && { RECOVERED=1; break; }
  sleep 1
done

if (( RECOVERED == 1 )); then
  test_pass "recuperou em ${i}s"
else
  test_fail "não recuperou após 15s ($HTTP_CODE)" "$HTTP_BODY"
fi

test_summary "chaos/partition-test"
exit $TEST_EXIT_CODE
