#!/usr/bin/env bash
# smoke · auth-gates
# Rotas autenticadas SEM Bearer token retornam 401 (não 200, não 500).
# Cobre regressão clássica de "abriu a porta sem perceber".

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "smoke · auth-gates"

API="$(api_base)"

# /v1/me/* — escopo do user logado
assert_http_status "/v1/me/2fa/status sem Bearer"   401 POST "$API/v1/me/2fa/status"
assert_http_status "/v1/me/profile sem Bearer"      401 GET  "$API/v1/me/profile"
assert_http_status "/v1/me/orders sem Bearer"       401 GET  "$API/v1/me/orders"

# /v1/admin/* — escopo backoffice
# 401 (sem token) é o esperado. Alguns dispatchers retornam 403 (token
# ausente == proibido) — aceitamos qualquer 4xx auth.
assert_http_in "/v1/admin/users sem Bearer"  "401|403" GET "$API/v1/admin/users"
assert_http_in "/v1/admin/orders sem Bearer" "401|403" GET "$API/v1/admin/orders"

test_summary "smoke/auth-gates"
exit $TEST_EXIT_CODE
