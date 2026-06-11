#!/usr/bin/env bash
# Hardening · default-creds
# Tenta login com credenciais default famosas: admin/admin, root/root, etc.
# Esperado: TODOS 401 (ou 400 / 404). Nenhum 200/204 com cookie.
# Falha = senha default ativa → comprometimento trivial.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "Hardening · default-creds"

API="$(api_base)"

# Pares de path × (user, pass). Admin path = /v1/auth/login; user path = /v1/auth/user/login.
PATHS=(
  "/v1/auth/login"
  "/v1/auth/user/login"
)

declare -a CREDS=(
  "admin@viralefy.com|admin"
  "admin@admin.com|admin"
  "root@root.com|root"
  "test@test.com|test"
  "user@user.com|user"
  "administrator@viralefy.com|password"
  "admin@viralefy.com|123456"
  "admin@viralefy.com|changeme"
)

for path in "${PATHS[@]}"; do
  for entry in "${CREDS[@]}"; do
    email="${entry%|*}"
    pw="${entry#*|}"
    body="$(printf '{"email":"%s","password":"%s"}' "$email" "$pw")"

    http_call POST "$API$path" "$body"

    case "$HTTP_CODE" in
      401|400|403|404|422|429)
        test_pass "$path × $email/<default> → $HTTP_CODE"
        ;;
      200|204)
        # Suspeito: confere se body contém token ou cookie.
        if echo "$HTTP_HEADERS" | grep -qi '^Set-Cookie:.*session' \
           || echo "$HTTP_BODY" | grep -qiE 'access_token|token|jwt'; then
          test_fail "$path × $email/<default> ACEITOU login" "$(echo "$HTTP_BODY" | head -c 200)"
        else
          test_pass "$path × $email/<default> → 200 sem token (provavelmente erro)"
        fi
        ;;
      000)
        test_skip "$path × $email connect fail"
        ;;
      *)
        if [[ "$HTTP_CODE" =~ ^4 ]]; then
          test_pass "$path × $email/<default> → $HTTP_CODE"
        else
          test_fail "$path × $email/<default> status inesperado $HTTP_CODE" "$(echo "$HTTP_BODY" | head -c 200)"
        fi
        ;;
    esac
  done
done

test_summary "hardening/default-creds"
exit $TEST_EXIT_CODE
