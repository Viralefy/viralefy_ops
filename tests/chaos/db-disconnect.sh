#!/usr/bin/env bash
# chaos · db-disconnect (DESTRUTIVO — gated por EDUCE_CHAOS_ALLOW=1)
# Bloqueia saída para Postgres com iptables, verifica que pool degrada
# graciosamente, desbloqueia, verifica recuperação.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "chaos · db-disconnect"

API="$(api_base)"

if [[ "${EDUCE_CHAOS_ALLOW:-0}" != "1" ]]; then
  test_skip "EDUCE_CHAOS_ALLOW != 1"; test_summary "chaos/db-disconnect"; exit $TEST_EXIT_CODE
fi
if ! command -v iptables >/dev/null 2>&1; then
  test_skip "iptables ausente"; test_summary "chaos/db-disconnect"; exit $TEST_EXIT_CODE
fi
if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
  test_skip "precisa root/sudo"; test_summary "chaos/db-disconnect"; exit $TEST_EXIT_CODE
fi
SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"

# Sanity inicial: /v1/plans depende do DB
http_call GET "$API/v1/plans"
[[ "$HTTP_CODE" != "200" ]] && {
  test_skip "/v1/plans não está 200 antes de bloquear (estado base ruim, $HTTP_CODE)"
  test_summary "chaos/db-disconnect"; exit $TEST_EXIT_CODE
}
test_pass "estado inicial: /v1/plans → 200"

# Trap pra GARANTIR desbloqueio mesmo se algo explodir
cleanup_db() {
  $SUDO iptables -D OUTPUT -p tcp --dport 5432 -j DROP 2>/dev/null || true
  $SUDO iptables -D OUTPUT -p tcp --dport 15432 -j DROP 2>/dev/null || true
}
trap cleanup_db EXIT

# Bloqueia
$SUDO iptables -A OUTPUT -p tcp --dport 5432 -j DROP
$SUDO iptables -A OUTPUT -p tcp --dport 15432 -j DROP
sleep 3

# Hit endpoint que depende de DB
http_call GET "$API/v1/plans"
if [[ "$HTTP_CODE" =~ ^(500|502|503|504)$ ]]; then
  test_pass "com DB bloqueado: /v1/plans → $HTTP_CODE (degradou)"
elif [[ "$HTTP_CODE" == "200" ]]; then
  # Pode estar servindo de cache — aceitável
  test_pass "com DB bloqueado: /v1/plans → 200 (cache layer)"
else
  test_fail "DB bloqueado, código inesperado: $HTTP_CODE" "$HTTP_BODY"
fi

# Desbloqueia
cleanup_db
trap - EXIT
sleep 5

# Recovery
RECOVERED=0
for i in $(seq 1 20); do
  http_call GET "$API/v1/plans"
  if [[ "$HTTP_CODE" == "200" ]]; then RECOVERED=1; break; fi
  sleep 1
done

if (( RECOVERED == 1 )); then
  test_pass "/v1/plans recuperou em ${i}s"
else
  test_fail "/v1/plans não recuperou após 20s" "$HTTP_BODY"
fi

test_summary "chaos/db-disconnect"
exit $TEST_EXIT_CODE
