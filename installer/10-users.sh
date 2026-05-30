#!/usr/bin/env bash
# Cria os usuários de sistema isolados (um por pacote) e o grupo viralefy.
# Cada usuário só acessa o seu próprio /viralefy/<pkg>; o grupo viralefy
# concede acesso de leitura ao /etc/viralefy/.env compartilhado.

install_users() {
  log "criando usuários e grupo de sistema"

  if ! getent group viralefy >/dev/null; then
    groupadd --system viralefy
    info "grupo viralefy criado"
  fi

  for pkg in "${PACKAGES[@]}"; do
    local u
    u="$(user_of "$pkg")"
    if id "$u" >/dev/null 2>&1; then
      continue
    fi
    useradd \
      --system \
      --gid viralefy \
      --home-dir "$(dir_of "$pkg")" \
      --shell /usr/sbin/nologin \
      --comment "Viralefy $pkg service" \
      "$u"
    info "usuário $u criado"
  done

  install -d -m 0755 -o root -g root "$ROOT_DIR"
}
