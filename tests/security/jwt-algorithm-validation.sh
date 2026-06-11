#!/usr/bin/env bash
# Security · jwt-algorithm-validation
# Verifica que o middleware de auth aceita só JWT com alg=RS256.
# Casos:
#  - alg=none (sem assinatura): 401.
#  - alg=HS256 com chave inventada: 401 (não pode "downgrade" pra HMAC com a public key RSA).
#  - JWT inteiro sintaticamente quebrado: 401.
#  - Bearer ausente em rota protegida: 401.
# Esperado: TODOS 401. Nada de 500 (parser não deve crashar com payload exótico).
# Falha = JWT confusion / algorithm confusion crítico (CVE class).

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "Security · jwt-algorithm-validation"

API="$(api_base)"
PROTECTED="$API/v1/admin/me"

# base64url sem padding.
b64url() {
  # Sem newline, sem padding `=`, com substituições URL-safe.
  printf '%s' "$1" | base64 -w0 2>/dev/null | tr '+/' '-_' | tr -d '='
}

now="$(date -u +%s)"
exp=$((now + 3600))

# 1) alg=none — sem assinatura.
hdr_none='{"alg":"none","typ":"JWT"}'
payload="{\"sub\":\"attacker\",\"role\":\"superadmin\",\"exp\":$exp}"
tok_none="$(b64url "$hdr_none").$(b64url "$payload")."
assert_http_in "JWT alg=none rejeitado" "401" \
  GET "$PROTECTED" "" -H "Authorization: Bearer $tok_none"

# 2) alg=HS256 com sig inventada (algorithm confusion attempt).
hdr_hs='{"alg":"HS256","typ":"JWT"}'
fake_sig="$(b64url 'fake-hs256-signature-bytes')"
tok_hs="$(b64url "$hdr_hs").$(b64url "$payload").$fake_sig"
assert_http_in "JWT alg=HS256 rejeitado" "401" \
  GET "$PROTECTED" "" -H "Authorization: Bearer $tok_hs"

# 3) JWT lixo (não-base64).
assert_http_in "JWT sintaticamente quebrado rejeitado" "401" \
  GET "$PROTECTED" "" -H "Authorization: Bearer not.a.jwt"

# 4) Bearer ausente — deve ser 401 (não 500, não 200).
assert_http_in "sem Bearer em rota protegida" "401" \
  GET "$PROTECTED"

# 5) Bearer com whitespace estranho.
assert_http_in "Bearer com prefix vazio" "401" \
  GET "$PROTECTED" "" -H "Authorization: Bearer "

test_summary "security/jwt-algorithm-validation"
exit $TEST_EXIT_CODE
