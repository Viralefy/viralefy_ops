#!/usr/bin/env bash
# Build de cada pacote rodando como o usuário do serviço.

install_build() {
  log "buildando pacotes"
  # Go services em paralelo — todos compartilham o toolchain.
  build_api &
  PID_API=$!
  build_go payments cmd/payments &
  PID_PAY=$!
  build_go sender cmd/sender &
  PID_SND=$!

  local fail=0
  wait $PID_API || { err "build da API falhou"; fail=1; }
  wait $PID_PAY || { err "build de payments falhou"; fail=1; }
  wait $PID_SND || { err "build de sender falhou"; fail=1; }
  [[ $fail -eq 0 ]] || fatal "build Go falhou — abortando"

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

# build_go: padrão do build_api pros microservices (payments, sender).
# Compila /viralefy/<pkg>/<cmd_path> em /viralefy/<pkg>/bin/viralefy-<pkg>
# e copia pra /usr/local/sbin/ (referenciado pelo ExecStart dos units).
build_go() {
  local pkg="$1" cmd_path="$2"
  local dir; dir="$(dir_of "$pkg")"
  local user; user="$(user_of "$pkg")"
  local bin_name="viralefy-$pkg"
  log "build do $pkg (Go)"
  install -d -m 0755 -o "$user" -g viralefy "$dir/bin"
  run_as "$user" env PATH="/usr/local/go/bin:$PATH" \
    bash -c "cd '$dir' && go build -trimpath -ldflags='-s -w' -o bin/$bin_name ./$cmd_path"
  install -m 0755 -o root -g root "$dir/bin/$bin_name" "/usr/local/sbin/$bin_name"
  info "binário em /usr/local/sbin/$bin_name ($(du -h "$dir/bin/$bin_name" | cut -f1))"
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
