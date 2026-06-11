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

  # PHASE-9: novos units pro core (Go domain motor), auth (Go identidade)
  # e dispatcher (Rust borda). Instalados mas NÃO habilitados por default;
  # operador habilita conforme cutover progride. Cada um numa porta
  # dedicada pra não conflitar com a stack legacy.
  for unit in viralefy-core viralefy-auth viralefy-dispatcher; do
    if [[ -f "$src/$unit.service" ]]; then
      install -m 0644 -o root -g root "$src/$unit.service" "/etc/systemd/system/$unit.service"
    fi
  done

  # Backup do Postgres: service + timer + diretório de saída.
  # Verify (daily) e restore drill (weekly) ficam ao lado pra garantir que
  # os dumps são restauráveis — backup sem verify é "esperança", não SLA.
  for unit in \
      viralefy-backup.service viralefy-backup.timer \
      viralefy-backup-verify.service viralefy-backup-verify.timer \
      viralefy-restore-drill.service viralefy-restore-drill.timer; do
    install -m 0644 -o root -g root "$src/$unit" "/etc/systemd/system/$unit"
  done
  install -d -m 0700 -o root -g root /var/backups/viralefy

  # PHASE-9 crons do viralefy_core: reconcile (drift diário) e
  # user-deletion (hard-delete LGPD Art. 18 IV). Cada um é um binário
  # Go separado em /usr/local/sbin/ — o build do core gera ambos
  # quando presentes. Unit + timer instalados aqui; CLI fica condicional
  # à existência do binário (host sem core ignora silenciosamente).
  for unit in \
      viralefy-reconcile.service viralefy-reconcile.timer \
      viralefy-user-deletion.service viralefy-user-deletion.timer \
      viralefy-orders-anonymize.service viralefy-orders-anonymize.timer \
      viralefy-test-cleanup.service viralefy-test-cleanup.timer; do
    if [[ -f "$src/$unit" ]]; then
      install -m 0644 -o root -g root "$src/$unit" "/etc/systemd/system/$unit"
    fi
  done

  # Diretório do node_exporter textfile collector pras métricas do
  # user-deletion-cron — node_exporter já lê esse path por convenção.
  install -d -m 0755 -o root -g root /var/lib/node_exporter/textfile_collector

  # Os CLIs ficam em /usr/local/sbin pra sobreviverem ao rm -rf de
  # /viralefy/ops durante o update destrutivo.
  for cmd in \
      viralefy-update viralefy-status viralefy-logs viralefy-smoke \
      viralefy-backup viralefy-backup-verify viralefy-restore-drill; do
    install -m 0755 -o root -g root "$ops_dir/bin/$cmd" "/usr/local/sbin/$cmd"
  done

  systemctl daemon-reload
  info "systemd recarregado"
}
