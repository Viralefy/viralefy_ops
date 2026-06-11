#!/usr/bin/env bash
# Security · auth-bypass
# Tenta acessar rotas /v1/admin/* sem cookie de sessão / sem JWT admin.
# Esperado: TODAS retornam 401 (Unauthorized). 403 também aceito (auth ok,
# autorização nega) mas em "sem credencial alguma" deve ser 401.
# Falha = rota admin acessível sem auth (auth bypass crítico).

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "Security · auth-bypass"

API="$(api_base)"

# Rotas admin canônicas — cobre identidade do operador, listagens críticas e métricas.
assert_http_in "GET /v1/admin/me sem cookie"               "401" GET "$API/v1/admin/me"
assert_http_in "GET /v1/admin/orders sem cookie"           "401" GET "$API/v1/admin/orders"
assert_http_in "GET /v1/admin/users sem cookie"            "401" GET "$API/v1/admin/users"
assert_http_in "GET /v1/admin/metrics/summary sem cookie"  "401" GET "$API/v1/admin/metrics/summary"

# Defesa em profundidade: tokens claramente inválidos não devem virar 500.
assert_http_in "GET /v1/admin/me com Bearer lixo" "401" GET "$API/v1/admin/me" \
  "" -H "Authorization: Bearer not-a-real-token"

assert_http_in "GET /v1/admin/me com Cookie lixo" "401" GET "$API/v1/admin/me" \
  "" -H "Cookie: session=deadbeef"

test_summary "security/auth-bypass"
exit $TEST_EXIT_CODE
