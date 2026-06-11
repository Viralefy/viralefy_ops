#!/usr/bin/env bash
# smoke · observability-stack
# Prometheus + Grafana + Loki respondem nos endpoints de health/-/ready.
# Skip silencioso quando obs stack não está local (CI externo).

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "smoke · observability-stack"

check() {
  local svc="$1" url="$2"
  http_call GET "$url"
  case "$HTTP_CODE" in
    200|204|302) test_pass "$svc $url → $HTTP_CODE" ;;
    000)         test_skip "$svc $url" "não disponível neste host" ;;
    *)           test_fail "$svc $url → $HTTP_CODE (esperado 200/204/302)" "$HTTP_BODY" ;;
  esac
}

check "prometheus" "$(prom_base)/-/healthy"
check "grafana"    "$(grafana_base)/api/health"
check "loki"       "$(loki_base)/ready"

test_summary "smoke/observability-stack"
exit $TEST_EXIT_CODE
