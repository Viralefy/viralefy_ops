#!/usr/bin/env bash
# chaos · memory-pressure
# 20 POSTs sequenciais com body de ~2MB em /v1/checkout. Mede RSS dos
# services antes e depois — não deve subir > 50MB persistentes (vazamento).
# Sem ps disponível, skipa medição mas ainda exercita o caminho.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "chaos · memory-pressure"

API="$(api_base)"

# Coleta RSS (KB) de um service pelo pid systemd
rss_of() {
  local svc="$1"
  if command -v systemctl >/dev/null 2>&1; then
    local pid
    pid="$(systemctl show -p MainPID --value "$svc" 2>/dev/null || echo 0)"
    if [[ "$pid" != "0" && -n "$pid" && -r "/proc/$pid/status" ]]; then
      awk '/VmRSS/{print $2}' "/proc/$pid/status"
      return
    fi
  fi
  echo "0"
}

CORE0=$(rss_of viralefy-core)
DISP0=$(rss_of viralefy-dispatcher)
echo "  RSS inicial: core=${CORE0}KB dispatcher=${DISP0}KB"

# Body grande: tracking com payload reproduzido bytes filler
FILLER="$(printf 'X%.0s' {1..2000000})"  # 2 MB
PLAN_BODY=$(jq -cn --arg f "$FILLER" '{
  plan_id:"00000000-0000-0000-0000-000000000000",
  email:"mempressure@viralefy.test",
  name:"Mem",
  display_currency:"USD",
  payment_method:"gateway",
  gateway_id:"00000000-0000-0000-0000-000000000000",
  pay_currency:"USDT",
  new_profile:{platform:"instagram",handle:"x",display_name:"x"},
  tracking:{landing_url:"https://www.viralefy.com/us/instagram-followers", filler:$f},
  country:"us", target_country:"us"
}')

OK_CODES=0
SERVER_5XX=0
for i in $(seq 1 20); do
  http_call POST "$API/v1/checkout" "$PLAN_BODY" -H "Idempotency-Key: mem-$i-$(date +%s%N)"
  if [[ "$HTTP_CODE" =~ ^5 ]]; then
    SERVER_5XX=$((SERVER_5XX+1))
  else
    OK_CODES=$((OK_CODES+1))
  fi
done
echo "  20 POSTs grandes: $OK_CODES não-5xx / $SERVER_5XX 5xx"

if (( SERVER_5XX == 0 )); then
  test_pass "sem 5xx em 20 POSTs grandes"
else
  test_fail "$SERVER_5XX 5xx em 20 POSTs grandes"
fi

sleep 3
CORE1=$(rss_of viralefy-core)
DISP1=$(rss_of viralefy-dispatcher)
echo "  RSS final:   core=${CORE1}KB dispatcher=${DISP1}KB"

if [[ "$CORE0" != "0" && "$CORE1" != "0" ]]; then
  DELTA=$(( CORE1 - CORE0 ))
  if (( DELTA < 51200 )); then
    test_pass "core RSS Δ=${DELTA}KB (< 50MB)"
  else
    test_fail "core RSS subiu ${DELTA}KB (≥ 50MB — possível vazamento)"
  fi
else
  test_skip "RSS não disponível (sem permissão pra /proc/<pid>/status?)"
fi

test_summary "chaos/memory-pressure"
exit $TEST_EXIT_CODE
