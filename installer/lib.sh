#!/usr/bin/env bash
# Helpers compartilhados entre os módulos do installer.
# Carregado por viralefy-install / viralefy-update.

# ---------------- Constantes globais ---------------- #

# Raiz fixa do stack — instalação SEMPRE em /viralefy/<pkg>.
ROOT_DIR="${ROOT_DIR:-/viralefy}"

# Diretório/arquivo de segredos persistentes (sobrevivem a updates).
ENV_DIR="${ENV_DIR:-/etc/viralefy}"
ENV_FILE="${ENV_FILE:-$ENV_DIR/.env}"

# GitHub organization base. Pode ser sobrescrito por env var.
ORG="${VIRALEFY_GH_ORG:-Viralefy}"
REPO_BASE="${VIRALEFY_REPO_BASE:-https://github.com/$ORG}"
BRANCH="${VIRALEFY_BRANCH:-main}"

# Pacotes desplegados (cada um vira /viralefy/<pkg> e um usuário systemd).
PACKAGES=(api front backoffice payments sender)

# Mapeamento package -> repo (basename). archive também é clonado mas não roda.
declare -A REPO_OF=(
  [api]="viralefy_api"
  [front]="viralefy_front"
  [backoffice]="viralefy_backoffice"
  [payments]="viralefy_payments"
  [sender]="viralefy_sender"
  [archive]="viralefy_archive"
  [ops]="viralefy_ops"
)

# Versões alvo (pinadas — diretrizes Anexo A).
GO_VERSION="${GO_VERSION:-1.26.3}"
NODE_MAJOR="${NODE_MAJOR:-24}"
PG_VERSION="${PG_VERSION:-16}"

# ---------------- Logging ---------------- #

if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'; C_BOLD=$'\e[1m'
else
  C_RESET=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BOLD=""
fi

log()  { printf '%s[%s]%s %s\n' "$C_BLU" "$(date +%H:%M:%S)" "$C_RESET" "$*"; }
info() { printf '%s[ok]%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YEL" "$C_RESET" "$*" >&2; }
err()  { printf '%s[erro]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
fatal(){ err "$*"; exit 1; }

# ---------------- Pré-condições ---------------- #

require_root() {
  [[ $EUID -eq 0 ]] || fatal "Precisa rodar como root (use sudo)."
}

require_apt() {
  command -v apt-get >/dev/null || fatal "Distro não suportada: este installer assume Debian/Ubuntu (apt). Detectado: $(. /etc/os-release && echo "$PRETTY_NAME" || echo "desconhecido")"
}

# ---------------- Util ---------------- #

# Roda comando como o usuário do serviço.
run_as() {
  local user="$1"; shift
  sudo -u "$user" -H -- "$@"
}

# Gera segredo aleatório base64 url-safe (sem chars problemáticos em .env).
gen_secret() {
  local n="${1:-48}"
  head -c "$n" /dev/urandom | base64 | tr -d '+/=\n' | head -c "$n"
}

# Usuário de sistema que roda o pacote.
user_of() {
  echo "viralefy-$1"
}

# Diretório do pacote.
dir_of() {
  echo "$ROOT_DIR/$1"
}

# URL do repo (https) do pacote.
repo_of() {
  local pkg="$1"
  echo "$REPO_BASE/${REPO_OF[$pkg]}.git"
}
