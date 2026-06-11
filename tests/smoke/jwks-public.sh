#!/usr/bin/env bash
# smoke · jwks-public
# /.well-known/jwks.json deve estar acessível sem auth e retornar JSON
# válido com pelo menos 1 chave. Cobre auth (RS256 JWT validation).

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "smoke · jwks-public"

API="$(api_base)"
AUTH="$(auth_base)"

# Tenta primeiro no dispatcher (path canônico em prod), fallback no auth direto.
candidates=(
  "$API/.well-known/jwks.json"
  "$AUTH/.well-known/jwks.json"
)

OK=0
for url in "${candidates[@]}"; do
  http_call GET "$url"
  if [[ "$HTTP_CODE" == "200" ]]; then
    # Valida shape JWKS: {"keys": [...]} com pelo menos 1 entrada
    n="$(echo "$HTTP_BODY" | jq -r '.keys | length' 2>/dev/null || echo -1)"
    if [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )); then
      test_pass "$url → 200 + .keys[$n]"
      # Cada key precisa de kty (chave de tipo). RS256 idealmente.
      kty="$(echo "$HTTP_BODY" | jq -r '.keys[0].kty // ""' 2>/dev/null)"
      if [[ -n "$kty" && "$kty" != "null" ]]; then
        test_pass "primeira key tem kty=$kty"
      else
        test_fail "primeira key sem 'kty'" "$HTTP_BODY"
      fi
      OK=1
      break
    else
      test_fail "$url → 200 mas .keys vazio/ausente" "$HTTP_BODY"
      OK=1
      break
    fi
  fi
done

if [[ $OK -eq 0 ]]; then
  test_fail "JWKS endpoint não disponível em nenhum candidato" "tentativas: ${candidates[*]}"
fi

test_summary "smoke/jwks-public"
exit $TEST_EXIT_CODE
