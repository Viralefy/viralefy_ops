#!/usr/bin/env bash
# smoke · tls-grade
# TLS 1.2/1.3 ok, TLS 1.0/1.1 rejeitados, HSTS no header com preload.
# Skip silencioso quando rodando contra http:// local (sem TLS).

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "smoke · tls-grade"

API="$(api_base)"

# Só roda se API for https://
if [[ "$API" != https://* ]]; then
  test_skip "tls-grade" "API base não é https ($API) — rodando local sem TLS"
  test_summary "smoke/tls-grade"
  exit $TEST_EXIT_CODE
fi

HOST="${API#https://}"
HOST="${HOST%%/*}"
HOST="${HOST%%:*}"

if ! command -v openssl >/dev/null 2>&1; then
  test_skip "openssl ausente" "instalar openssl pra cobrir TLS handshake"
else
  # TLS 1.2 deve aceitar
  if echo | timeout 5 openssl s_client -connect "$HOST:443" -tls1_2 -servername "$HOST" 2>&1 \
       | grep -q 'Verify return code: 0'; then
    test_pass "TLS 1.2 ok em $HOST"
  else
    test_fail "TLS 1.2 falhou em $HOST" ""
  fi

  # TLS 1.3 deve aceitar (Caddy default)
  if echo | timeout 5 openssl s_client -connect "$HOST:443" -tls1_3 -servername "$HOST" 2>&1 \
       | grep -q 'Verify return code: 0'; then
    test_pass "TLS 1.3 ok em $HOST"
  else
    test_skip "TLS 1.3 não pode ser confirmado" "openssl pode não suportar -tls1_3"
  fi

  # TLS 1.0 deve falhar
  if echo | timeout 5 openssl s_client -connect "$HOST:443" -tls1 -servername "$HOST" 2>&1 \
       | grep -qE 'Verify return code: 0|TLSv1\b'; then
    test_fail "TLS 1.0 aceito em $HOST (deveria estar desabilitado)" ""
  else
    test_pass "TLS 1.0 rejeitado em $HOST"
  fi
fi

# HSTS header
http_call GET "$API/health"
if echo "$HTTP_HEADERS" | grep -qiE '^strict-transport-security:'; then
  test_pass "Strict-Transport-Security presente"
  if echo "$HTTP_HEADERS" | grep -qiE '^strict-transport-security:.*preload'; then
    test_pass "HSTS preload directive presente"
  else
    test_skip "HSTS sem 'preload'" "considere submeter ao hstspreload.org"
  fi
else
  test_fail "Strict-Transport-Security ausente" "$HTTP_HEADERS"
fi

test_summary "smoke/tls-grade"
exit $TEST_EXIT_CODE
