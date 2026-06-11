#!/usr/bin/env bash
# tests/lib.sh — fonte única de helpers para os scripts em tests/<mode>/.
#
# Cada script de teste segue o skeleton (§22.4 das diretrizes):
#
#   #!/usr/bin/env bash
#   set -uo pipefail
#   _DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
#   source "$_DIR/lib.sh"
#
#   test_section "<Categoria> · <Nome>"
#   API="$(api_base)"
#   assert_http_in "<descrição>" "200|401" GET "$API/v1/rota"
#   test_summary "<categoria>/<nome>"
#   exit $TEST_EXIT_CODE
#
# Helpers obrigatórios expostos:
#   test_section, test_pass, test_fail, test_skip, test_summary
#   http_call, assert_http_in, assert_http_status
#   assert_json_field, assert_header_present, assert_no_pii
#   api_base, front_base, admin_base, dispatcher_base
#
# Contadores PASS/FAIL ficam em variáveis do shell (escopo do script). O
# runner viralefy-test agrega ao ler exit code + stdout + summary line.
#
# Sem deps externas além de curl + jq + python3 (em todos hosts Debian/Ubuntu).

set -uo pipefail

# ─── Cores (só se TTY) ─────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'
  C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'
  C_DIM=$'\033[2m'
  C_BLU=$'\033[34m'
  C_BOLD=$'\033[1m'
  C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_DIM=""; C_BLU=""; C_BOLD=""; C_RST=""
fi

# ─── Bases (overridable via env) ──────────────────────────────────────
# Localhost por default (rodando direto no host de prod via /usr/local/sbin
# ou via dev box). Em CI externo / GH runner, exporte os _BASE com https://.
api_base()        { echo "${VIRALEFY_TEST_API_BASE:-http://127.0.0.1:8090}"; }
dispatcher_base() { echo "${VIRALEFY_TEST_DISPATCHER_BASE:-http://127.0.0.1:8090}"; }
front_base()      { echo "${VIRALEFY_TEST_FRONT_BASE:-http://127.0.0.1:3000}"; }
admin_base()      { echo "${VIRALEFY_TEST_ADMIN_BASE:-http://127.0.0.1:3001}"; }
core_base()       { echo "${VIRALEFY_TEST_CORE_BASE:-http://127.0.0.1:8084}"; }
auth_base()       { echo "${VIRALEFY_TEST_AUTH_BASE:-http://127.0.0.1:8083}"; }
payments_base()   { echo "${VIRALEFY_TEST_PAYMENTS_BASE:-http://127.0.0.1:8081}"; }
sender_base()     { echo "${VIRALEFY_TEST_SENDER_BASE:-http://127.0.0.1:8082}"; }

# Observability (Prometheus/Grafana/Loki) — só local por default.
prom_base()    { echo "${VIRALEFY_TEST_PROM_BASE:-http://127.0.0.1:9090}"; }
grafana_base() { echo "${VIRALEFY_TEST_GRAFANA_BASE:-http://127.0.0.1:3030}"; }
loki_base()    { echo "${VIRALEFY_TEST_LOKI_BASE:-http://127.0.0.1:3100}"; }

# ─── Contadores (por-script) ──────────────────────────────────────────
TEST_PASS=0
TEST_FAIL=0
TEST_SKIP=0
TEST_EXIT_CODE=0
TEST_SECTION=""

# HTTP_CODE e HTTP_BODY são populados por http_call.
HTTP_CODE=""
HTTP_BODY=""
HTTP_HEADERS=""

# ─── Banner / lifecycle ───────────────────────────────────────────────
test_section() {
  TEST_SECTION="${1:-?}"
  local bar
  bar="$(printf '═%.0s' $(seq 1 70))"
  printf '%s%s%s\n' "$C_BOLD" "$bar" "$C_RST"
  printf '%s  %s%s\n' "$C_BOLD" "$TEST_SECTION" "$C_RST"
  printf '%s%s%s\n' "$C_BOLD" "$bar" "$C_RST"
}

test_pass() {
  TEST_PASS=$((TEST_PASS + 1))
  printf '  %s✓%s %s\n' "$C_GRN" "$C_RST" "$1"
}

test_fail() {
  TEST_FAIL=$((TEST_FAIL + 1))
  TEST_EXIT_CODE=1
  local msg="${1:-(no message)}"
  local body="${2:-}"
  printf '  %s✗ %s%s\n' "$C_RED" "$msg" "$C_RST"
  if [[ -n "$body" ]]; then
    # Truncado a 2000 chars, indentado.
    printf '%s%s%s\n' "$C_DIM" "$(echo "${body:0:2000}" | sed 's/^/      /')" "$C_RST"
  fi
}

test_skip() {
  TEST_SKIP=$((TEST_SKIP + 1))
  local msg="${1:-(no message)}"
  local reason="${2:-}"
  printf '  %s○ %s%s%s\n' "$C_YEL" "$msg" \
    "${reason:+ (skip: $reason)}" "$C_RST"
}

# test_summary "<categoria>/<nome>"
# Imprime totals + banner gigante vermelho se houver falha. Exporta
# TEST_EXIT_CODE pra o `exit $TEST_EXIT_CODE` na última linha do script.
test_summary() {
  local label="${1:-${TEST_SECTION:-script}}"
  local total=$((TEST_PASS + TEST_FAIL + TEST_SKIP))
  printf '\n  %s──── %s ────%s\n' "$C_DIM" "$label" "$C_RST"
  printf '  pass=%s%d%s  fail=%s%d%s  skip=%s%d%s  total=%d\n' \
    "$C_GRN" "$TEST_PASS" "$C_RST" \
    "$C_RED" "$TEST_FAIL" "$C_RST" \
    "$C_YEL" "$TEST_SKIP" "$C_RST" \
    "$total"

  if (( TEST_FAIL > 0 )); then
    local bar
    bar="$(printf '█%.0s' $(seq 1 70))"
    printf '\n%s%s%s\n' "$C_RED$C_BOLD" "$bar" "$C_RST"
    printf '%s%s   FAIL   %s%s\n' "$C_RED$C_BOLD" "$(printf ' %.0s' $(seq 1 28))" "$(printf ' %.0s' $(seq 1 28))" "$C_RST"
    printf '%s%s%s\n\n' "$C_RED$C_BOLD" "$bar" "$C_RST"
    TEST_EXIT_CODE=1
  fi
}

# ─── HTTP helpers ─────────────────────────────────────────────────────
# http_call <method> <url> [body] [extra_curl_args...]
# Popula HTTP_CODE, HTTP_BODY, HTTP_HEADERS no shell do chamador.
# Usa --max-time 10. Body por --data-raw se não vazio. Headers extras
# como -H "X-Foo: bar" entram nos extra args.
http_call() {
  local method="${1:?method required}"
  local url="${2:?url required}"
  local body="${3:-}"
  shift 3 2>/dev/null || shift $(($#))

  local body_f hdr_f code
  body_f="$(mktemp)"
  hdr_f="$(mktemp)"

  local -a args=(
    -sS --max-time 10 --connect-timeout 3
    -o "$body_f" -D "$hdr_f"
    -w '%{http_code}'
    -X "$method"
  )
  if [[ -n "$body" ]]; then
    args+=(--data-raw "$body")
    # Heurística: se body começa com { ou [, manda Content-Type JSON
    # (a menos que o caller já tenha passado outro).
    local has_ct=0
    for a in "$@"; do [[ "$a" == "Content-Type:"* ]] && has_ct=1; done
    if [[ $has_ct -eq 0 ]] && [[ "${body:0:1}" == "{" || "${body:0:1}" == "[" ]]; then
      args+=(-H "Content-Type: application/json")
    fi
  fi
  args+=("$@" "$url")

  code="$(curl "${args[@]}" 2>/dev/null || echo 000)"
  # Defensive: pega só os 3 últimos chars (curl --write-out duplica em failure modes).
  code="${code: -3}"
  HTTP_CODE="$code"
  HTTP_BODY="$(cat "$body_f" 2>/dev/null || true)"
  HTTP_HEADERS="$(cat "$hdr_f" 2>/dev/null || true)"
  rm -f "$body_f" "$hdr_f"
}

# assert_http_status "<desc>" "<expected_code>" <method> <url> [body] [extra...]
assert_http_status() {
  local desc="$1" expected="$2" method="$3" url="$4"
  shift 4
  local body="${1:-}"
  [[ $# -gt 0 ]] && shift
  http_call "$method" "$url" "$body" "$@"
  if [[ "$HTTP_CODE" == "$expected" ]]; then
    test_pass "$desc → $expected"
  else
    test_fail "$desc → got $HTTP_CODE expected $expected ($method $url)" "$HTTP_BODY"
  fi
}

# assert_http_in "<desc>" "<code|code|code>" <method> <url> [body] [extra...]
assert_http_in() {
  local desc="$1" allowed="$2" method="$3" url="$4"
  shift 4
  local body="${1:-}"
  [[ $# -gt 0 ]] && shift
  http_call "$method" "$url" "$body" "$@"
  # allowed é "200|401|404"
  if [[ "|$allowed|" == *"|$HTTP_CODE|"* ]]; then
    test_pass "$desc → $HTTP_CODE ∈ {$allowed}"
  else
    test_fail "$desc → got $HTTP_CODE not in {$allowed} ($method $url)" "$HTTP_BODY"
  fi
}

# assert_json_field "<jq_query>" "<expected_value>" [<failure_msg>]
# Roda jq sobre $HTTP_BODY. Compara stdout textual com o valor esperado.
assert_json_field() {
  local query="${1:?jq query required}"
  local expected="${2:-}"
  local msg="${3:-json field $query == $expected}"
  local got
  got="$(echo "$HTTP_BODY" | jq -r "$query" 2>/dev/null || echo "__JQ_ERR__")"
  if [[ "$got" == "$expected" ]]; then
    test_pass "$msg"
  else
    test_fail "$msg (got=$got)" "$HTTP_BODY"
  fi
}

# assert_header_present "<header_name>" [<failure_msg>]
# Verifica em $HTTP_HEADERS (last response). Case-insensitive.
assert_header_present() {
  local hdr="${1:?header required}"
  local msg="${2:-header $hdr present}"
  if echo "$HTTP_HEADERS" | grep -qiE "^${hdr}:"; then
    test_pass "$msg"
  else
    test_fail "$msg" "headers=$HTTP_HEADERS"
  fi
}

# assert_header_absent "<header_name>" [<failure_msg>]
assert_header_absent() {
  local hdr="${1:?header required}"
  local msg="${2:-header $hdr absent}"
  if echo "$HTTP_HEADERS" | grep -qiE "^${hdr}:"; then
    test_fail "$msg" "headers=$HTTP_HEADERS"
  else
    test_pass "$msg"
  fi
}

# assert_no_pii "<text>" [<context>]
# Heurística regex pra detectar CPF (111.222.333-44 ou 11122233344),
# e-mail real (qualquer @ que não @viralefy.test), telefone BR.
# Test users *@viralefy.test são whitelisted.
assert_no_pii() {
  local text="${1:-}"
  local ctx="${2:-text}"
  local found=""
  # CPF formatado ou 11 dígitos contíguos
  if echo "$text" | grep -qE '\b[0-9]{3}\.[0-9]{3}\.[0-9]{3}-[0-9]{2}\b'; then
    found="CPF formatado"
  elif echo "$text" | grep -qE '\b[0-9]{11}\b' \
       && ! echo "$text" | grep -qE '"timestamp"|"ts"|"epoch"|"created_at"|"updated_at"|[0-9]{10,13}\.[0-9]'; then
    # heurística fraca: 11 dígitos isolados — pode ser CPF.
    found="possível CPF (11 dígitos contíguos)"
  fi
  # E-mails que NÃO sejam @viralefy.test
  if echo "$text" | grep -ohE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
       | grep -v '@viralefy\.test' | grep -qE '.'; then
    found="${found:+$found, }e-mail real"
  fi
  if [[ -n "$found" ]]; then
    test_fail "PII detectada em $ctx: $found" "$(echo "$text" | head -c 500)"
  else
    test_pass "sem PII em $ctx"
  fi
}

# vim: set ft=bash et sw=2:
