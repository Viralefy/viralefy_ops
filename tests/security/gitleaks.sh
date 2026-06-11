#!/usr/bin/env bash
# Security · gitleaks
# Scaneia os últimos N commits dos repositórios viralefy_* procurando segredos
# vazados (chaves AWS, tokens GitHub, JWTs, etc.).
# Esperado: 0 findings (whitelist em .gitleaksignore se for FP documentado).
# Falha = credencial vazada em commit recente.
#
# Skip se gitleaks ausente.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "Security · gitleaks"

if ! command -v gitleaks >/dev/null 2>&1; then
  test_skip "gitleaks ausente" "https://github.com/gitleaks/gitleaks"
  test_summary "security/gitleaks"
  exit $TEST_EXIT_CODE
fi

DEPTH="${VIRALEFY_GITLEAKS_DEPTH:-10}"
WORKSPACE_ROOT="${VIRALEFY_WORKSPACE_ROOT:-/media/sonne/Archives/projects/viralefy}"

mapfile -t REPOS < <(find "$WORKSPACE_ROOT" -maxdepth 2 -name '.git' -type d 2>/dev/null \
  | sed 's:/.git$::' | sort)

if (( ${#REPOS[@]} == 0 )); then
  test_skip "nenhum repo .git encontrado em $WORKSPACE_ROOT"
  test_summary "security/gitleaks"
  exit $TEST_EXIT_CODE
fi

for repo in "${REPOS[@]}"; do
  name="$(basename "$repo")"
  log_opts=(--log-opts="-n $DEPTH")
  report="$(mktemp)"

  if gitleaks detect --no-banner --redact \
       --source "$repo" \
       --report-format json \
       --report-path "$report" \
       "${log_opts[@]}" \
       >/dev/null 2>&1; then
    findings=0
  else
    findings="$(jq 'length' "$report" 2>/dev/null || echo 0)"
    findings="${findings:-0}"
  fi

  if (( findings == 0 )); then
    test_pass "$name: 0 findings em últimos $DEPTH commits"
  else
    rules="$(jq -r '[.[].RuleID] | unique | join(",")' "$report" 2>/dev/null)"
    test_fail "$name: $findings finding(s) em últimos $DEPTH commits" "rules=$rules"
  fi
  rm -f "$report"
done

test_summary "security/gitleaks"
exit $TEST_EXIT_CODE
