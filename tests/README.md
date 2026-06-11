# `viralefy_ops/tests/` — Test Kit do Sistema Vivo

CLI único `viralefy test` (alias systêmico em `/usr/local/sbin/viralefy-test`)
roda a malha de testes "do sistema vivo" descrita em §22 das diretrizes.
Cada subdiretório é uma **categoria** (modo), e cada `*.sh` dentro é um
script standalone com PASS/FAIL próprio.

## Quickstart

```bash
viralefy test                  # default → smoke
viralefy test smoke            # ~10s
viralefy test all              # tudo exceto chaos+unit
viralefy test full             # all + chaos + unit
viralefy test smoke --verbose  # ecoa stdout/stderr dos scripts
viralefy test smoke --quiet    # só linha final
viralefy test smoke --fail-fast
```

Logs em `/var/log/viralefy/test-YYYY-MM-DD-HHMMSS-PID/`:

- `summary.txt` — `PASS|FAIL category/name`, uma linha por script
- `summary.json` — contrato §22.2 pra dashboards/CI
- `run-totals.txt` — 8 linhas chave=valor (mode, started, …, exit)
- `<category>-<name>.log` — stdout/stderr de cada script

## Modos × scripts × duração × CI hooks

| Modo | Scripts | Duração | CI hook | Status atual |
|---|---|---|---|---|
| `smoke` | services-health, api-public, auth-gates, cors-preflight, checkout-e2e, observability-stack, waf-block-attacks, jwks-public, tls-grade | ~10s | pré + pós deploy (`viralefy-update`); PR check; external GH cron 15min | **9/9 implementados** |
| `integration` | login real, CRUD admin, upload, password reset | ~3min | pré-deploy | placeholder (agent N) |
| `security` | auth bypass, headers, rate-limit, bcrypt cost, JWT alg | ~1min | PR check | placeholder (agent L) |
| `pentest` | OWASP Top 10 + extensão (~25 scripts) | ~3min | nightly | placeholder (agent K) |
| `authz` | cross-tenant-idor, rbac-negative, privilege-escalation, permission-boundary, tenant-isolation | ~1min | PR check | placeholder (agent M) |
| `hardening` | tls-config, headers-full, cookies, cors, exposed-paths, default-creds | ~1min | PR check | placeholder (agent L) |
| `chaos` | input-fuzz, property-based, service-kill (gated), db-disconnect, concurrent-load | ~5min | nightly | placeholder (agent N) |
| `simulated` | engine Python: rotas × personas × injections | ~5min | nightly | placeholder (agent O) |
| `unit` | `go test` / `npm test` por serviço | 5-15min | PR (in-repo) + nightly aggregate | delega para runners nativos |

**Seeds (§22.5)**:

```bash
viralefy test seed-superadmin  # idempotente, INSERT ... ON CONFLICT DO UPDATE
viralefy test clean-seeds      # remove *@viralefy.test (cleanup explícito)
```

## Helpers de `lib.sh`

Toda assertion mora em `lib.sh` — fonte única. Scripts em `tests/<mode>/`
fazem `source` dele logo no início:

```bash
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$_DIR/lib.sh"
```

**Lifecycle**:

- `test_section "<Categoria> · <Nome>"` — banner ASCII no topo
- `test_pass "<msg>"` — incrementa `TEST_PASS`
- `test_fail "<msg>" "<body_truncado>"` — incrementa `TEST_FAIL` + seta `TEST_EXIT_CODE=1`
- `test_skip "<msg>" "<reason>"` — incrementa `TEST_SKIP`
- `test_summary "<categoria>/<nome>"` — totals + banner ENORME vermelho na falha

**HTTP**:

- `http_call <method> <url> [body] [extra_curl_args...]` → popula `HTTP_CODE`, `HTTP_BODY`, `HTTP_HEADERS`
- `assert_http_status "<desc>" "<code>" <method> <url> [body]`
- `assert_http_in "<desc>" "<code|code|code>" <method> <url> [body]`
- `assert_json_field "<jq_query>" "<expected>" [<msg>]`
- `assert_header_present "<name>" [<msg>]` / `assert_header_absent`
- `assert_no_pii "<text>" [<ctx>]` — regex CPF + e-mail real (whitelist `@viralefy.test`)

**Bases (overridable via env)**:

- `api_base` / `dispatcher_base` — `VIRALEFY_TEST_API_BASE` (default `http://127.0.0.1:8090`)
- `front_base` — `VIRALEFY_TEST_FRONT_BASE` (default `http://127.0.0.1:3000`)
- `admin_base` — `VIRALEFY_TEST_ADMIN_BASE` (default `http://127.0.0.1:3001`)
- `core_base` / `auth_base` / `payments_base` / `sender_base`
- `prom_base` / `grafana_base` / `loki_base`

Quando rodando contra prod externo: `export VIRALEFY_TEST_API_BASE=https://api.viralefy.com`.

## Convenção de script

Skeleton obrigatório (§22.4):

```bash
#!/usr/bin/env bash
# <Categoria> · <Nome curto>
# Descrição clara do que cobre e o esperado.
set -uo pipefail
_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$_DIR/lib.sh"

test_section "<Categoria> · <Nome>"
API="$(api_base)"

assert_http_in "<desc>" "200|401" GET "$API/v1/<rota>"

test_summary "<categoria>/<nome>"
exit $TEST_EXIT_CODE
```

**MUST**:

- Cada script é executável standalone: `bash tests/smoke/auth-gates.sh` deve rodar e sair `0/1`.
- Test users no padrão `*@viralefy.test` (cleanup hourly via `viralefy-test-cleanup.timer`).
- Fail-soft em sub-checks (não aborta script inteiro por 1 caso quando os demais são independentes).
- Sem deps externas além de `curl + jq + python3` (em todos hosts Debian).
- Cores e formatação só se TTY (`-t 1`).

## CI integration

- **Pós-deploy** (`viralefy-update`): roda `viralefy test smoke` no fim. Falha avisa "considere rollback".
- **External smoke** (GH Actions cron 15min): `viralefy_archive/.github/workflows/external-smoke.yml`. Roda contra `https://api.viralefy.com` a partir de runner externo, reusando os mesmos scripts via `VIRALEFY_TEST_API_BASE`.
- **PR check** (futuro): `viralefy test smoke + security + authz + hardening` (~3min total).
- **Nightly** (futuro): `viralefy test full` (inclui chaos + unit).

## Schema `summary.json` (§22.2) — **CONTRATO**

```json
{
  "started_at": "2026-06-11T04:24:30Z",
  "finished_at": "2026-06-11T04:24:32Z",
  "duration_seconds": 2,
  "mode": "smoke",
  "log_dir": "/var/log/viralefy/test-2026-06-11-042430-542481",
  "scripts": [
    {"category": "smoke", "name": "services-health", "status": "pass"},
    {"category": "smoke", "name": "api-public",      "status": "pass"}
  ],
  "totals": {"pass": 9, "fail": 0, "scripts": 9, "exit_code": 0}
}
```

Os campos `mode`, `scripts[]` e `totals` são imutáveis — dashboards e
alertas dependem deles. Campos novos podem ser adicionados sem quebrar
parsers existentes.

## Install

Em prod (cobertos pelo `viralefy-update`):

```bash
scp viralefy_ops/bin/viralefy-test root@host:/usr/local/sbin/
ssh root@host 'chmod 755 /usr/local/sbin/viralefy-test'
scp -r viralefy_ops/tests/ root@host:/opt/viralefy-tests/
ssh root@host 'viralefy-test smoke'
```

O CLI procura `tests/` em ordem:

1. `$VIRALEFY_TESTS_DIR` (override)
2. `/opt/viralefy-tests`
3. `/viralefy/ops/tests`
4. `<bin_dir>/../tests` (dev/CI)
