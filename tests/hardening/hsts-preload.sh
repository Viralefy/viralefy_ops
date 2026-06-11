#!/usr/bin/env bash
# Hardening · hsts-preload
# Consulta a API oficial do HSTS Preload List (https://hstspreload.org) pra
# saber se viralefy.com está na lista.
# Esperado: status == "preloaded".
# Aceita também "pending" (submissão em curso) com aviso.
# Falha = domínio fora da preload list e nem submetido → primeiro hit ainda
# usa http://.
# Skip se sem rede ou curl.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "Hardening · hsts-preload"

if ! command -v curl >/dev/null 2>&1; then
  test_skip "curl ausente"
  test_summary "hardening/hsts-preload"
  exit $TEST_EXIT_CODE
fi

ZONE="${VIRALEFY_TEST_ZONE:-viralefy.com}"
url="https://hstspreload.org/api/v2/status?domain=${ZONE}"

body="$(curl -sS --max-time 10 --connect-timeout 5 "$url" 2>/dev/null || true)"

if [[ -z "$body" ]]; then
  test_skip "hstspreload.org inacessível" "rodando offline?"
  test_summary "hardening/hsts-preload"
  exit $TEST_EXIT_CODE
fi

status="$(echo "$body" | jq -r '.status // "unknown"' 2>/dev/null)"

case "$status" in
  preloaded)
    test_pass "$ZONE: preloaded ✓"
    ;;
  pending)
    test_skip "$ZONE: pending (submissão em curso)"
    ;;
  unknown|"")
    test_fail "$ZONE: NÃO preloaded — submeter em https://hstspreload.org/?domain=$ZONE" "$body"
    ;;
  *)
    test_fail "$ZONE: status=$status (inesperado)" "$body"
    ;;
esac

test_summary "hardening/hsts-preload"
exit $TEST_EXIT_CODE
