#!/usr/bin/env bash
# Habilita e sobe os serviços, espera healthcheck.
#
# Ordem importa: payments + sender são deps do viralefy-api (orchestrator).
# Sobem primeiro, espera /internal/health, só depois sobe o api e os fronts.
#
# Migrations rodam ANTES de qualquer serviço subir (descoberta do DR drill
# 2026-06-10): viralefy-auth assert schema de `refresh_tokens` no startup;
# essa tabela vive nas migrations 039_auth_tokens / 040_proof_storage_key
# que pertencem ao viralefy_core. Sem `viralefy-core migrate up`, auth
# entra em crash loop. Ordem: api → core (PHASE-9, se presente) → services.

install_start() {
  run_migrations

  log "habilitando e subindo microservices (payments, sender)"
  systemctl enable --now viralefy-payments viralefy-sender

  wait_internal_healthy payments "${PAYMENTS_PORT:-8081}"
  wait_internal_healthy sender   "${SENDER_PORT:-8082}"

  log "subindo viralefy-api + fronts"
  systemctl enable --now viralefy-api viralefy-front viralefy-backoffice
  # Timer do backup do Postgres — diário 03:00 UTC. enable+now agenda imediato.
  systemctl enable --now viralefy-backup.timer
  wait_healthy
}

# Migrations sequencing (DR drill 2026-06-10):
#   1. viralefy-api migrate up   → migrations 001..038 (legacy schema)
#   2. viralefy-core migrate up  → migrations 039_auth_tokens, 040_proof_storage_key
#
# core migrate é PRECONDIÇÃO de viralefy-auth (refresh_tokens assert).
# Idempotente: migrate up é no-op se já aplicado. Falha hard se api migrate
# falhar (schema base); falha hard em core SOMENTE se o binário existir
# (PHASE-9 pode estar desabilitado em hosts < phase-9-ready).
run_migrations() {
  local api_bin="${ROOT_DIR}/api/bin/viralefy-api"
  if [[ -x "$api_bin" ]]; then
    log "viralefy-api migrate up (legacy migrations 001..038)"
    run_as viralefy-api bash -c "set -a; source '$ENV_FILE'; set +a; '$api_bin' migrate up" \
      || fatal "viralefy-api migrate up falhou — abortando start"
  else
    warn "viralefy-api binário ausente em $api_bin — pulando migrate"
  fi

  local core_bin=/usr/local/sbin/viralefy-core
  if [[ -x "$core_bin" ]]; then
    log "viralefy-core migrate up (PHASE-9 migrations 039/040 — precondição de viralefy-auth)"
    run_as viralefy-core bash -c "set -a; source '$ENV_FILE'; set +a; '$core_bin' migrate up" \
      || fatal "viralefy-core migrate up falhou — viralefy-auth não vai subir sem refresh_tokens"
  else
    info "viralefy-core ausente — pulando migrate PHASE-9 (host < phase-9-ready)"
  fi
}

# Espera /internal/health do microservice responder 200 antes de prosseguir.
# Falha hard se não subir em 60s — preferimos abortar o install do que subir
# o api orfão dos backends.
wait_internal_healthy() {
  local svc="$1" port="$2"
  local url="http://127.0.0.1:$port/internal/health"
  log "aguardando viralefy-$svc em $url"
  local i
  for i in $(seq 1 60); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      info "viralefy-$svc saudável (${i}s)"
      return 0
    fi
    sleep 1
  done
  fatal "viralefy-$svc não respondeu em 60s — abortando start do api"
}

wait_healthy() {
  log "aguardando API saudável em http://127.0.0.1:${PORT:-8080}/health"
  local i
  for i in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:${PORT:-8080}/health" >/dev/null 2>&1; then
      info "API saudável (${i}s)"
      break
    fi
    sleep 1
  done

  for port in 3000 3001; do
    for i in $(seq 1 60); do
      if curl -fsS "http://127.0.0.1:$port" >/dev/null 2>&1; then
        info ":$port respondendo (${i}s)"
        break
      fi
      sleep 1
    done
  done
}
