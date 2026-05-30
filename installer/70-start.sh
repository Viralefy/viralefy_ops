#!/usr/bin/env bash
# Habilita e sobe os serviços, espera healthcheck.

install_start() {
  log "habilitando e subindo serviços"
  systemctl enable --now viralefy-api viralefy-front viralefy-backoffice
  wait_healthy
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
