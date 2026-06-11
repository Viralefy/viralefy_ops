#!/usr/bin/env bash
# Security · rate-limit-login
# Hit /v1/auth/user/login com credenciais inválidas 50x em paralelo.
# Esperado: pelo menos 1 resposta com 429 Too Many Requests (rate limit ativo).
# Auth tem janela de 10/15min por IP.
# Falha = rate-limit não está ativo → vulnerável a credential stuffing.

set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$_DIR/lib.sh"

test_section "Security · rate-limit-login"

API="$(api_base)"
url="$API/v1/auth/user/login"
body='{"email":"nope-ratelimit-probe@viralefy.test","password":"x"}'

# Sanity: rota responde algum 4xx (não 5xx) com credencial inválida.
http_call POST "$url" "$body"
if [[ "$HTTP_CODE" == "000" ]]; then
  test_skip "rota /v1/auth/user/login inacessível" "connect refused"
  test_summary "security/rate-limit-login"
  exit $TEST_EXIT_CODE
fi
if [[ "$HTTP_CODE" =~ ^5 ]]; then
  test_fail "/v1/auth/user/login devolveu 5xx em login inválido" "$HTTP_BODY"
  test_summary "security/rate-limit-login"
  exit $TEST_EXIT_CODE
fi
test_pass "rota respondeu sem 5xx ($HTTP_CODE)"

# 50 requests paralelos. Coleta códigos em arquivo.
tmp="$(mktemp)"
N=50
for _ in $(seq 1 $N); do
  (
    curl -sS -o /dev/null --max-time 5 --connect-timeout 2 \
      -w '%{http_code}\n' \
      -X POST -H 'Content-Type: application/json' \
      --data-raw "$body" "$url" \
      2>/dev/null || echo 000
  ) >> "$tmp" &
done
wait

total="$(wc -l < "$tmp" | tr -d ' ')"
count_codes() { grep -cE "$1" "$tmp" 2>/dev/null | head -1 || true; }
n429="$(count_codes '^429$')"; n429="${n429:-0}"
n401="$(count_codes '^401$')"; n401="${n401:-0}"
n400="$(count_codes '^400$')"; n400="${n400:-0}"
n5xx="$(count_codes '^5[0-9][0-9]$')"; n5xx="${n5xx:-0}"
n000="$(count_codes '^000$')"; n000="${n000:-0}"

printf '  %sdistribuição: total=%d 429=%d 401=%d 400=%d 5xx=%d conn-fail=%d%s\n' \
  "${C_DIM:-}" "$total" "$n429" "$n401" "$n400" "$n5xx" "$n000" "${C_RST:-}"

if (( n5xx > 0 )); then
  test_fail "$n5xx respostas 5xx durante burst (deveria ser 4xx limpo)" "$(head -20 "$tmp")"
fi

if (( n429 > 0 )); then
  test_pass "rate-limit ativo ($n429/$N respostas 429)"
else
  test_fail "nenhum 429 em $N requests — rate-limit do login provavelmente desligado" "$(sort "$tmp" | uniq -c)"
fi

rm -f "$tmp"

test_summary "security/rate-limit-login"
exit $TEST_EXIT_CODE
