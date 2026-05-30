#!/usr/bin/env bash
# Configura PostgreSQL: cria role viralefy + db viralefy. Idempotente —
# preserva dados existentes. A senha vive em /etc/viralefy/.env (DATABASE_URL).

install_postgres_role() {
  log "configurando role e banco PostgreSQL"

  # Senha do role — gerada na primeira execução e persistida no .env.
  : "${DATABASE_PASSWORD:?DATABASE_PASSWORD precisa estar setado (vem de 30-secrets.sh)}"

  # Cria role se não existir; atualiza senha sempre (fonte da verdade = .env).
  sudo -u postgres psql -v ON_ERROR_STOP=1 <<-SQL
		DO \$\$
		BEGIN
		  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='viralefy') THEN
		    CREATE ROLE viralefy LOGIN PASSWORD '$DATABASE_PASSWORD';
		  ELSE
		    ALTER ROLE viralefy WITH PASSWORD '$DATABASE_PASSWORD';
		  END IF;
		END
		\$\$;
SQL

  # Cria DB se não existir (idempotente).
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='viralefy'" | grep -q 1; then
    sudo -u postgres createdb -O viralefy viralefy
    info "banco viralefy criado"
  else
    info "banco viralefy já existe"
  fi

  # Garante que o role local consegue conectar via TCP (md5/scram).
  ensure_pg_hba

  systemctl reload postgresql >/dev/null
}

ensure_pg_hba() {
  local pg_conf
  pg_conf="$(sudo -u postgres psql -tAc "SHOW hba_file" 2>/dev/null | tr -d ' ')"
  [[ -f "$pg_conf" ]] || return 0

  if ! grep -qE '^host\s+viralefy\s+viralefy\s+127\.0\.0\.1/32' "$pg_conf"; then
    {
      echo ""
      echo "# Viralefy — conexão local da role viralefy"
      echo "host    viralefy        viralefy        127.0.0.1/32            scram-sha-256"
      echo "host    viralefy        viralefy        ::1/128                 scram-sha-256"
    } >> "$pg_conf"
    info "pg_hba.conf atualizado"
  fi
}
