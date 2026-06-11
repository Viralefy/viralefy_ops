#!/usr/bin/env bash
# Security · cargo-audit
# Roda `cargo audit` no dispatcher Rust (viralefy_api_rust).
# Esperado: 0 vulnerabilidades ativas.
# Exceção documentada: rsa@0.9.10 (RUSTSEC-2023-0071, Marvin Attack) — risk
# accepted enquanto não há upgrade upstream em sqlx-mysql. Cargo audit aceita
# `[advisories.ignore]` no .cargo/audit.toml, então o status "active" já deve
# excluí-lo.
# Falha = nova vulnerabilidade não documentada.
#
# Skip se cargo/cargo-audit ausente.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "Security · cargo-audit"

if ! command -v cargo >/dev/null 2>&1; then
  test_skip "cargo ausente" "instale rustup"
  test_summary "security/cargo-audit"
  exit $TEST_EXIT_CODE
fi

if ! cargo audit --version >/dev/null 2>&1; then
  test_skip "cargo-audit ausente" "cargo install cargo-audit"
  test_summary "security/cargo-audit"
  exit $TEST_EXIT_CODE
fi

ROOTS=(
  "${VIRALEFY_RUST_DIR:-/media/sonne/Archives/projects/viralefy/viralefy_api_rust}"
)

audited=0
for root in "${ROOTS[@]}"; do
  if [[ ! -f "$root/Cargo.toml" ]]; then
    test_skip "$root sem Cargo.toml"
    continue
  fi
  audited=$((audited + 1))

  out="$(cd "$root" && cargo audit --json 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    test_fail "$root: cargo audit sem output"
    continue
  fi

  # vulnerabilities.count após honrar ignores do audit.toml.
  count="$(echo "$out" | jq -r '.vulnerabilities.count // 0' 2>/dev/null)"
  count="${count:-0}"

  # Lista risk-accepted documentada. Cada RUSTSEC aqui DEVE ter justificativa
  # em viralefy_archive/PENTEST-BASELINE-*.md ou COMPLIANCE.md.
  # RUSTSEC-2023-0071: Marvin Attack em rsa@0.9.x — sqlx-mysql não tem upgrade
  #                    upstream. Não usamos MySQL em prod (Postgres only), mas
  #                    a feature ainda compila o crate. Risk-accepted.
  RISK_ACCEPTED=(
    "RUSTSEC-2023-0071"
  )

  active="$(echo "$out" | jq -r '.vulnerabilities.list[]?.advisory.id' 2>/dev/null)"
  unexpected=""
  while IFS= read -r adv; do
    [[ -z "$adv" ]] && continue
    accepted=0
    for a in "${RISK_ACCEPTED[@]}"; do
      [[ "$adv" == "$a" ]] && accepted=1 && break
    done
    if (( accepted == 0 )); then
      unexpected="${unexpected:+$unexpected,}$adv"
    fi
  done <<< "$active"

  if [[ -z "$unexpected" ]]; then
    if (( count > 0 )); then
      test_pass "$root: $count vuln(s) ativas, todas risk-accepted (${RISK_ACCEPTED[*]})"
    else
      test_pass "$root: 0 vulns ativas"
    fi
  else
    test_fail "$root: vuln(s) NÃO documentadas" "RUSTSEC: $unexpected"
  fi

  # Warnings (yanked, unmaintained) ficam só como info no output do test.
  warn="$(echo "$out" | jq -r '[.warnings | to_entries[] | .value | length] | add // 0' 2>/dev/null)"
  warn="${warn:-0}"
  printf '  %sinfo: %d warnings (yanked/unmaintained — não bloqueia)%s\n' \
    "${C_DIM:-}" "$warn" "${C_RST:-}"
done

if (( audited == 0 )); then
  test_skip "nenhum crate Rust encontrado"
fi

test_summary "security/cargo-audit"
exit $TEST_EXIT_CODE
