#!/usr/bin/env bash
# Hardening · caa-records
# Verifica que a zona tem registros CAA (RFC 8659) restringindo quais CAs
# podem emitir cert pra viralefy.com. Sem CAA, qualquer CA do mundo pode
# emitir cert — risco de mis-issuance.
# Esperado:
#  - Pelo menos um `issue "letsencrypt.org"` (Caddy usa LE por default).
#  - `iodef mailto:` recomendado (canal pra notificar emissão suspeita).
# Falha = qualquer CA pode emitir cert pro nosso domínio.
# Skip se dig ausente.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "Hardening · caa-records"

if ! command -v dig >/dev/null 2>&1; then
  test_skip "dig ausente"
  test_summary "hardening/caa-records"
  exit $TEST_EXIT_CODE
fi

ZONE="${VIRALEFY_TEST_ZONE:-viralefy.com}"
caa="$(dig +short "$ZONE" CAA 2>/dev/null)"

if [[ -z "$caa" ]]; then
  test_fail "$ZONE: nenhum CAA publicado" "qualquer CA pode emitir"
  test_summary "hardening/caa-records"
  exit $TEST_EXIT_CODE
fi

printf '  %sCAA records:%s\n' "${C_DIM:-}" "${C_RST:-}"
echo "$caa" | sed 's/^/    /'

if echo "$caa" | grep -qiE 'issue\s+"letsencrypt\.org"'; then
  test_pass "$ZONE: issue \"letsencrypt.org\" presente"
else
  test_fail "$ZONE: sem issue \"letsencrypt.org\"" "$caa"
fi

# iodef é SHOULD; só marca como skip se ausente (informativo).
if echo "$caa" | grep -qiE 'iodef\s+"(mailto:|https?://)'; then
  test_pass "$ZONE: iodef configurado (canal de notificação)"
else
  test_skip "$ZONE: iodef ausente (recomendado mas não obrigatório)"
fi

test_summary "hardening/caa-records"
exit $TEST_EXIT_CODE
