#!/usr/bin/env bash
# Security · npm-audit
# Roda `npm audit --audit-level=high` nos pacotes Node do projeto.
# Esperado: 0 vulnerabilidades high/critical.
# Falha = CVE conhecido em deps Node → bloqueia deploy.
#
# Skip se npm ausente ou nenhum package-lock.json encontrado.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "Security · npm-audit"

if ! command -v npm >/dev/null 2>&1; then
  test_skip "npm ausente"
  test_summary "security/npm-audit"
  exit $TEST_EXIT_CODE
fi

# Heurística: procura sob /media/sonne/.../viralefy_* (dev) ou /opt/viralefy/* (prod).
ROOTS=(
  "${VIRALEFY_FRONT_DIR:-}"
  "${VIRALEFY_BACKOFFICE_DIR:-}"
  "/opt/viralefy/front"
  "/opt/viralefy/backoffice"
  "/media/sonne/Archives/projects/viralefy/viralefy_front"
  "/media/sonne/Archives/projects/viralefy/viralefy_backoffice"
)

audited=0
for root in "${ROOTS[@]}"; do
  [[ -z "$root" ]] && continue
  [[ ! -f "$root/package-lock.json" ]] && continue
  audited=$((audited + 1))

  # `npm audit --json` retorna métricas em metadata.vulnerabilities.
  out="$(cd "$root" && npm audit --audit-level=high --json 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    test_fail "$root: npm audit sem output"
    continue
  fi

  high="$(echo "$out" | jq -r '.metadata.vulnerabilities.high // 0' 2>/dev/null)"
  crit="$(echo "$out" | jq -r '.metadata.vulnerabilities.critical // 0' 2>/dev/null)"
  high="${high:-0}"
  crit="${crit:-0}"

  if (( high == 0 && crit == 0 )); then
    test_pass "$root: 0 high/critical"
  else
    sample="$(echo "$out" | jq -r '.vulnerabilities | to_entries[] | select(.value.severity=="high" or .value.severity=="critical") | .key' 2>/dev/null | head -5 | tr '\n' ',')"
    test_fail "$root: high=$high critical=$crit" "vulneráveis: $sample"
  fi
done

if (( audited == 0 )); then
  test_skip "nenhum package-lock.json encontrado em paths conhecidos"
fi

test_summary "security/npm-audit"
exit $TEST_EXIT_CODE
