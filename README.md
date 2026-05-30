# viralefy_ops

Instalação e operação do stack Viralefy. Instala em `/viralefy/{api,front,backoffice,ops,archive}`, sobe via **systemd** com **isolamento por usuário**, mantém segredos em `/etc/viralefy/.env` (sobrevive a updates) e usa **Resend** pra e-mail.

## TL;DR

```bash
# Instalação do zero numa máquina Debian/Ubuntu:
curl -fsSL https://raw.githubusercontent.com/Viralefy/viralefy_ops/main/bin/bootstrap.sh \
  | sudo RESEND_API_KEY=re_xxx bash

# Atualização destrutiva (rm -rf + reclone + rebuild):
sudo viralefy-update

# Status:
viralefy-status

# Logs:
viralefy-logs api -n 200
sudo viralefy-logs -f                # follow de todos
```

## O que o installer faz

| Etapa | Módulo | O que faz |
|---|---|---|
| 1 | `00-prereqs.sh` | Instala Go 1.26, Node 24, PostgreSQL 16, git, curl, build tools |
| 2 | `10-users.sh` | Cria grupo `viralefy` + usuários `viralefy-api`, `viralefy-front`, `viralefy-backoffice` (system, sem shell) |
| 3 | `30-secrets.sh` | Gera/preserva `/etc/viralefy/.env` (perms 0640, root:viralefy). Pergunta `RESEND_API_KEY` se não vier por env |
| 4 | `20-postgres.sh` | Cria role `viralefy` (senha do `.env`) + DB `viralefy` + `pg_hba` p/ localhost SCRAM |
| 5 | `40-clone.sh` | Clona `viralefy_{api,front,backoffice,archive,ops}` em `/viralefy/<pkg>` com owner do serviço |
| 6 | `50-build.sh` | `go build` (API) e `npm ci && npm run build` (front/backoffice) rodando como o user do serviço |
| 7 | `60-systemd.sh` | Instala `.service` em `/etc/systemd/system/` + CLIs em `/usr/local/sbin/` |
| 8 | `70-start.sh` | `systemctl enable --now` + espera healthcheck |

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
| `VIRALEFY_GH_ORG` | `Viralefy` | Org no GitHub |
| `VIRALEFY_REPO_BASE` | `https://github.com/Viralefy` | Override completo da base URL |
| `VIRALEFY_BRANCH` | `main` | Branch a clonar dos 5 repos |

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
- Conexão de saída: github.com, go.dev, deb.nodesource.com, api.resend.com
- Portas livres: 8080 (API), 3000 (Front), 3001 (Backoffice), 5432 (PostgreSQL, localhost only)
