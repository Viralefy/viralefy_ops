#!/usr/bin/env bash
# Instala MinIO single-instance via Docker pra object storage S3-compatível.
# Path de migração: trocar STORAGE_ENDPOINT pro Cloudflare R2 quando atingir
# volume — código da API é S3-compatível, nenhuma mudança no app.
#
# Dados em /var/lib/viralefy-storage (sobrevive a viralefy-update destrutivo,
# igual ao Postgres). Credenciais geradas no primeiro install e persistidas
# em /etc/viralefy/.env (root:owned, 0600).
#
# Idempotente: rerun não reseta keys nem buckets.

install_storage() {
  log "instalando storage (MinIO single-instance)"

  install_storage_docker
  install_storage_dirs
  install_storage_secrets
  install_storage_compose
  start_storage_service
}

# Docker é a única dependência hard. Em VPSs Debian/Ubuntu modernos vem
# como docker.io ou docker-ce. Usamos o que estiver disponível; se nenhum,
# instala docker.io de apt (suficiente pra single-instance, sem swarm).
install_storage_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "docker já presente: $(docker --version)"
    return
  fi
  log "instalando docker.io via apt"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io docker-compose-v2
  systemctl enable --now docker
}

install_storage_dirs() {
  install -d -m 0750 -o root -g root /var/lib/viralefy-storage
  install -d -m 0750 -o root -g root /etc/viralefy-storage
}

# Credenciais geradas no primeiro install. STORAGE_ACCESS_KEY visível (vai
# pro client S3 da API), STORAGE_SECRET_KEY confidencial.
install_storage_secrets() {
  local envfile=/etc/viralefy/.env
  if grep -q '^STORAGE_ACCESS_KEY=' "$envfile" 2>/dev/null; then
    log "STORAGE_* já presentes em $envfile — não rotaciona"
    return
  fi
  log "gerando credenciais MinIO (primeiro install)"
  local ak sk
  ak="vf_$(openssl rand -hex 8)"   # ex: vf_a1b2c3d4e5f6g7h8
  sk="$(openssl rand -base64 32 | tr -d '/+=' | head -c 40)"
  {
    echo ""
    echo "# --- Object storage (MinIO local, S3-compat) ---"
    echo "STORAGE_ENDPOINT=http://127.0.0.1:9000"
    echo "STORAGE_ACCESS_KEY=${ak}"
    echo "STORAGE_SECRET_KEY=${sk}"
    echo "STORAGE_REGION=us-east-1"
    echo "STORAGE_BUCKET_PROOFS=viralefy-proofs"
    echo "STORAGE_BUCKET_PUBLIC=viralefy-public"
    echo "STORAGE_USE_SSL=false"
  } >> "$envfile"
  chmod 0600 "$envfile"
}

install_storage_compose() {
  local src=/viralefy/viralefy_ops/config/docker-compose.storage.yml
  local dst=/etc/viralefy-storage/docker-compose.yml
  install -m 0640 -o root -g root "$src" "$dst"
}

start_storage_service() {
  local envfile=/etc/viralefy/.env
  log "iniciando MinIO via docker compose"
  ( cd /etc/viralefy-storage && \
    docker compose --env-file "$envfile" up -d --quiet-pull )
  # Aguarda healthcheck antes de criar buckets (minio-init depende).
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if docker inspect --format='{{.State.Health.Status}}' viralefy-storage 2>/dev/null | grep -q healthy; then
      log "MinIO healthy"
      return
    fi
    sleep 2
  done
  log "WARN: MinIO healthcheck não confirmou em 20s; revisar 'docker logs viralefy-storage'"
}
