#!/usr/bin/env bash
# Instala o stack de observabilidade: Grafana, Loki, Tempo, Prometheus, Alloy,
# node_exporter. Tudo loopback-only — Caddy expõe Grafana em $DOMAIN_OBS.
#
# Dados ficam em /var/lib/{grafana,loki,tempo,prometheus,alloy} e configs em
# /etc/{grafana,loki,tempo,prometheus,alloy} — fora de /viralefy/, portanto
# sobrevivem ao viralefy-update destrutivo.
#
# Idempotente: rerun atualiza configs e units sem perder dados.
#
# Versões alvo (pinadas):
#   LOKI_VERSION    ex 3.3.2
#   TEMPO_VERSION   ex 2.7.1
# Grafana, Prometheus, Alloy, node_exporter vêm de apt (versões do repo).

: "${LOKI_VERSION:=3.3.2}"
: "${TEMPO_VERSION:=2.7.1}"

install_observability() {
  log "instalando stack de observabilidade (Grafana/Loki/Tempo/Prometheus/Alloy)"

  install_obs_apt_repos
  install_obs_packages
  install_obs_loki_binary
  install_obs_tempo_binary
  install_obs_users_dirs
  install_obs_configs
  install_obs_postgres_exporter
  install_obs_systemd
  start_obs_services
}

# ---- Repos apt: Grafana (Grafana + Alloy) ---- #
install_obs_apt_repos() {
  local keyring=/usr/share/keyrings/grafana-archive-keyring.gpg
  if [[ ! -f "$keyring" ]]; then
    log "adicionando repo apt da Grafana"
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://apt.grafana.com/gpg.key \
      | gpg --dearmor -o "$keyring"
  fi
  if [[ ! -f /etc/apt/sources.list.d/grafana.list ]]; then
    echo "deb [signed-by=$keyring] https://apt.grafana.com stable main" \
      > /etc/apt/sources.list.d/grafana.list
  fi
  apt-get update -y -qq
}

# ---- Pacotes apt (Grafana, Alloy, Prometheus, node_exporter) ---- #
install_obs_packages() {
  local pkgs=(grafana alloy prometheus prometheus-node-exporter prometheus-postgres-exporter)
  log "apt-get install -y ${pkgs[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" >/dev/null

  # Mascarar units default desses pacotes — usaremos as nossas hardened.
  # (Prometheus e node_exporter no Debian já vêm com unit padrão; substituiremos.)
  systemctl stop prometheus 2>/dev/null || true
  systemctl stop prometheus-node-exporter 2>/dev/null || true
  systemctl stop prometheus-postgres-exporter 2>/dev/null || true
  systemctl stop grafana-server 2>/dev/null || true
  systemctl stop alloy 2>/dev/null || true
  systemctl disable prometheus-node-exporter 2>/dev/null || true
  systemctl disable prometheus-postgres-exporter 2>/dev/null || true
}

# ---- Loki binary (upstream tarball) ---- #
install_obs_loki_binary() {
  if [[ -x /usr/local/bin/loki ]] && /usr/local/bin/loki --version 2>&1 | grep -q "$LOKI_VERSION"; then
    info "Loki $LOKI_VERSION já instalado"
    return
  fi
  log "baixando Loki $LOKI_VERSION"
  local arch tmp url
  arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64) arch="amd64" ;;
    arm64) arch="arm64" ;;
    *) fatal "arquitetura não suportada: $arch" ;;
  esac
  tmp="$(mktemp -d)"
  url="https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-${arch}.zip"
  curl -fsSL "$url" -o "$tmp/loki.zip"
  ( cd "$tmp" && unzip -q loki.zip )
  install -m 0755 -o root -g root "$tmp/loki-linux-${arch}" /usr/local/bin/loki
  rm -rf "$tmp"
  info "Loki $(/usr/local/bin/loki --version 2>&1 | head -1) instalado"
}

# ---- Tempo binary (upstream tarball) ---- #
install_obs_tempo_binary() {
  if [[ -x /usr/local/bin/tempo ]] && /usr/local/bin/tempo -version 2>&1 | grep -q "$TEMPO_VERSION"; then
    info "Tempo $TEMPO_VERSION já instalado"
    return
  fi
  log "baixando Tempo $TEMPO_VERSION"
  local arch tmp url
  arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64) arch="amd64" ;;
    arm64) arch="arm64" ;;
    *) fatal "arquitetura não suportada: $arch" ;;
  esac
  tmp="$(mktemp -d)"
  url="https://github.com/grafana/tempo/releases/download/v${TEMPO_VERSION}/tempo_${TEMPO_VERSION}_linux_${arch}.tar.gz"
  curl -fsSL "$url" -o "$tmp/tempo.tgz"
  ( cd "$tmp" && tar -xzf tempo.tgz tempo )
  install -m 0755 -o root -g root "$tmp/tempo" /usr/local/bin/tempo
  rm -rf "$tmp"
  info "Tempo $(/usr/local/bin/tempo -version 2>&1 | head -1) instalado"
}

# ---- Usuários (apt já cria grafana/prometheus/alloy; loki/tempo nós criamos) ---- #
install_obs_users_dirs() {
  for u in loki tempo; do
    if ! id "$u" >/dev/null 2>&1; then
      useradd --system --no-create-home --shell /usr/sbin/nologin --comment "Viralefy $u" "$u"
      info "usuário $u criado"
    fi
  done

  install -d -m 0750 -o grafana    -g grafana    /var/lib/grafana
  install -d -m 0750 -o loki       -g loki       /var/lib/loki
  install -d -m 0750 -o tempo      -g tempo      /var/lib/tempo
  # /var/lib/prometheus precisa ser 0755 (não 0750): viralefy-backup e
  # viralefy-backup-verify rodam como root MAS com CapabilityBoundingSet=""
  # (hardening systemd), perdendo CAP_DAC_READ_SEARCH. Sem +x no parent,
  # o stat de /var/lib/prometheus/node_exporter falha com EACCES. Dados do
  # TSDB ficam em subdirs com perms próprias, então abrir +x no parent é seguro.
  install -d -m 0755 -o prometheus -g prometheus /var/lib/prometheus
  # Textfile collector usado pelos timers de backup/verify/drill — root grava
  # métricas aqui via mv atômico. node_exporter lê com perms herdadas.
  install -d -m 0755 -o root       -g root       /var/lib/prometheus/node_exporter
  install -d -m 0750 -o alloy      -g alloy      /var/lib/alloy

  install -d -m 0755 -o root -g root /etc/grafana
  install -d -m 0755 -o root -g grafana /etc/grafana/provisioning
  install -d -m 0755 -o root -g grafana /etc/grafana/provisioning/datasources
  install -d -m 0755 -o root -g grafana /etc/grafana/provisioning/dashboards
  install -d -m 0755 -o root -g grafana /etc/grafana/dashboards
  install -d -m 0755 -o root -g root /etc/loki
  install -d -m 0755 -o root -g root /etc/tempo
  install -d -m 0755 -o root -g root /etc/prometheus
  install -d -m 0755 -o root -g root /etc/alloy

  install -d -m 0750 -o grafana -g grafana /var/log/grafana
}

# ---- Configs (do repo ops) ---- #
install_obs_configs() {
  local ops; ops="$(dir_of ops)"
  local cfg="$ops/config"

  install -m 0640 -o root -g grafana "$cfg/grafana.ini"                /etc/grafana/grafana.ini
  install -m 0644 -o root -g grafana "$cfg/grafana-datasources.yaml"   /etc/grafana/provisioning/datasources/viralefy.yaml
  install -m 0644 -o root -g grafana "$cfg/grafana-dashboards.yaml"    /etc/grafana/provisioning/dashboards/viralefy.yaml
  install -m 0644 -o root -g grafana "$cfg/dashboards/viralefy-api.json" /etc/grafana/dashboards/viralefy-api.json

  install -m 0644 -o root -g loki       "$cfg/loki.yaml"             /etc/loki/loki.yaml
  install -m 0644 -o root -g tempo      "$cfg/tempo.yaml"            /etc/tempo/tempo.yaml
  install -m 0644 -o root -g prometheus "$cfg/prometheus.yml"        /etc/prometheus/prometheus.yml
  install -m 0644 -o root -g prometheus "$cfg/alerts.yml"            /etc/prometheus/alerts.yml
  install -m 0644 -o root -g alloy      "$cfg/alloy/config.alloy"    /etc/alloy/config.alloy

  info "configs de observabilidade em /etc/{grafana,loki,tempo,prometheus,alloy}"
}

# ---- Postgres exporter (role + env + symlink binary) ---- #
# Idempotente: cria/atualiza role postgres_exporter no banco viralefy,
# materializa /etc/viralefy/postgres-exporter.env com DSN loopback, e
# expõe o binário em /usr/local/bin/postgres_exporter (symlink). A unit
# em si entra via install_obs_systemd; start vem em start_obs_services.
install_obs_postgres_exporter() {
  log "configurando prometheus-postgres-exporter"

  # Symlink pro caminho canônico usado pela unit /etc/systemd/.../postgres-exporter.service.
  if [[ -x /usr/bin/prometheus-postgres-exporter ]]; then
    ln -sf /usr/bin/prometheus-postgres-exporter /usr/local/bin/postgres_exporter
  else
    fatal "prometheus-postgres-exporter não encontrado em /usr/bin (apt install falhou?)"
  fi

  # Gera/preserva o secret. Se o env file já existe, reusa a senha pra
  # não invalidar uma role já em uso.
  local env_file=/etc/viralefy/postgres-exporter.env
  local pass
  install -d -m 0755 -o root -g root /etc/viralefy
  if [[ -f "$env_file" ]] && grep -q '^DATA_SOURCE_NAME=' "$env_file"; then
    pass="$(sed -n 's#^DATA_SOURCE_NAME=postgresql://postgres_exporter:\([^@]*\)@.*#\1#p' "$env_file")"
  fi
  if [[ -z "${pass:-}" ]]; then
    pass="$(openssl rand -hex 16)"
  fi

  # Cria/atualiza role read-only (pg_monitor) no banco viralefy.
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d viralefy <<-SQL
		DO \$\$
		BEGIN
		  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'postgres_exporter') THEN
		    CREATE USER postgres_exporter PASSWORD '${pass}';
		  ELSE
		    ALTER USER postgres_exporter PASSWORD '${pass}';
		  END IF;
		END
		\$\$;
		ALTER USER postgres_exporter SET SEARCH_PATH TO postgres_exporter,pg_catalog;
		GRANT pg_monitor TO postgres_exporter;
		GRANT CONNECT ON DATABASE viralefy TO postgres_exporter;
	SQL

  # Materializa env file (DSN loopback). chmod 600, owner postgres pois
  # a unit roda como user postgres e precisa ler o file via EnvironmentFile.
  umask 077
  cat > "$env_file" <<-EOF
		DATA_SOURCE_NAME=postgresql://postgres_exporter:${pass}@127.0.0.1:5432/viralefy?sslmode=disable
		PG_EXPORTER_DISABLE_DEFAULT_METRICS=false
		PG_EXPORTER_DISABLE_SETTINGS_METRICS=false
	EOF
  chown postgres:postgres "$env_file"
  chmod 0600 "$env_file"
  info "postgres-exporter env em $env_file (modo 600, owner postgres)"
}

# ---- Systemd units (hardened, do repo ops) ---- #
install_obs_systemd() {
  local ops; ops="$(dir_of ops)"
  local src="$ops/systemd"
  for unit in grafana-server loki tempo prometheus alloy node-exporter postgres-exporter; do
    install -m 0644 -o root -g root "$src/$unit.service" "/etc/systemd/system/$unit.service"
  done

  # Drop-in pro Grafana receber a senha admin via env.
  install -d -m 0755 -o root -g root /etc/systemd/system/grafana-server.service.d
  cat > /etc/systemd/system/grafana-server.service.d/admin-password.conf <<-EOF
		[Service]
		Environment=GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
EOF
  chmod 0640 /etc/systemd/system/grafana-server.service.d/admin-password.conf

  systemctl daemon-reload
  info "units de observabilidade instaladas"
}

# ---- Enable + start + healthcheck ---- #
start_obs_services() {
  log "habilitando e subindo serviços de observabilidade"
  systemctl enable --now node-exporter loki tempo prometheus alloy grafana-server postgres-exporter

  # Healthcheck rápido: cada porta loopback deve responder em até 30s.
  local checks=(
    "Loki|3100|/ready"
    "Tempo|3200|/ready"
    "Prometheus|9090|/-/ready"
    "Grafana|3030|/api/health"
    "Alloy|12345|/-/ready"
    "node_exporter|9100|/metrics"
    "postgres-exporter|9187|/metrics"
  )
  local entry name port path
  for entry in "${checks[@]}"; do
    name="${entry%%|*}"
    port="$(echo "$entry" | cut -d'|' -f2)"
    path="${entry##*|}"
    local i ok=0
    for i in $(seq 1 30); do
      if curl -fsS "http://127.0.0.1:$port$path" >/dev/null 2>&1; then
        info "$name :$port saudável (${i}s)"
        ok=1; break
      fi
      sleep 1
    done
    if [[ "$ok" == 0 ]]; then
      warn "$name :$port não respondeu em 30s — verifique journalctl -u $(echo "$name" | tr '[:upper:]' '[:lower:]')"
    fi
  done

  info "obs stack pronto — Grafana em https://${DOMAIN_OBS} (admin / GRAFANA_ADMIN_PASSWORD)"
}
