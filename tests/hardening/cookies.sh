#!/usr/bin/env bash
# Hardening · cookies / cookie-attributes
# Verifica que cookies emitidos pelo backend trazem flags de segurança:
#  - HttpOnly  (impede leitura via document.cookie)
#  - Secure    (só transmite em HTTPS)
#  - SameSite=Lax|Strict (mitiga CSRF cross-site)
#
# Cookies relevantes: session, refresh_token, gdpr_consent.
# Esperado: cada Set-Cookie em login OK tem todas as 3 flags.
# Falha = sessão exfiltrável via XSS ou enviada plaintext.
#
# Em http://127.0.0.1 (dev), Secure não pode ser exigido — Caddy/proxy só
# emite Secure se request entrou via TLS. Skip Secure nesse caso.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "Hardening · cookies"

API="$(api_base)"
LOGIN_PATH="${VIRALEFY_TEST_LOGIN_PATH:-/v1/auth/user/login}"

is_https=0
[[ "$API" =~ ^https:// ]] && is_https=1

# Login real exige seed. Usamos credenciais notoriamente inválidas; o backend
# pode (raramente) emitir cookies mesmo em 401 (ex.: gdpr_consent / csrf
# token). Se não houver Set-Cookie em login fail, tentamos a homepage.
http_call POST "$API$LOGIN_PATH" \
  '{"email":"cookie-probe@viralefy.test","password":"x"}'

cookies="$(echo "$HTTP_HEADERS" | grep -i '^Set-Cookie:')"

if [[ -z "$cookies" ]]; then
  # Tenta endpoint root pra captar gdpr_consent / csrf.
  http_call GET "$(front_base)/"
  cookies="$(echo "$HTTP_HEADERS" | grep -i '^Set-Cookie:')"
fi

if [[ -z "$cookies" ]]; then
  test_skip "nenhum Set-Cookie capturado" "endpoints não emitem cookies sem autenticação real"
  test_summary "hardening/cookies"
  exit $TEST_EXIT_CODE
fi

check_cookie() {
  local line="$1"
  local name
  name="$(echo "$line" | sed -E 's/^Set-Cookie:\s*([^=]+)=.*/\1/I' | tr -d ' \r')"

  # Cookies de sessão (case-insensitive match).
  case "${name,,}" in
    session|refresh_token|access_token|csrf_token|gdpr_consent|auth)
      :
      ;;
    *)
      printf '  %sinfo: cookie %s não auditado%s\n' "${C_DIM:-}" "$name" "${C_RST:-}"
      return
      ;;
  esac

  if echo "$line" | grep -qi 'HttpOnly'; then
    # gdpr_consent geralmente é lido pelo JS — não exige HttpOnly.
    if [[ "${name,,}" != "gdpr_consent" ]]; then
      test_pass "cookie $name: HttpOnly"
    else
      test_pass "cookie $name: (HttpOnly opcional pra consent)"
    fi
  else
    if [[ "${name,,}" == "gdpr_consent" ]]; then
      test_pass "cookie $name: HttpOnly não exigido (lido por JS)"
    else
      test_fail "cookie $name SEM HttpOnly" "$line"
    fi
  fi

  if (( is_https )); then
    if echo "$line" | grep -qi 'Secure'; then
      test_pass "cookie $name: Secure"
    else
      test_fail "cookie $name SEM Secure (em HTTPS)" "$line"
    fi
  else
    test_skip "cookie $name: Secure (skip em http://)"
  fi

  if echo "$line" | grep -qiE 'SameSite=(Lax|Strict)'; then
    test_pass "cookie $name: SameSite=Lax/Strict"
  else
    test_fail "cookie $name SEM SameSite=Lax/Strict" "$line"
  fi
}

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  check_cookie "$line"
done <<< "$cookies"

test_summary "hardening/cookies"
exit $TEST_EXIT_CODE
