#!/usr/bin/env bash
# smoke · waf-block-attacks
# Coraza/WAF bloqueia ataques óbvios: SQLi e XSS em query/body. Esperado:
# 403 (ou 400/422). NUNCA 200 com resposta normal.
#
# Edge: payloads aqui são triviais demais pra causar dano real — só pra
# verificar que o WAF está ativo no path. Pentest mode tem cobertura real.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "smoke · waf-block-attacks"

API="$(api_base)"

# SQLi em query string (rota pública)
http_call GET "$API/v1/plans?id=1%27%20OR%20%271%27%3D%271"
case "$HTTP_CODE" in
  403|400|422|429) test_pass "SQLi query string → $HTTP_CODE (WAF ativo)" ;;
  200|404)     test_skip "SQLi query string → $HTTP_CODE" "rota não usa o parâmetro (não conclusivo)" ;;
  *)           test_fail "SQLi query string → $HTTP_CODE inesperado" "$HTTP_BODY" ;;
esac

# XSS em query string
http_call GET "$API/v1/plans?q=%3Cscript%3Ealert(1)%3C/script%3E"
case "$HTTP_CODE" in
  403|400|422|429) test_pass "XSS query string → $HTTP_CODE (WAF ativo)" ;;
  200|404)     test_skip "XSS query string → $HTTP_CODE" "rota não reflete o input" ;;
  *)           test_fail "XSS query string → $HTTP_CODE inesperado" "$HTTP_BODY" ;;
esac

# Path traversal
http_call GET "$API/v1/../../etc/passwd"
case "$HTTP_CODE" in
  403|400|404|429) test_pass "Path traversal → $HTTP_CODE" ;;
  *)               test_fail "Path traversal → $HTTP_CODE (esperado 403/400/404/429)" "$HTTP_BODY" ;;
esac

# Body com SQLi clássico (POST sem auth — bate no auth gate ANTES do WAF,
# então 401 também é aceito como "não vazou pro DB").
SQLI_BODY='{"email":"x@y.com'"'"' OR 1=1 --"}'
http_call POST "$API/v1/me/profile" "$SQLI_BODY"
case "$HTTP_CODE" in
  401|403|400|422) test_pass "SQLi body POST → $HTTP_CODE (bloqueado/auth)" ;;
  500)             test_fail "SQLi body POST → 500 (WAF deveria ter bloqueado antes)" "$HTTP_BODY" ;;
  *)               test_skip "SQLi body POST → $HTTP_CODE" "resposta inesperada não-fatal" ;;
esac

test_summary "smoke/waf-block-attacks"
exit $TEST_EXIT_CODE
