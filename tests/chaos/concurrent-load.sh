#!/usr/bin/env bash
# chaos · concurrent-load
# 50 GETs paralelos em /v1/plans. Mede success rate + p50/p95/p99.
# Hang > 10s = falha (curl --max-time 10).

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "chaos · concurrent-load"

API="$(api_base)"
N=50
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Lança N curls paralelos. Cada um grava "code:lat_ms" num arquivo.
START=$(date +%s%N)
for i in $(seq 1 "$N"); do
  (
    T0=$(date +%s%N)
    code=$(curl -sS -o /dev/null --max-time 10 --connect-timeout 3 \
      -w '%{http_code}' "$API/v1/plans" 2>/dev/null || echo 000)
    T1=$(date +%s%N)
    lat=$(( (T1 - T0) / 1000000 ))
    echo "${code: -3}:$lat" > "$TMPDIR/$i"
  ) &
done
wait
END=$(date +%s%N)
TOTAL_MS=$(( (END - START) / 1000000 ))

# Agrega
SUCCESS=0
FAIL=0
LATS="$(mktemp)"
for f in "$TMPDIR"/*; do
  IFS=':' read -r code lat < "$f"
  echo "$lat" >> "$LATS"
  if [[ "$code" =~ ^(200|201)$ ]]; then
    SUCCESS=$((SUCCESS+1))
  else
    FAIL=$((FAIL+1))
  fi
done

RATE=$(( SUCCESS * 100 / N ))
P50=$(sort -n "$LATS" | awk -v n=$N 'NR==int(n*0.50)+1{print; exit}')
P95=$(sort -n "$LATS" | awk -v n=$N 'NR==int(n*0.95)+1{print; exit}')
P99=$(sort -n "$LATS" | awk -v n=$N 'NR==int(n*0.99)+1{print; exit}')
rm -f "$LATS"

echo "  stats: success=$SUCCESS/$N (${RATE}%)  total=${TOTAL_MS}ms  p50=${P50}ms p95=${P95}ms p99=${P99}ms"

if (( RATE >= 95 )); then
  test_pass "success rate ${RATE}% (≥ 95%)"
else
  test_fail "success rate ${RATE}% (< 95%)"
fi

if (( P95 < 5000 )); then
  test_pass "p95 ${P95}ms < 5000ms (sob carga)"
else
  test_fail "p95 ${P95}ms ≥ 5000ms"
fi

if (( P99 < 10000 )); then
  test_pass "p99 ${P99}ms < 10000ms (no hang)"
else
  test_fail "p99 ${P99}ms ≥ 10000ms (alguns hangs)"
fi

test_summary "chaos/concurrent-load"
exit $TEST_EXIT_CODE
