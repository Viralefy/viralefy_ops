# tests/seeds/ — Personas de teste

SQL idempotentes consumidos pela suíte `tests/authz/` (e por `tests/integration/`
no futuro). Cobertura mínima §22.5 das diretrizes: superadmin + manager + viewer
+ 3 normal users (A/B/C) com orders.

**Single-tenant**: Viralefy é marketplace, não SaaS multi-tenant. Não há seed
`tenant_admin_A/B` (§22.5 fala em multi-tenancy — não se aplica). Isolation
cross-user (BOLA) cobre o equivalente.

## Arquivos

| Arquivo | Persona | Role/Tipo | Email |
|---|---|---|---|
| `test-superadmin.sql` | superadmin | `admins.role='superadmin'` | `superadmin@viralefy.test` |
| `test-manager.sql`    | manager    | `admins.role='manager'`    | `manager@viralefy.test`    |
| `test-viewer.sql`     | viewer     | `admins.role='viewer'`     | `viewer@viralefy.test`     |
| `test-users.sql`      | user_a/b/c | normal users + profiles    | `user-{a,b,c}@viralefy.test` |
| `test-orders.sql`     | —          | orders pros 3 users        | (paid×2 pra A, pending×1 pra B, nada pra C) |

## Comandos

```bash
viralefy test seed-superadmin   # roda test-superadmin.sql
viralefy test seed-manager      # roda test-manager.sql
viralefy test seed-viewer       # roda test-viewer.sql
viralefy test seed-users        # roda test-users.sql
viralefy test seed-orders       # roda test-orders.sql (depende de test-users)
viralefy test seed-all          # roda todos na ordem certa
viralefy test clean-seeds       # DELETE seguro WHERE email LIKE '%@viralefy.test'
```

Idempotente — re-rodar não duplica nem corrompe.

## Senhas test-only

Prefixo **`SimTest!`** sinaliza "senha de teste, NUNCA usar em produção":

| Persona | Senha |
|---|---|
| superadmin | `SimTest!Super123`   |
| manager    | `SimTest!Manager123` |
| viewer     | `SimTest!Viewer123`  |
| user_a/b/c | `SimTest!User123`    |

Hash bcrypt cost 12 pré-computado (idempotência exige hash literal no SQL,
não gerado por random salt cada run).

**TODO (validador de senha em prod)**: rejeitar `SimTest!*` no fluxo de
admin signup / password reset — defense-in-depth caso alguém tente
promover uma persona de teste a admin real.

## RBAC esperado (de `viralefy_core/internal/infrastructure/persistence/postgres/seed.go`)

| role | permissões |
|---|---|
| `superadmin` | TUDO (bypass em `Principal.Can`) |
| `manager` | `plans:*`, `gateways:*`, `currencies:*`, `orders:read`, `tickets:*`, `reviews:read,moderate` |
| `support` | `plans:read`, `gateways:read`, `currencies:read`, `orders:read`, `tickets:*`, `reviews:read` |
| `viewer`  | só `*:read` |

Manager **NÃO** tem `admins:manage` — privilege-escalation.sh testa exatamente
isso (manager tentando criar/promover admin).

## Cleanup

`viralefy test clean-seeds` apaga:

```sql
DELETE FROM orders          WHERE user_id IN (SELECT id FROM users  WHERE email LIKE '%@viralefy.test');
DELETE FROM profiles        WHERE user_id IN (SELECT id FROM users  WHERE email LIKE '%@viralefy.test');
DELETE FROM users           WHERE email LIKE '%@viralefy.test';
DELETE FROM admins          WHERE email LIKE '%@viralefy.test';
DELETE FROM revoked_jtis    WHERE revoked_reason LIKE 'authz-test-%';
```

Ordem importa (FKs). Em prod, rodar pós-incidente OU manualmente — o
runner `viralefy-test` NÃO faz cleanup automático (deixa lixo pra
inspeção, alinhado com §22.5).
