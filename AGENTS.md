# viralefy_ops — Instruções para Agentes

## Diretrizes obrigatórias

Antes de qualquer mudança neste repo, leia [viralefy_archive/diretrizes.md](https://github.com/Viralefy/viralefy_archive/blob/master/diretrizes.md). Mudanças que afetam **instalação destrutiva** ou **modelo de segurança** exigem ADR.

## Princípios deste repositório

1. **Instalação destrutiva**: `viralefy-update` apaga `/viralefy/{api,front,backoffice,ops,archive}` e reconstrói. Tudo persistente (segredos, banco) vive **fora** de `/viralefy/`.
2. **Idempotência**: rodar o installer duas vezes não quebra nada. Cada módulo verifica antes de criar.
3. **Isolamento por usuário**: um usuário systemd por serviço. Sem shell. Sem write fora do próprio dir.
4. **Segredos só em `/etc/viralefy/.env`** (0640, root:viralefy). Nunca commitados.
5. **Bash + shellcheck**: scripts shell padrão, sem dependências exóticas. `set -euo pipefail` em todo lugar.

## Estrutura

```
bin/
  bootstrap.sh         entry point para máquina nova
  viralefy-install     instalador principal (modular)
  viralefy-update      atualizador destrutivo
  viralefy-status      diagnóstico rápido
  viralefy-logs        wrapper journalctl
installer/
  lib.sh               helpers + constantes (ROOT_DIR, ORG, PACKAGES, ...)
  00-prereqs.sh        deps de sistema (Go/Node/PG/git)
  10-users.sh          grupo + usuários system
  20-postgres.sh       role + db + pg_hba
  30-secrets.sh        /etc/viralefy/.env (gen ou preserva)
  40-clone.sh          clone dos pacotes
  50-build.sh          go build + npm ci/build
  60-systemd.sh        instala units + CLIs
  70-start.sh          enable+start + wait healthy
systemd/
  viralefy-*.service   units hardened
config/
  env.template         template de referência
```

## Adicionando um novo pacote

1. Adicione o repo no `PACKAGES` em `installer/lib.sh` e no map `REPO_OF`.
2. Crie a unit `systemd/viralefy-<pkg>.service` seguindo o padrão hardened das outras.
3. Adicione `viralefy-<pkg>` à lista de units em `60-systemd.sh` (loop de install).
4. Acrescente a função `build_<pkg>` em `50-build.sh` (e chame em `install_build`).
5. Atualize `viralefy-status` e `viralefy-logs` para incluir o novo serviço.

## Testando local

A instalação real exige uma VM/container limpa (Debian/Ubuntu). Para iterar nos scripts use:

```bash
# Validação estática:
make lint                    # shellcheck em todos os scripts

# Smoke (numa VM/container):
sudo VIRALEFY_BRANCH=feat/xxx ./bin/viralefy-install
```
