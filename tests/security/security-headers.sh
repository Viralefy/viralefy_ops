#!/usr/bin/env bash
# Security · security-headers
# Verifica que os headers de segurança "óbvios" estão presentes em api/www/admin.
# - Strict-Transport-Security (HSTS) com preload
# - X-Content-Type-Options: nosniff
# - Content-Security-Policy em www + admin
# - Cross-Origin-Resource-Policy
# - Referrer-Policy
# - Permissions-Policy
# - Server header NÃO exposto (era removido com `-Server` no Caddyfile)
# Esperado: cada header presente; Server ausente.
# Falha = configuração do reverse proxy regrediu.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "Security · security-headers"

API="$(api_base)"
FRONT="$(front_base)"
ADMIN="$(admin_base)"

check_target() {
  local label="$1" url="$2" want_csp="$3"
  http_call GET "$url"
  if [[ "$HTTP_CODE" == "000" ]]; then
    test_skip "$label inacessível" "connect refused"
    return
  fi

  # Headers comuns a todos os vhosts
  if echo "$HTTP_HEADERS" | grep -qiE '^Strict-Transport-Security:.*preload'; then
    test_pass "$label HSTS preload"
  else
    # Se rodando em http://127.0.0.1, Caddy normalmente não emite HSTS.
    if [[ "$url" =~ ^http:// ]]; then
      test_skip "$label HSTS (skip em http://)" "TLS off"
    else
      test_fail "$label HSTS preload ausente" "$HTTP_HEADERS"
    fi
  fi

  if echo "$HTTP_HEADERS" | grep -qiE '^X-Content-Type-Options:\s*nosniff'; then
    test_pass "$label X-Content-Type-Options nosniff"
  else
    test_fail "$label X-Content-Type-Options ausente" "$HTTP_HEADERS"
  fi

  if echo "$HTTP_HEADERS" | grep -qiE '^Referrer-Policy:'; then
    test_pass "$label Referrer-Policy"
  else
    test_fail "$label Referrer-Policy ausente" "$HTTP_HEADERS"
  fi

  if echo "$HTTP_HEADERS" | grep -qiE '^Cross-Origin-Resource-Policy:'; then
    test_pass "$label Cross-Origin-Resource-Policy"
  else
    test_fail "$label CORP ausente" "$HTTP_HEADERS"
  fi

  if echo "$HTTP_HEADERS" | grep -qiE '^Permissions-Policy:'; then
    test_pass "$label Permissions-Policy"
  else
    test_fail "$label Permissions-Policy ausente" "$HTTP_HEADERS"
  fi

  if [[ "$want_csp" == "1" ]]; then
    if echo "$HTTP_HEADERS" | grep -qiE '^Content-Security-Policy:'; then
      test_pass "$label CSP"
    else
      test_fail "$label CSP ausente" "$HTTP_HEADERS"
    fi
  fi

  # Server header não deve aparecer (foi removido com `-Server` no Caddyfile).
  if echo "$HTTP_HEADERS" | grep -qiE '^Server:\s*Caddy'; then
    test_fail "$label Server: Caddy exposto" "$HTTP_HEADERS"
  else
    test_pass "$label Server: Caddy oculto"
  fi
}

check_target "api"   "$API/healthz"   "0"
check_target "www"   "$FRONT/"        "1"
check_target "admin" "$ADMIN/"        "1"

test_summary "security/security-headers"
exit $TEST_EXIT_CODE
