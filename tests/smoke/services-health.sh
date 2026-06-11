#!/usr/bin/env bash
# smoke · services-health
# Verifica /health unificado (PHASE-10) em todos os services em execução.
# Esperado: 200 nos services live; tolera 000 ("connection refused") nos
# services PHASE-9 que ainda não foram habilitados no host (skip).
# Falha: qualquer service rodando mas retornando != 200.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "smoke · services-health"

# Map de service → URL canônico. Dispatcher é o ponto único pós-PHASE-9.
declare -a TARGETS=(
  "dispatcher  $(dispatcher_base)/health"
  "payments   $(payments_base)/health"
  "sender     $(sender_base)/health"
  "core       $(core_base)/health"
  "auth       $(auth_base)/health"
)

for entry in "${TARGETS[@]}"; do
  svc="${entry%% *}"
  url="${entry##* }"
  http_call GET "$url"
  case "$HTTP_CODE" in
    200) test_pass "$svc $url → 200" ;;
    000) test_skip "$svc $url" "connection refused (service não rodando neste host)" ;;
    *)   test_fail "$svc $url → $HTTP_CODE (esperado 200)" "$HTTP_BODY" ;;
  esac
done

test_summary "smoke/services-health"
exit $TEST_EXIT_CODE
