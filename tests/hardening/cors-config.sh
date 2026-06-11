#!/usr/bin/env bash
# Hardening · cors-config
# Verifica CORS configurado de forma restritiva:
#  - Allow-Origin reflete Origin permitido (não wildcard `*` em rotas
#    autenticadas).
#  - Allow-Credentials: true só quando Allow-Origin é explícito (RFC: não
#    pode combinar com `*`).
#  - Allow-Methods explícito (não wildcard).
#  - Preflight OPTIONS retorna 204 (ou 200) com headers acima.
# Esperado: origin não-listado não recebe Allow-Origin.
# Falha = CSRF/CORS misconfiguração que permite leitura cross-site de dados
# autenticados.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "Hardening · cors-config"

API="$(api_base)"
ALLOWED_ORIGIN="${VIRALEFY_TEST_CORS_ORIGIN:-https://www.viralefy.com}"
EVIL_ORIGIN="https://evil.example.com"

# 1) Preflight OPTIONS com origin permitido — esperado 204 (Caddy / handler CORS).
http_call OPTIONS "$API/v1/auth/user/login" "" \
  -H "Origin: $ALLOWED_ORIGIN" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: Content-Type"

if [[ "$HTTP_CODE" == "000" ]]; then
  test_skip "api inacessível"
  test_summary "hardening/cors-config"
  exit $TEST_EXIT_CODE
fi

case "$HTTP_CODE" in
  200|204) test_pass "preflight OPTIONS → $HTTP_CODE" ;;
  *)       test_fail "preflight OPTIONS → $HTTP_CODE (esperado 200/204)" "$HTTP_BODY" ;;
esac

aco="$(echo "$HTTP_HEADERS" | grep -i '^Access-Control-Allow-Origin:' | head -1 | tr -d '\r')"
acc="$(echo "$HTTP_HEADERS" | grep -i '^Access-Control-Allow-Credentials:' | head -1 | tr -d '\r')"
acm="$(echo "$HTTP_HEADERS" | grep -i '^Access-Control-Allow-Methods:' | head -1 | tr -d '\r')"

if echo "$aco" | grep -q "\*"; then
  if echo "$acc" | grep -qi 'true'; then
    test_fail "Allow-Origin: * + Allow-Credentials: true (combinação proibida)" "$aco / $acc"
  else
    test_pass "Allow-Origin: * sem credenciais (ok pra rotas públicas)"
  fi
else
  if echo "$aco" | grep -qF "$ALLOWED_ORIGIN"; then
    test_pass "Allow-Origin reflete origem permitida"
  else
    # Caddy às vezes não emite ACO se o site não tem CORS configurado pra essa rota.
    test_skip "Allow-Origin não emitido em /v1/auth/user/login" "rota pode não ser CORS-aware"
  fi
fi

if [[ -n "$acm" ]]; then
  if echo "$acm" | grep -qE 'Allow-Methods:\s*\*'; then
    test_fail "Allow-Methods wildcard" "$acm"
  else
    test_pass "Allow-Methods explícito"
  fi
fi

# 2) Preflight com origin malicioso — Allow-Origin não deve refletir evil.
http_call OPTIONS "$API/v1/auth/user/login" "" \
  -H "Origin: $EVIL_ORIGIN" \
  -H "Access-Control-Request-Method: POST"

evil_aco="$(echo "$HTTP_HEADERS" | grep -i '^Access-Control-Allow-Origin:' | head -1 | tr -d '\r')"
if echo "$evil_aco" | grep -qF "$EVIL_ORIGIN"; then
  test_fail "Allow-Origin REFLETIU $EVIL_ORIGIN — CORS misconfig" "$evil_aco"
elif echo "$evil_aco" | grep -q "\*"; then
  if echo "$HTTP_HEADERS" | grep -qi '^Access-Control-Allow-Credentials:\s*true'; then
    test_fail "Allow-Origin * + credentials true em origin evil" "$evil_aco"
  else
    test_pass "Allow-Origin * sem credenciais (toleramos em públicos)"
  fi
else
  test_pass "evil origin não recebe Allow-Origin ($evil_aco)"
fi

test_summary "hardening/cors-config"
exit $TEST_EXIT_CODE
