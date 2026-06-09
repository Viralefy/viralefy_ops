#!/usr/bin/env bash
# Instala unidades systemd hardened e os comandos /usr/local/sbin/.

install_systemd() {
  log "instalando systemd units e CLIs"
  local ops_dir; ops_dir="$(dir_of ops)"
  local src="$ops_dir/systemd"

  install -d -m 0755 -o root -g root /etc/systemd/system
  for unit in viralefy-api viralefy-front viralefy-backoffice viralefy-payments viralefy-sender; do
    install -m 0644 -o root -g root "$src/$unit.service" "/etc/systemd/system/$unit.service"
  done

  # Backup do Postgres: service + timer + diretório de saída.
  for unit in viralefy-backup.service viralefy-backup.timer; do
    install -m 0644 -o root -g root "$src/$unit" "/etc/systemd/system/$unit"
  done
  install -d -m 0700 -o root -g root /var/backups/viralefy

  # Os CLIs (update/status/logs/backup) ficam em /usr/local/sbin pra
  # sobreviverem ao rm -rf de /viralefy/ops durante o update destrutivo.
  for cmd in viralefy-update viralefy-status viralefy-logs viralefy-backup; do
    install -m 0755 -o root -g root "$ops_dir/bin/$cmd" "/usr/local/sbin/$cmd"
  done

  systemctl daemon-reload
  info "systemd recarregado"
}
