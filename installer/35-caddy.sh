#!/usr/bin/env bash
# Configura o Caddy como reverse proxy + TLS automático.
#
# Caddy lê os domínios via {$DOMAIN_*} de /etc/caddy/viralefy.env (gerado aqui
# a partir do /etc/viralefy/.env). Não damos acesso ao .env principal pra
# manter o trust boundary (Caddy não precisa ver DATABASE_URL, RESEND_API_KEY).

install_caddy_config() {
  log "configurando Caddy (Caddyfile + drop-in systemd)"

  local caddy_env=/etc/caddy/viralefy.env
  install -d -m 0755 -o root -g root /etc/caddy

  # Subset do .env que o Caddy precisa — domínios + email ACME.
  umask 027
  cat > "$caddy_env" <<-ENV
		DOMAIN_FRONT=$DOMAIN_FRONT
		DOMAIN_BACKOFFICE=$DOMAIN_BACKOFFICE
		DOMAIN_API=$DOMAIN_API
		CADDY_EMAIL=$CADDY_EMAIL
ENV
  chown root:caddy "$caddy_env"
  chmod 0640 "$caddy_env"

  # Caddyfile vem do repo ops.
  install -m 0644 -o root -g root \
    "$(dir_of ops)/config/Caddyfile" /etc/caddy/Caddyfile

  # Drop-in systemd: Caddy carrega o env file específico.
  install -d -m 0755 -o root -g root /etc/systemd/system/caddy.service.d
  cat > /etc/systemd/system/caddy.service.d/viralefy.conf <<-EOF
		[Service]
		EnvironmentFile=/etc/caddy/viralefy.env
EOF

  systemctl daemon-reload

  # Validação estática antes de reload — evita derrubar Caddy com sintaxe ruim.
  if ! caddy validate --config /etc/caddy/Caddyfile --envfile "$caddy_env" 2>/dev/null; then
    fatal "Caddyfile inválido — verifique /etc/caddy/Caddyfile"
  fi

  systemctl enable --now caddy >/dev/null
  systemctl reload caddy 2>/dev/null || systemctl restart caddy
  info "Caddy servindo $DOMAIN_FRONT, $DOMAIN_BACKOFFICE, $DOMAIN_API"
}
