#!/usr/bin/env bash
# Gerencia segredos em /etc/viralefy/.env (sobrevive a updates destrutivos).
#
# Fluxo:
#   1. Cria /etc/viralefy/ com perms 0750 (root:viralefy).
#   2. Se .env existir, carrega para preservar valores manuais.
#   3. Gera o que faltar (JWT_SECRET, DATABASE_PASSWORD).
#   4. RESEND_API_KEY pode vir via env var (não-interativo) ou ser perguntada.
#   5. Domínios públicos (DOMAIN_FRONT/BACKOFFICE/API) + CADDY_EMAIL podem ser
#      definidos no install (env var) ou editados depois no .env. Defaults
#      apontam para localhost (Caddy usará CA local).
#   6. CORS_ORIGINS e NEXT_PUBLIC_API_URL/SITE_URL são derivados dos domínios.
#   7. Escreve .env com perms 0640.

install_secrets() {
  log "configurando segredos em $ENV_FILE"

  # 0770 (em vez de 0750) permite ao viralefy-api criar
  # /etc/viralefy/jwt-rs256.pem via jwtkeys.LoadOrGenerate no primeiro boot
  # após a migração HS256→RS256. .env continua mode 0640 (root-owned).
  install -d -m 0770 -o root -g viralefy "$ENV_DIR"

  # Carrega valores existentes (sem expor no shell — apenas se vai preservar).
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
    info "preservando segredos existentes de $ENV_FILE"
  fi

  : "${PORT:=8080}"
  : "${BIND_HOST:=127.0.0.1}"
  : "${JWT_SECRET:=$(gen_secret 64)}"
  : "${DATABASE_PASSWORD:=$(gen_secret 32)}"
  # 2FA encryption key — AES-256 (32 bytes). Cifra secrets TOTP em rest.
  # Hex 64 chars. Vazio = 2FA disabled. Trocar essa key invalida TODOS os
  # enrollments existentes (re-enroll obrigatório) — não rotacionar.
  : "${TWOFA_ENCRYPTION_KEY:=$(openssl rand -hex 32)}"

  # ---- Microservices (loopback) ---- #
  # Token compartilhado entre viralefy_api, viralefy_payments e viralefy_sender
  # — header X-Internal-Token em cada request inter-service. Loopback-only é a
  # primeira barreira; o token é defense-in-depth contra processos co-locados.
  # 32 bytes hex (64 chars). Rotacionar exige restart sincronizado dos 3 services.
  : "${INTERNAL_SHARED_SECRET:=$(openssl rand -hex 32)}"
  : "${PAYMENTS_PORT:=8081}"
  : "${PAYMENTS_BIND_HOST:=127.0.0.1}"
  : "${PAYMENTS_INTERNAL_URL:=http://${PAYMENTS_BIND_HOST}:${PAYMENTS_PORT}}"
  : "${SENDER_PORT:=8082}"
  : "${SENDER_BIND_HOST:=127.0.0.1}"
  : "${SENDER_INTERNAL_URL:=http://${SENDER_BIND_HOST}:${SENDER_PORT}}"

  # ---- Telegram bot (opcional) ---- #
  # Vazio = canal Telegram desabilitado (sender vira no-op nesse channel).
  : "${TELEGRAM_BOT_TOKEN:=}"
  : "${TELEGRAM_ADMIN_CHAT_ID:=}"
  : "${DATABASE_URL:=postgres://viralefy:${DATABASE_PASSWORD}@localhost:5432/viralefy?sslmode=disable}"

  : "${EMAIL_PROVIDER:=resend}"
  : "${RESEND_FROM:=onboarding@resend.dev}"
  : "${RESEND_FROM_NAME:=Viralefy}"
  : "${RESEND_BASE_URL:=https://api.resend.com}"

  # ---- Bing IndexNow ---- #
  # Chave pública vai exposta em /<INDEXNOW_KEY>.txt no front.
  # Secret gates o endpoint /api/indexnow contra abuso. Ambos sobrevivem
  # ao update destrutivo. INDEXNOW_KEY tem default hardcoded p/ casar com
  # o arquivo já hospedado em viralefy_front/public/ — só gera novo se o
  # operador definir manualmente antes do install.
  : "${INDEXNOW_KEY:=adcfcb87889076210f395f754a9ad0c3}"
  : "${INDEXNOW_SECRET:=$(gen_secret 24)}"

  # Domínios públicos servidos por Caddy. Default localhost — Caddy usa CA local.
  : "${DOMAIN_FRONT:=localhost}"
  : "${DOMAIN_BACKOFFICE:=admin.localhost}"
  : "${DOMAIN_API:=api.localhost}"
  : "${DOMAIN_OBS:=obs.localhost}"
  : "${CADDY_EMAIL:=}"

  # Grafana admin password (persistente). Acesso em https://$DOMAIN_OBS.
  : "${GRAFANA_ADMIN_PASSWORD:=$(gen_secret 32)}"
  : "${OTEL_EXPORTER_OTLP_ENDPOINT:=http://127.0.0.1:4318}"

  # Derivados (recomputa sempre que domínios mudarem).
  local scheme
  if [[ "$DOMAIN_FRONT" == "localhost" || "$DOMAIN_FRONT" == *.localhost ]]; then
    scheme="https"   # Caddy usa CA local mesmo em localhost
  else
    scheme="https"
  fi
  : "${NEXT_PUBLIC_API_URL:=$scheme://$DOMAIN_API}"
  # SITE_URL aponta pra www como canônico — apex viralefy.com redireciona
  # 301 pra www. Hostnames sem ponto (localhost) ficam direto, sem www.
  if [[ "$DOMAIN_FRONT" == *.*  ]]; then
    : "${NEXT_PUBLIC_SITE_URL:=$scheme://www.$DOMAIN_FRONT}"
  else
    : "${NEXT_PUBLIC_SITE_URL:=$scheme://$DOMAIN_FRONT}"
  fi
  : "${CORS_ORIGINS:=$scheme://$DOMAIN_FRONT,$scheme://www.$DOMAIN_FRONT,$scheme://$DOMAIN_BACKOFFICE}"

  if [[ -z "${RESEND_API_KEY:-}" ]]; then
    if [[ -t 0 ]]; then
      read -r -s -p "RESEND_API_KEY: " RESEND_API_KEY; echo
    else
      warn "RESEND_API_KEY não informada — Resend ficará sem chave (LogSender)."
      RESEND_API_KEY=""
    fi
  fi

  # Turnstile (anti-bot) e admin webhook (Slack/Discord). Vazios = bypass —
  # ambos têm tratamento de no-op no código. Mantemos no template pra
  # sobreviver à regeneração destrutiva do .env.
  : "${NEXT_PUBLIC_TURNSTILE_SITE_KEY:=}"
  : "${TURNSTILE_SECRET_KEY:=}"
  : "${ADMIN_WEBHOOK_URL:=}"

  # Exporta para os módulos seguintes (PostgreSQL, build, Caddy, Observabilidade).
  export DATABASE_PASSWORD JWT_SECRET RESEND_API_KEY \
         NEXT_PUBLIC_API_URL NEXT_PUBLIC_SITE_URL \
         NEXT_PUBLIC_TURNSTILE_SITE_KEY TURNSTILE_SECRET_KEY ADMIN_WEBHOOK_URL \
         DOMAIN_FRONT DOMAIN_BACKOFFICE DOMAIN_API DOMAIN_OBS CADDY_EMAIL BIND_HOST \
         GRAFANA_ADMIN_PASSWORD OTEL_EXPORTER_OTLP_ENDPOINT \
         TWOFA_ENCRYPTION_KEY \
         INTERNAL_SHARED_SECRET \
         PAYMENTS_PORT PAYMENTS_BIND_HOST PAYMENTS_INTERNAL_URL \
         SENDER_PORT SENDER_BIND_HOST SENDER_INTERNAL_URL \
         TELEGRAM_BOT_TOKEN TELEGRAM_ADMIN_CHAT_ID

  umask 027
  cat > "$ENV_FILE" <<-ENV
		# Viralefy — variáveis de ambiente (gerado por viralefy-install)
		# Sobrevive a updates destrutivos. Edite com cuidado.

		# ---- API ---- #
		PORT=$PORT
		BIND_HOST=$BIND_HOST
		DATABASE_URL=$DATABASE_URL
		DATABASE_PASSWORD=$DATABASE_PASSWORD
		JWT_SECRET=$JWT_SECRET
		TWOFA_ENCRYPTION_KEY=$TWOFA_ENCRYPTION_KEY
		CORS_ORIGINS=$CORS_ORIGINS

		# ---- E-mail (Resend) ---- #
		EMAIL_PROVIDER=$EMAIL_PROVIDER
		RESEND_API_KEY=$RESEND_API_KEY
		RESEND_FROM=$RESEND_FROM
		RESEND_FROM_NAME=$RESEND_FROM_NAME
		RESEND_BASE_URL=$RESEND_BASE_URL

		# ---- Bing IndexNow ---- #
		INDEXNOW_KEY=$INDEXNOW_KEY
		INDEXNOW_SECRET=$INDEXNOW_SECRET

		# ---- Front / Backoffice (Next.js — usadas em build) ---- #
		NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL
		NEXT_PUBLIC_SITE_URL=$NEXT_PUBLIC_SITE_URL
		NEXT_PUBLIC_TURNSTILE_SITE_KEY=$NEXT_PUBLIC_TURNSTILE_SITE_KEY

		# ---- Cloudflare Turnstile (anti-bot) ---- #
		# Site key é pública (front carrega via NEXT_PUBLIC_*); secret é
		# server-only. Ambos vazios = bypass (HML).
		TURNSTILE_SECRET_KEY=$TURNSTILE_SECRET_KEY

		# ---- Admin webhook (Slack/Discord) ---- #
		# Notificação quando ticket de high-touch abre. Vazio = no-op.
		ADMIN_WEBHOOK_URL=$ADMIN_WEBHOOK_URL

		# ---- Caddy (HTTP/HTTPS) ---- #
		DOMAIN_FRONT=$DOMAIN_FRONT
		DOMAIN_BACKOFFICE=$DOMAIN_BACKOFFICE
		DOMAIN_API=$DOMAIN_API
		DOMAIN_OBS=$DOMAIN_OBS
		CADDY_EMAIL=$CADDY_EMAIL

		# ---- Microservices (loopback-only) ---- #
		# Loopback HTTP entre viralefy_api ↔ viralefy_payments ↔ viralefy_sender.
		# Caddy reverse-proxia /v1/webhooks/{stripe,heleket,woovi} → payments.
		PAYMENTS_PORT=$PAYMENTS_PORT
		PAYMENTS_BIND_HOST=$PAYMENTS_BIND_HOST
		PAYMENTS_INTERNAL_URL=$PAYMENTS_INTERNAL_URL
		SENDER_PORT=$SENDER_PORT
		SENDER_BIND_HOST=$SENDER_BIND_HOST
		SENDER_INTERNAL_URL=$SENDER_INTERNAL_URL
		INTERNAL_SHARED_SECRET=$INTERNAL_SHARED_SECRET

		# ---- Telegram bot (opcional, sender) ---- #
		TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
		TELEGRAM_ADMIN_CHAT_ID=$TELEGRAM_ADMIN_CHAT_ID

		# ---- Observabilidade (Grafana / OTel) ---- #
		GRAFANA_ADMIN_PASSWORD=$GRAFANA_ADMIN_PASSWORD
		OTEL_EXPORTER_OTLP_ENDPOINT=$OTEL_EXPORTER_OTLP_ENDPOINT
		OTEL_SERVICE_NAME=viralefy-api
ENV
  chown root:viralefy "$ENV_FILE"
  chmod 0640 "$ENV_FILE"
  info "$ENV_FILE pronto (perms 0640, root:viralefy)"
}
