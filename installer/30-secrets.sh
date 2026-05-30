#!/usr/bin/env bash
# Gerencia segredos em /etc/viralefy/.env (sobrevive a updates destrutivos).
#
# Fluxo:
#   1. Cria /etc/viralefy/ com perms 0750 (root:viralefy).
#   2. Se .env existir, carrega para preservar valores manuais.
#   3. Gera o que faltar (JWT_SECRET, DATABASE_PASSWORD) e mantém o resto.
#   4. RESEND_API_KEY pode vir via env var (não-interativo) ou ser perguntada.
#   5. Escreve .env com perms 0640.

install_secrets() {
  log "configurando segredos em $ENV_FILE"

  install -d -m 0750 -o root -g viralefy "$ENV_DIR"

  # Carrega valores existentes (sem expor no shell — apenas se vai preservar).
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
    info "preservando segredos existentes de $ENV_FILE"
  fi

  : "${PORT:=8080}"
  : "${JWT_SECRET:=$(gen_secret 64)}"
  : "${DATABASE_PASSWORD:=$(gen_secret 32)}"
  : "${DATABASE_URL:=postgres://viralefy:${DATABASE_PASSWORD}@localhost:5432/viralefy?sslmode=disable}"
  : "${CORS_ORIGINS:=http://localhost:3000,http://localhost:3001}"

  : "${EMAIL_PROVIDER:=resend}"
  : "${RESEND_FROM:=onboarding@resend.dev}"
  : "${RESEND_FROM_NAME:=Viralefy}"
  : "${RESEND_BASE_URL:=https://api.resend.com}"

  if [[ -z "${RESEND_API_KEY:-}" ]]; then
    if [[ -t 0 ]]; then
      read -r -s -p "RESEND_API_KEY: " RESEND_API_KEY; echo
    else
      warn "RESEND_API_KEY não informada — Resend ficará sem chave (LogSender)."
      RESEND_API_KEY=""
    fi
  fi

  : "${NEXT_PUBLIC_API_URL:=http://localhost:$PORT}"
  : "${NEXT_PUBLIC_SITE_URL:=http://localhost:3000}"

  # Exporta DATABASE_PASSWORD para os módulos seguintes (PostgreSQL).
  export DATABASE_PASSWORD JWT_SECRET RESEND_API_KEY NEXT_PUBLIC_API_URL NEXT_PUBLIC_SITE_URL

  umask 027
  cat > "$ENV_FILE" <<-ENV
		# Viralefy — variáveis de ambiente (gerado por viralefy-install)
		# Sobrevive a updates destrutivos. Edite com cuidado.

		# API
		PORT=$PORT
		DATABASE_URL=$DATABASE_URL
		DATABASE_PASSWORD=$DATABASE_PASSWORD
		JWT_SECRET=$JWT_SECRET
		CORS_ORIGINS=$CORS_ORIGINS

		# E-mail (Resend)
		EMAIL_PROVIDER=$EMAIL_PROVIDER
		RESEND_API_KEY=$RESEND_API_KEY
		RESEND_FROM=$RESEND_FROM
		RESEND_FROM_NAME=$RESEND_FROM_NAME
		RESEND_BASE_URL=$RESEND_BASE_URL

		# Front / Backoffice (Next.js)
		NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL
		NEXT_PUBLIC_SITE_URL=$NEXT_PUBLIC_SITE_URL
ENV
  chown root:viralefy "$ENV_FILE"
  chmod 0640 "$ENV_FILE"
  info "$ENV_FILE pronto (perms 0640, root:viralefy)"
}
