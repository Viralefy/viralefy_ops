# viralefy_ops

Instalação e operação do stack Viralefy. Instala em `/viralefy/{api,front,backoffice,ops,archive}`, sobe via **systemd** com **isolamento por usuário**, expõe via **Caddy** com **TLS automático**, mantém segredos em `/etc/viralefy/.env` (sobrevive a updates) e usa **Resend** pra e-mail.

## TL;DR

```bash
# Instalação do zero numa máquina Debian/Ubuntu, com domínios reais:
curl -fsSL https://raw.githubusercontent.com/Viralefy/viralefy_ops/main/bin/bootstrap.sh \
  | sudo RESEND_API_KEY=re_xxx \
         DOMAIN_FRONT=viralefy.com \
         DOMAIN_BACKOFFICE=admin.viralefy.com \
         DOMAIN_API=api.viralefy.com \
         CADDY_EMAIL=ops@viralefy.com \
         bash

# Atualização destrutiva (rm -rf + reclone + rebuild):
sudo viralefy-update

# Status:
viralefy-status

# Logs:
viralefy-logs api -n 200
sudo viralefy-logs -f                # follow de tudo (incl. Caddy)
viralefy-logs caddy -n 100
```

## O que o installer faz

| Etapa | Módulo | O que faz |
|---|---|---|
| 1 | `00-prereqs.sh` | Instala Go 1.26, Node 24, PostgreSQL 16, **Caddy** (repo Cloudsmith), git, curl, build tools |
| 2 | `10-users.sh` | Cria grupo `viralefy` + usuários `viralefy-api`, `viralefy-front`, `viralefy-backoffice` (system, sem shell) |
| 3 | `30-secrets.sh` | Gera/preserva `/etc/viralefy/.env` (perms 0640, root:viralefy). Domínios + `RESEND_API_KEY` via env var ou prompt |
| 4 | `20-postgres.sh` | Cria role `viralefy` (senha do `.env`) + DB `viralefy` + `pg_hba` p/ localhost SCRAM |
| 5 | `40-clone.sh` | Clona `viralefy_{api,front,backoffice,archive,ops}` em `/viralefy/<pkg>` com owner do serviço |
| 6 | `50-build.sh` | `go build` (API) e `npm ci && npm run build` (front/backoffice) rodando como o user do serviço |
| 7 | `60-systemd.sh` | Instala `.service` em `/etc/systemd/system/` + CLIs em `/usr/local/sbin/` |
| 8 | `35-caddy.sh` | Escreve `/etc/caddy/Caddyfile` + `/etc/caddy/viralefy.env` (drop-in) + `caddy validate` + reload |
| 9 | `70-start.sh` | `systemctl enable --now` + espera healthcheck |

## Layout final

```
/viralefy/                       # root da instalação (root:root, 0755)
├── api/                         # viralefy-api:viralefy
│   └── bin/viralefy-api         # binário Go
├── front/                       # viralefy-front:viralefy (Next.js)
├── backoffice/                  # viralefy-backoffice:viralefy
├── ops/                         # viralefy_ops (este repo)
└── archive/                     # docs/diretrizes (read-only, root:root)

/etc/viralefy/                   # 0750, root:viralefy
└── .env                         # 0640, root:viralefy — sobrevive a updates

/etc/systemd/system/             # units hardened
├── viralefy-api.service
├── viralefy-front.service
└── viralefy-backoffice.service

/usr/local/sbin/                 # CLIs (sobrevivem ao rm -rf /viralefy/ops)
├── viralefy-update
├── viralefy-status
└── viralefy-logs
```

## Update é destrutivo (de propósito)

`viralefy-update` faz literalmente:

1. `systemctl stop viralefy-{api,front,backoffice}`
2. `rm -rf /viralefy/{api,front,backoffice,ops,archive}`
3. Clona `viralefy_ops` num temp dir em `/tmp/`
4. `exec` no installer dali → faz a instalação inteira do zero

Sobrevive porque o script se copia pro `/tmp` antes de apagar o próprio `/viralefy/ops`. **/etc/viralefy/.env** e o **banco PostgreSQL** ficam intocados — segredos e dados de cliente seguem.

## Segurança

- **Isolamento por usuário**: cada serviço roda como usuário system próprio sem shell. Permissões nos diretórios de pacote bloqueiam acesso cruzado.
- **Grupo `viralefy`** dá acesso somente-leitura ao `/etc/viralefy/.env` (perms 0640) só para os 3 usuários de serviço.
- **systemd hardened**: `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `PrivateDevices`, `RestrictNamespaces`, `SystemCallFilter=@system-service`, `CapabilityBoundingSet=`, `ReadWritePaths=/viralefy/<pkg>` (cada serviço só escreve no próprio dir), `MemoryDenyWriteExecute` na API Go (Node faz JIT então não rola).
- **PostgreSQL** com role dedicada, sem superuser, `pg_hba` específico para `viralefy@127.0.0.1` via SCRAM-SHA-256.
- **`JWT_SECRET`** gerado com 64 bytes do `/dev/urandom` na primeira instalação.
- **Resend API key** nunca vai pro repo — só em `/etc/viralefy/.env` ou via env var no install.

## Variáveis de ambiente do install

| Var | Default | Uso |
|---|---|---|
| `RESEND_API_KEY` | (pergunta interativo) | Resend HTTP API |
| `DOMAIN_FRONT` | `localhost` | Domínio público da loja (Caddy emite TLS) |
| `DOMAIN_BACKOFFICE` | `admin.localhost` | Domínio do backoffice |
| `DOMAIN_API` | `api.localhost` | Domínio da API |
| `CADDY_EMAIL` | (vazio) | E-mail registrado no Let's Encrypt |
| `BIND_HOST` | `127.0.0.1` | Onde apps escutam (Caddy proxy via loopback) |
| `VIRALEFY_GH_ORG` | `Viralefy` | Org no GitHub |
| `VIRALEFY_REPO_BASE` | `https://github.com/Viralefy` | Override completo da base URL |
| `VIRALEFY_BRANCH` | `main` | Branch a clonar dos 5 repos |

`CORS_ORIGINS`, `NEXT_PUBLIC_API_URL` e `NEXT_PUBLIC_SITE_URL` são derivadas dos domínios — não precisam ser setadas à mão.

## HTTPS via Caddy

Caddy é a única superfície pública. Os apps escutam só em **127.0.0.1**:
- `viralefy-api.service` → API Go em `127.0.0.1:8080` (controlado por `BIND_HOST` em `.env`)
- `viralefy-front.service` → Next.js em `127.0.0.1:3000` (`-H 127.0.0.1` na unit)
- `viralefy-backoffice.service` → Next.js em `127.0.0.1:3001` (`-H 127.0.0.1` na unit)

O Caddyfile (em `/viralefy/ops/config/Caddyfile`, instalado em `/etc/caddy/Caddyfile`) define três blocos:
- `{$DOMAIN_FRONT}` → `127.0.0.1:3000` (HSTS, Permissions-Policy, COOP)
- `{$DOMAIN_BACKOFFICE}` → `127.0.0.1:3001` (HSTS + `X-Frame-Options DENY` + `CSP frame-ancestors 'none'`)
- `{$DOMAIN_API}` → `127.0.0.1:8080` (HSTS; CORS continua na API)

Variáveis vêm de `/etc/caddy/viralefy.env` (drop-in `EnvironmentFile`), perms 0640, root:caddy. Esse arquivo só contém `DOMAIN_*` e `CADDY_EMAIL` — Caddy **não** vê `DATABASE_URL`, `RESEND_API_KEY` etc.

**Domínio real**: Caddy emite via Let's Encrypt automaticamente. **localhost / *.localhost**: Caddy usa CA local (instalado em `/etc/ssl/caddy/`) — para confiar no certificado, rode `sudo caddy trust`.

## CLIs instaladas em `/usr/local/sbin/`

| Comando | O que faz |
|---|---|
| `viralefy-install` | Bootstrap completo (rodado pelo `bootstrap.sh`). Idempotente. |
| `viralefy-update` | Destrutivo. `--yes` pra pular confirmação. |
| `viralefy-status` | Resumo: systemd, portas, healthchecks, PG |
| `viralefy-logs [api\|front\|backoffice\|all] [-f] [-n N]` | Tail via `journalctl` |

## Diretrizes

Segue [viralefy_archive/diretrizes.md](https://github.com/Viralefy/viralefy_archive/blob/master/diretrizes.md). Mudanças destrutivas neste repo exigem ADR.

## Pré-requisitos do host

- Debian 12 ou Ubuntu 22.04/24.04 (ou Linux Mint base Ubuntu)
- Acesso root via `sudo`
- Conexão de saída: github.com, go.dev, deb.nodesource.com, dl.cloudsmith.io, api.resend.com, acme-v02.api.letsencrypt.org
- Portas livres no host: **80** e **443** (Caddy público), 5432 (PostgreSQL local)
- As portas internas 8080/3000/3001 ficam só em 127.0.0.1 — não precisam estar abertas no firewall
- Para domínios reais: registros DNS A/AAAA dos 3 subdomínios apontando para o IP do servidor (Let's Encrypt usa HTTP-01)
