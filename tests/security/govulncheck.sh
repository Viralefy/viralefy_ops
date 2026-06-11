#!/usr/bin/env bash
# Security · govulncheck
# Roda `govulncheck ./...` em todos os serviços Go (core, auth, payments, sender).
# Esperado: 0 vulnerabilidades efetivamente chamadas (vulns em deps não-usadas
# são ignoradas pelo próprio govulncheck).
# Falha = path vulnerável é alcançável pelo nosso código.
#
# Skip se govulncheck/go ausentes.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "Security · govulncheck"

if ! command -v go >/dev/null 2>&1; then
  test_skip "go ausente" "instale golang"
  test_summary "security/govulncheck"
  exit $TEST_EXIT_CODE
fi

# govulncheck pode estar em $PATH ou em GOBIN.
GOVC="$(command -v govulncheck || true)"
if [[ -z "$GOVC" ]] && [[ -x "$(go env GOPATH)/bin/govulncheck" ]]; then
  GOVC="$(go env GOPATH)/bin/govulncheck"
fi
if [[ -z "$GOVC" ]]; then
  test_skip "govulncheck ausente" "go install golang.org/x/vuln/cmd/govulncheck@latest"
  test_summary "security/govulncheck"
  exit $TEST_EXIT_CODE
fi

ROOTS=(
  "${VIRALEFY_CORE_DIR:-/media/sonne/Archives/projects/viralefy/viralefy_core}"
  "${VIRALEFY_AUTH_DIR:-/media/sonne/Archives/projects/viralefy/viralefy_auth}"
  "${VIRALEFY_PAYMENTS_DIR:-/media/sonne/Archives/projects/viralefy/viralefy_payments}"
  "${VIRALEFY_SENDER_DIR:-/media/sonne/Archives/projects/viralefy/viralefy_sender}"
)

audited=0
for root in "${ROOTS[@]}"; do
  if [[ ! -f "$root/go.mod" ]]; then
    test_skip "$root sem go.mod" "service não disponível"
    continue
  fi
  audited=$((audited + 1))

  out="$(cd "$root" && "$GOVC" -json ./... 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    test_fail "$root: govulncheck sem output"
    continue
  fi

  # Conta findings.osv tipo "vulnerability" com call stack não-vazia.
  called="$(echo "$out" | jq -rs '
    [ .[] | select(.finding != null)
          | select((.finding.trace // [])[0].function // null) != null
    ] | length' 2>/dev/null)"
  called="${called:-0}"

  if (( called == 0 )); then
    test_pass "$root: 0 vulns chamadas"
  else
    sample="$(echo "$out" | jq -rs '[.[] | .finding.osv // empty] | unique | join(",")' 2>/dev/null | head -c 200)"
    test_fail "$root: $called vulns chamadas" "OSVs: $sample"
  fi
done

if (( audited == 0 )); then
  test_skip "nenhum serviço Go encontrado nos paths conhecidos"
fi

test_summary "security/govulncheck"
exit $TEST_EXIT_CODE
