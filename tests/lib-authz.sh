#!/usr/bin/env bash
# tests/lib-authz.sh — helpers extras pros scripts em tests/authz/.
#
# Estende lib.sh com:
#   - constantes das personas (IDs, e-mails, senhas SimTest!)
#   - mint_admin_token <role> [jti_out_var] [ttl_seconds]
#   - mint_user_token  <user_id> [jti_out_var] [ttl_seconds]
#   - psql_q <sql>  → roda como root contra Postgres local
#   - login_user_real <email> <password>  → POST /v1/auth/user/login,
#     exporta USER_TOKEN (fallback pra SQL-mint se 2FA bloqueia)
#
# Esses scripts dependem de:
#   - python3 + módulo `jwt` (pip install pyjwt) NO HOST onde rodam — o
#     installer já garante via 50-build / requirements de prod.
#   - /etc/viralefy/jwt-rs256.pem legível pelo runner (root em prod,
#     ou via VIRALEFY_JWT_KEY_PATH override em dev box).
#   - psql + PGPASSWORD via env VIRALEFY_DB_URL ou
#     PGHOST/PGUSER/PGPASSWORD/PGDATABASE.
#
# Se chave RSA ou psql ausentes, o script chamador deve `test_skip` cedo.

set -uo pipefail

# ─── Personas (espelha tests/seeds/*.sql) ────────────────────────────────
AUTHZ_SUPERADMIN_ID="aaaaaaaa-0000-4000-8000-000000000001"
AUTHZ_SUPERADMIN_EMAIL="superadmin@viralefy.test"
AUTHZ_SUPERADMIN_PASSWORD="SimTest!Super123"

AUTHZ_MANAGER_ID="aaaaaaaa-0000-4000-8000-000000000002"
AUTHZ_MANAGER_EMAIL="manager@viralefy.test"
AUTHZ_MANAGER_PASSWORD="SimTest!Manager123"

AUTHZ_VIEWER_ID="aaaaaaaa-0000-4000-8000-000000000003"
AUTHZ_VIEWER_EMAIL="viewer@viralefy.test"
AUTHZ_VIEWER_PASSWORD="SimTest!Viewer123"

AUTHZ_USER_A_ID="bbbbbbbb-0000-4000-8000-00000000000a"
AUTHZ_USER_A_EMAIL="user-a@viralefy.test"
AUTHZ_USER_B_ID="bbbbbbbb-0000-4000-8000-00000000000b"
AUTHZ_USER_B_EMAIL="user-b@viralefy.test"
AUTHZ_USER_C_ID="bbbbbbbb-0000-4000-8000-00000000000c"
AUTHZ_USER_C_EMAIL="user-c@viralefy.test"
AUTHZ_USER_PASSWORD="SimTest!User123"

AUTHZ_ORDER_A_PAID_1="dddddddd-0000-4000-8000-00000000a001"
AUTHZ_ORDER_A_PAID_2="dddddddd-0000-4000-8000-00000000a002"
AUTHZ_ORDER_B_PENDING="dddddddd-0000-4000-8000-00000000b001"
AUTHZ_PROFILE_A="cccccccc-0000-4000-8000-00000000000a"
AUTHZ_PROFILE_B="cccccccc-0000-4000-8000-00000000000b"

# ─── Config ──────────────────────────────────────────────────────────────
authz_key_path() {
  echo "${VIRALEFY_JWT_KEY_PATH:-/etc/viralefy/jwt-rs256.pem}"
}

authz_kid() {
  # Default = mesmo `kid` usado por viralefy_archive/scripts/smoke_admin.py.
  # Override via VIRALEFY_JWT_KID se rotacionado.
  echo "${VIRALEFY_JWT_KID:-vfCOltLYjII}"
}

# ─── psql ────────────────────────────────────────────────────────────────
# psql_q "<sql>" → stdout do resultado (-Atc).
# Usa VIRALEFY_DB_URL se setado; caso contrário PGHOST/PGUSER/PGPASSWORD/PGDATABASE.
psql_q() {
  local sql="${1:?sql required}"
  if [[ -n "${VIRALEFY_DB_URL:-}" ]]; then
    psql "$VIRALEFY_DB_URL" -Atc "$sql" 2>/dev/null
  else
    PGPASSWORD="${PGPASSWORD:-}" psql \
      -h "${PGHOST:-localhost}" \
      -p "${PGPORT:-5432}" \
      -U "${PGUSER:-viralefy}" \
      -d "${PGDATABASE:-viralefy}" \
      -Atc "$sql" 2>/dev/null
  fi
}

# authz_check_prereqs — chama no início do script. Faz test_skip + exit 0
# se algo crítico falta (ambiente dev sem chave / sem psql).
authz_check_prereqs() {
  local missing=""
  if ! command -v python3 >/dev/null 2>&1; then
    missing+=" python3"
  fi
  if ! python3 -c "import jwt" 2>/dev/null; then
    missing+=" pyjwt"
  fi
  if ! command -v psql >/dev/null 2>&1; then
    missing+=" psql"
  fi
  local key
  key="$(authz_key_path)"
  if [[ ! -r "$key" ]]; then
    missing+=" jwt-key($key)"
  fi
  if [[ -n "$missing" ]]; then
    test_skip "pré-requisitos ausentes:$missing" \
      "rode em prod ou exporte VIRALEFY_JWT_KEY_PATH/PG* pra ambiente dev"
    test_summary "${TEST_SECTION:-authz/?}"
    exit 0
  fi
}

# ─── JWT mint ────────────────────────────────────────────────────────────
# mint_admin_token <role> [ttl_seconds]
# Stdout: "<token>\t<jti>" — caller separa com cut/IFS.
#   Exemplo:
#     read TOK JTI < <(mint_admin_token superadmin)
#     OR
#     OUT=$(mint_admin_token superadmin); TOK=${OUT%%$'\t'*}; JTI=${OUT##*$'\t'}
#
# Mudamos do padrão "printf -v" pra retorno via stdout porque o caller
# costuma fazer TOK="$(mint_admin_token ...)" e variáveis sobrevivem no
# subshell mas não no escopo do caller. Stdout é o canal que sobrevive.
mint_admin_token() {
  local role="${1:?role required}"
  local ttl="${2:-900}"
  local sub email
  case "$role" in
    superadmin) sub="$AUTHZ_SUPERADMIN_ID"; email="$AUTHZ_SUPERADMIN_EMAIL" ;;
    manager)    sub="$AUTHZ_MANAGER_ID";    email="$AUTHZ_MANAGER_EMAIL" ;;
    viewer)     sub="$AUTHZ_VIEWER_ID";     email="$AUTHZ_VIEWER_EMAIL" ;;
    support)    sub="$AUTHZ_MANAGER_ID";    email="$AUTHZ_MANAGER_EMAIL" ;;
    *)          sub="$AUTHZ_SUPERADMIN_ID"; email="$AUTHZ_SUPERADMIN_EMAIL" ;;
  esac
  local key kid
  key="$(authz_key_path)"; kid="$(authz_kid)"
  VIRALEFY_KEY="$key" VIRALEFY_KID="$kid" \
    VIRALEFY_SUB="$sub" VIRALEFY_EMAIL="$email" \
    VIRALEFY_ROLE="$role" VIRALEFY_TTL="$ttl" \
    VIRALEFY_TYP="admin" \
    python3 -c '
import os, jwt, uuid, datetime
key = open(os.environ["VIRALEFY_KEY"], "rb").read()
now = datetime.datetime.now(datetime.timezone.utc)
ttl = int(os.environ["VIRALEFY_TTL"])
jti = str(uuid.uuid4())
claims = {
  "sub":   os.environ["VIRALEFY_SUB"],
  "typ":   os.environ["VIRALEFY_TYP"],
  "role":  os.environ["VIRALEFY_ROLE"],
  "email": os.environ["VIRALEFY_EMAIL"],
  "iat":   int(now.timestamp()),
  "exp":   int((now + datetime.timedelta(seconds=ttl)).timestamp()),
  "jti":   jti,
}
tok = jwt.encode(claims, key, algorithm="RS256", headers={"kid": os.environ["VIRALEFY_KID"]})
print(f"{tok}\t{jti}")
' 2>/dev/null
}

# mint_user_token <user_id> [ttl_seconds]
# Stdout: "<token>\t<jti>".
mint_user_token() {
  local sub="${1:?user_id required}"
  local ttl="${2:-900}"
  local key kid
  key="$(authz_key_path)"; kid="$(authz_kid)"
  VIRALEFY_KEY="$key" VIRALEFY_KID="$kid" \
    VIRALEFY_SUB="$sub" VIRALEFY_TTL="$ttl" \
    python3 -c '
import os, jwt, uuid, datetime
key = open(os.environ["VIRALEFY_KEY"], "rb").read()
now = datetime.datetime.now(datetime.timezone.utc)
ttl = int(os.environ["VIRALEFY_TTL"])
jti = str(uuid.uuid4())
claims = {
  "sub":  os.environ["VIRALEFY_SUB"],
  "role": "user",
  "iat":  int(now.timestamp()),
  "exp":  int((now + datetime.timedelta(seconds=ttl)).timestamp()),
  "jti":  jti,
}
tok = jwt.encode(claims, key, algorithm="RS256", headers={"kid": os.environ["VIRALEFY_KID"]})
print(f"{tok}\t{jti}")
' 2>/dev/null
}

# Helpers pra extrair token/jti do output "<token>\t<jti>".
mint_token() { local out="$1"; echo "${out%%$'\t'*}"; }
mint_jti()   { local out="$1"; echo "${out##*$'\t'}"; }

# revoke_jti <jti> [reason]
# Insere em revoked_jtis + NOTIFY pro dispatcher Rust pegar via LISTEN.
revoke_jti() {
  local jti="${1:?jti required}"
  local reason="${2:-authz-test-revoke}"
  psql_q "
    INSERT INTO revoked_jtis (jti, expires_at, revoked_reason)
    VALUES ('$jti', NOW() + INTERVAL '1 hour', '$reason')
    ON CONFLICT DO NOTHING;
    SELECT pg_notify('revoked_jtis_inserted', '$jti');
  " >/dev/null 2>&1
}

# bearer "<token>" — formata pro http_call. Uso:
#   http_call GET "$API/v1/admin/me" "" "$(bearer "$TOK")"
bearer() {
  printf -- '-H\nAuthorization: Bearer %s\n' "${1:-}"
}

# ─── Rate-limit pacing ───────────────────────────────────────────────────
# Prod (dispatcher Rust) usa tower_governor: 1 req/s sustained, burst 30.
# Para evitar 429 contaminando os asserts de RBAC, todos os http hits dos
# scripts authz passam por throttle_pause antes do request.
#
# AUTHZ_PAUSE_MS = delay em ms entre requests (default 250). Sobrescreva
# pra 0 em ambiente dev local sem rate limit.
# Default 1100ms = 1 req/s + folga p/ governor sustain rate. Permission-boundary
# (44 hits) demora ~50s, ainda < 1min do orçamento §22.3.
AUTHZ_PAUSE_MS="${AUTHZ_PAUSE_MS:-1100}"
throttle_pause() {
  local ms="$AUTHZ_PAUSE_MS"
  (( ms > 0 )) || return 0
  # python3 já é prereq; sleep com fração funciona em coreutils Debian.
  sleep "$(awk "BEGIN{print $ms/1000}")"
}

# assert_http_with_token <desc> <expected_codes> <method> <url> <token> [body]
# Wrapper sobre assert_http_in que injeta Authorization Bearer + throttling.
# Retry uma vez se HTTP_CODE=429 (espera 2s).
assert_http_with_token() {
  local desc="$1" allowed="$2" method="$3" url="$4" token="$5"
  local body="${6:-}"
  throttle_pause
  http_call "$method" "$url" "$body" -H "Authorization: Bearer $token"
  if [[ "$HTTP_CODE" == "429" ]]; then
    sleep 2
    http_call "$method" "$url" "$body" -H "Authorization: Bearer $token"
  fi
  if [[ "|$allowed|" == *"|$HTTP_CODE|"* ]]; then
    test_pass "$desc → $HTTP_CODE ∈ {$allowed}"
  else
    test_fail "$desc → got $HTTP_CODE not in {$allowed} ($method $url)" "$HTTP_BODY"
  fi
}

# http_call_token <method> <url> <token> [body]
# Wrapper de http_call (sem assert) com throttle + retry em 429.
http_call_token() {
  local method="$1" url="$2" token="$3" body="${4:-}"
  throttle_pause
  http_call "$method" "$url" "$body" -H "Authorization: Bearer $token"
  if [[ "$HTTP_CODE" == "429" ]]; then
    sleep 2
    http_call "$method" "$url" "$body" -H "Authorization: Bearer $token"
  fi
}

# vim: set ft=bash et sw=2:
