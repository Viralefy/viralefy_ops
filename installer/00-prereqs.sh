#!/usr/bin/env bash
# Instala dependências de sistema: git, curl, build tools, Go, Node, PostgreSQL.
# Idempotente — pula o que já estiver na versão alvo.

install_prereqs() {
  log "verificando pré-requisitos do sistema"
  require_apt

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y -qq
  apt-get install -y -qq \
    git curl jq ca-certificates gnupg lsb-release \
    build-essential pkg-config \
    sudo openssl \
    debian-keyring debian-archive-keyring apt-transport-https >/dev/null

  install_go
  install_node
  install_postgres
  install_caddy
}

install_go() {
  if command -v go >/dev/null && [[ "$(go version 2>/dev/null)" == *"go$GO_VERSION"* ]]; then
    info "Go $GO_VERSION já instalado"
    return
  fi
  log "instalando Go $GO_VERSION em /usr/local/go"
  local arch tmp
  arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64) arch="amd64" ;;
    arm64) arch="arm64" ;;
    *) fatal "arquitetura não suportada: $arch" ;;
  esac
  tmp="$(mktemp -d)"
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz" -o "$tmp/go.tar.gz"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$tmp/go.tar.gz"
  rm -rf "$tmp"
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
  info "Go $(go version | awk '{print $3}') instalado"
}

install_node() {
  if command -v node >/dev/null && [[ "$(node -v | tr -d v | cut -d. -f1)" -ge "$NODE_MAJOR" ]]; then
    info "Node $(node -v) já instalado (>= $NODE_MAJOR)"
    return
  fi
  log "instalando Node $NODE_MAJOR via NodeSource"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
  info "Node $(node -v) instalado"
}

install_postgres() {
  if command -v psql >/dev/null && systemctl is-enabled --quiet postgresql 2>/dev/null; then
    info "PostgreSQL já instalado e habilitado"
    return
  fi
  log "instalando PostgreSQL $PG_VERSION"
  apt-get install -y -qq "postgresql-$PG_VERSION" "postgresql-client-$PG_VERSION" >/dev/null \
    || apt-get install -y -qq postgresql postgresql-client >/dev/null
  systemctl enable --now postgresql >/dev/null
  info "PostgreSQL pronto"
}

install_caddy() {
  if command -v caddy >/dev/null && systemctl list-unit-files caddy.service >/dev/null 2>&1; then
    info "Caddy já instalado"
    return
  fi
  log "instalando Caddy (repo oficial Cloudsmith)"
  local keyring=/usr/share/keyrings/caddy-stable-archive-keyring.gpg
  if [[ ! -f "$keyring" ]]; then
    curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor -o "$keyring"
  fi
  if [[ ! -f /etc/apt/sources.list.d/caddy-stable.list ]]; then
    curl -fsSL "https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt?distro=debian&codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-bookworm}")" \
      | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  fi
  apt-get update -y -qq
  apt-get install -y -qq caddy >/dev/null
  info "Caddy $(caddy version 2>/dev/null | head -1)"
}
