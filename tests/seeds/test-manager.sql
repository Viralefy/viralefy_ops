-- tests/seeds/test-manager.sql
--
-- Persona "manager" — subset de permissões definido em seed.go::seedRoles:
--   plans:*, gateways:*, currencies:*, orders:read,
--   tickets:*, reviews:read, reviews:moderate.
-- Em particular, manager NÃO tem admins:manage (não pode CRUD admins,
-- não pode disable 2FA de outros, não tem AB/vendors).
--
-- Senha test-only: SimTest!Manager123 (bcrypt cost 12).
-- Login real bloqueado por 2FA em prod; scripts mintam token RS256.

INSERT INTO admins (id, email, password_hash, name, role, requires_2fa)
VALUES (
    'aaaaaaaa-0000-4000-8000-000000000002',
    'manager@viralefy.test',
    '$2b$12$pALE53S9QG5zONaE3iIQYuSBOGmRZ9wzUFQKq/k1yczT8UNDTxrgq',
    'Manager Test',
    'manager',
    false
)
ON CONFLICT (email) DO UPDATE SET
    role          = EXCLUDED.role,
    name          = EXCLUDED.name,
    requires_2fa  = EXCLUDED.requires_2fa,
    password_hash = EXCLUDED.password_hash;
