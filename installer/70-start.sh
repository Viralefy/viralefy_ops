#!/usr/bin/env bash
# Habilita e sobe os serviços, espera healthcheck.
#
# Ordem importa: payments + sender são deps do viralefy-api (orchestrator).
# Sobem primeiro, espera /internal/health, só depois sobe o api e os fronts.

install_start() {
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
