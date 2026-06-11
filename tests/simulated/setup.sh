#!/usr/bin/env bash
# tests/simulated/setup.sh
# Prepara o ambiente para a engine simulated.
#
#   1. Verifica Python 3.11+.
#   2. Garante os seeds (test-superadmin, test-admin, test-normal-user) via
#      `viralefy test seed-superadmin` se existir, ou aplica
#      tests/seeds/*.sql diretamente via psql.
#   3. Mintea JWTs efêmeros (HS256) usando os secrets que já estão em
#      /etc/viralefy/viralefy_core.env (CORE_JWT_SECRET) e exporta:
#         VIRALEFY_SIM_TOKEN_USER
#         VIRALEFY_SIM_TOKEN_ADMIN
#         VIRALEFY_SIM_TOKEN_SUPERADMIN
#         VIRALEFY_SIM_API_KEY        (do seed)
#
# Idempotente: rodar 2× não duplica seeds (ON CONFLICT) nem rotaciona token
# (TTL 60min — basta source de novo).
#
# Uso:
#   source tests/simulated/setup.sh        # exporta os env vars no shell atual
#   tests/simulated/setup.sh --check       # só valida ambiente, não exporta

set -uo pipefail

_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM_DIR="$_DIR/simulated"
SEEDS_DIR="$_DIR/seeds"

# ─── helpers locais (não dependem de lib.sh pra poder rodar via source) ──
_log() { printf '[setup] %s\n' "$*" >&2; }
_warn() { printf '[setup] WARN %s\n' "$*" >&2; }
_die() { printf '[setup] FATAL %s\n' "$*" >&2; return 1; }

# ─── 1. Python 3.11+ ────────────────────────────────────────────────────
_check_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    _die "python3 não encontrado no PATH"
    return 1
  fi
  local v
  v="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
  case "$v" in
    3.1[1-9]|3.[2-9][0-9]|[4-9].*)
      _log "python $v OK"
      ;;
    *)
      _warn "python $v < 3.11 — engine usa só stdlib mas foi testada em 3.11+"
      ;;
  esac
}

# ─── 2. Seeds ───────────────────────────────────────────────────────────
_ensure_seeds() {
  if command -v viralefy-test >/dev/null 2>&1; then
    _log "rodando: viralefy-test seed-superadmin"
    viralefy-test seed-superadmin || _warn "viralefy-test seed-superadmin falhou (segue)"
    return 0
  fi
  if [[ ! -d "$SEEDS_DIR" ]] || [[ -z "$(ls -A "$SEEDS_DIR"/*.sql 2>/dev/null || true)" ]]; then
    _warn "tests/seeds/*.sql ainda não populado (agent M) — pulando seeds"
    return 0
  fi
  local db_url="${DATABASE_URL:-${VIRALEFY_DATABASE_URL:-}}"
  if [[ -z "$db_url" ]] && [[ -f /etc/viralefy/viralefy_core.env ]]; then
    db_url="$(grep -E '^DATABASE_URL=' /etc/viralefy/viralefy_core.env | cut -d= -f2- | tr -d '"' || true)"
  fi
  if [[ -z "$db_url" ]]; then
    _warn "DATABASE_URL não setada — pulando seeds (rotas authenticated vão falhar)"
    return 0
  fi
  if ! command -v psql >/dev/null 2>&1; then
    _warn "psql não instalado — pulando seeds"
    return 0
  fi
  local f
  for f in "$SEEDS_DIR"/*.sql; do
    _log "psql < $f"
    psql "$db_url" -v ON_ERROR_STOP=1 -f "$f" >/dev/null || _warn "seed $f falhou"
  done
}

# ─── 3. Mint de tokens ─────────────────────────────────────────────────
# Usa secret CORE_JWT_SECRET de /etc/viralefy/viralefy_core.env e gera
# HS256 token. Subjects vêm dos seeds (UUIDs determinísticos).
_mint_jwt_hs256() {
  # _mint_jwt_hs256 <secret> <sub> <kind> <role>
  local secret="$1" sub="$2" kind="$3" role="${4:-}"
  python3 - <<PY
import base64, hmac, hashlib, json, time
secret = ${secret@Q}
sub = ${sub@Q}
kind = ${kind@Q}
role = ${role@Q}
now = int(time.time())
hdr = {"alg":"HS256","typ":"JWT"}
payload = {"sub": sub, "kind": kind, "iat": now, "exp": now + 3600, "iss": "viralefy-sim"}
if role:
    payload["role"] = role
def b64(d): return base64.urlsafe_b64encode(json.dumps(d, separators=(",",":")).encode()).rstrip(b"=").decode()
signing = (b64(hdr) + "." + b64(payload)).encode()
sig = base64.urlsafe_b64encode(hmac.new(secret.encode(), signing, hashlib.sha256).digest()).rstrip(b"=").decode()
print(signing.decode() + "." + sig)
PY
}

_mint_tokens() {
  local secret=""
  if [[ -f /etc/viralefy/viralefy_core.env ]]; then
    secret="$(grep -E '^CORE_JWT_SECRET=' /etc/viralefy/viralefy_core.env | cut -d= -f2- | tr -d '"' || true)"
  fi
  secret="${CORE_JWT_SECRET:-$secret}"
  if [[ -z "$secret" ]]; then
    _warn "CORE_JWT_SECRET não disponível — tokens não serão minted; personas autenticadas vão receber 401 (esperado em ambiente sem seeds)"
    return 0
  fi

  # UUIDs determinísticos do agent M (tests/seeds/test-*.sql). Podem ser
  # sobrescritos via env caso o agent M escolha outros valores.
  local sub_user="${VIRALEFY_SIM_SUB_USER:-11111111-1111-1111-1111-111111111111}"
  local sub_admin="${VIRALEFY_SIM_SUB_ADMIN:-22222222-2222-2222-2222-222222222222}"
  local sub_super="${VIRALEFY_SIM_SUB_SUPERADMIN:-33333333-3333-3333-3333-333333333333}"

  export VIRALEFY_SIM_TOKEN_USER="$(_mint_jwt_hs256 "$secret" "$sub_user" "user")"
  export VIRALEFY_SIM_TOKEN_ADMIN="$(_mint_jwt_hs256 "$secret" "$sub_admin" "admin" "admin")"
  export VIRALEFY_SIM_TOKEN_SUPERADMIN="$(_mint_jwt_hs256 "$secret" "$sub_super" "admin" "superadmin")"
  _log "JWT minted: USER ADMIN SUPERADMIN (TTL 60min)"
}

_load_api_key() {
  # API key vem do seed (tests/seeds/test-api-key.sql) — coluna `key_plaintext`
  # convencionada SimTest!APIKEY. Fallback para env override.
  : "${VIRALEFY_SIM_API_KEY:=SimTest!APIKEY-do-seed-quando-existir}"
  export VIRALEFY_SIM_API_KEY
}

# ─── Orquestração ───────────────────────────────────────────────────────
_check_python
_ensure_seeds
_mint_tokens
_load_api_key

if [[ "${1:-}" == "--check" ]]; then
  _log "check OK"
  return 0 2>/dev/null || exit 0
fi

_log "ready — exported: VIRALEFY_SIM_TOKEN_{USER,ADMIN,SUPERADMIN}, VIRALEFY_SIM_API_KEY"
