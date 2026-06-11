#!/usr/bin/env bash
# Hardening · dnssec
# Verifica se a zona viralefy.com tem DNSSEC ativo (RRSIG retornado).
# Esperado: dig +dnssec retorna registro RRSIG na resposta autoritativa.
# Falha = zona DNS pode ser spoofed; bloqueia produção idealmente.
# Skip se dig ausente ou DNS resolver não suporta +dnssec.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "Hardening · dnssec"

if ! command -v dig >/dev/null 2>&1; then
  test_skip "dig ausente" "instale dnsutils/bind-utils"
  test_summary "hardening/dnssec"
  exit $TEST_EXIT_CODE
fi

ZONE="${VIRALEFY_TEST_ZONE:-viralefy.com}"

# DNSKEY: prova que zona é assinada.
out_dnskey="$(dig +dnssec +short "$ZONE" DNSKEY 2>/dev/null || true)"
out_rrsig="$(dig +dnssec "$ZONE" 2>/dev/null | grep -c '^[^;].*RRSIG' 2>/dev/null | head -1)"
out_rrsig="${out_rrsig:-0}"
ad_flag="$(dig +dnssec "$ZONE" 2>/dev/null | grep -c '; flags:.* ad' 2>/dev/null | head -1)"
ad_flag="${ad_flag:-0}"

if [[ -z "$out_dnskey" ]]; then
  test_fail "$ZONE: nenhum DNSKEY publicado (DNSSEC inativo)" "dig +short $ZONE DNSKEY: vazio"
else
  test_pass "$ZONE: DNSKEY publicado"
fi

if (( out_rrsig > 0 )); then
  test_pass "$ZONE: RRSIG na resposta ($out_rrsig registro(s))"
else
  test_fail "$ZONE: nenhum RRSIG" "registrar pode não assinar a zona"
fi

if (( ad_flag > 0 )); then
  test_pass "$ZONE: resolver validou (flag ad)"
else
  # Pode ser que o resolver local não valide — não é falha do dono da zona.
  test_skip "$ZONE: resolver não setou flag ad" "resolver local sem validação"
fi

test_summary "hardening/dnssec"
exit $TEST_EXIT_CODE
