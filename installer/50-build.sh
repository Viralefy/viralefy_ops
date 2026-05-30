#!/usr/bin/env bash
# Build de cada pacote rodando como o usuário do serviço.

install_build() {
  log "buildando pacotes"
  build_api
  build_node front
  build_node backoffice
}

build_api() {
  local dir; dir="$(dir_of api)"
  local user; user="$(user_of api)"
  log "build da API (Go)"
  install -d -m 0755 -o "$user" -g viralefy "$dir/bin"
  run_as "$user" env PATH="/usr/local/go/bin:$PATH" \
    bash -c "cd '$dir' && go build -trimpath -ldflags='-s -w' -o bin/viralefy-api ./cmd/api"
  info "binário em $dir/bin/viralefy-api ($(du -h "$dir/bin/viralefy-api" | cut -f1))"
}

build_node() {
  local pkg="$1"
  local dir; dir="$(dir_of "$pkg")"
  local user; user="$(user_of "$pkg")"
  log "build do $pkg (Next.js)"

  # Copia variáveis públicas do .env para um .env.local lido pelo Next build
  # (NEXT_PUBLIC_* precisa estar disponível em build time).
  install -m 0640 -o "$user" -g viralefy /dev/null "$dir/.env.local"
  {
    grep -E '^NEXT_PUBLIC_' "$ENV_FILE" || true
  } > "$dir/.env.local"
  chown "$user:viralefy" "$dir/.env.local"

  run_as "$user" bash -c "cd '$dir' && npm ci --no-audit --no-fund --silent"
  run_as "$user" bash -c "cd '$dir' && npm run build --silent"
  info "$pkg buildado"
}
