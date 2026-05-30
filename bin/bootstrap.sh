#!/usr/bin/env bash
# Entry point para instalar do zero em uma máquina nova.
# Uso (uma linha):
#   curl -fsSL https://raw.githubusercontent.com/Viralefy/viralefy_ops/main/bin/bootstrap.sh | sudo bash
#   curl -fsSL ... | sudo RESEND_API_KEY=re_xxx bash
set -euo pipefail

ORG="${VIRALEFY_GH_ORG:-Viralefy}"
BRANCH="${VIRALEFY_BRANCH:-main}"
REPO_BASE="${VIRALEFY_REPO_BASE:-https://github.com/$ORG}"

[[ $EUID -eq 0 ]] || { echo "Precisa rodar como root (sudo)."; exit 1; }

echo "[bootstrap] instalando git/curl (mínimo)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -qq
apt-get install -y -qq git curl ca-certificates >/dev/null

STAGE="$(mktemp -d /tmp/viralefy-ops.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

echo "[bootstrap] clonando viralefy_ops ($REPO_BASE/viralefy_ops.git@$BRANCH)"
git clone --depth 1 --branch "$BRANCH" "$REPO_BASE/viralefy_ops.git" "$STAGE" >/dev/null

echo "[bootstrap] executando viralefy-install"
exec "$STAGE/bin/viralefy-install"
