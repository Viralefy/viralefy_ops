-- tests/seeds/test-viewer.sql
--
-- Persona "viewer" — read-only. Em seed.go::seedRoles:
--   plans:read, gateways:read, currencies:read, orders:read,
--   tickets:read, reviews:read.
-- Nenhum :write, nenhum :moderate, nenhum admins:manage.
--
-- Senha test-only: SimTest!Viewer123 (bcrypt cost 12).

INSERT INTO admins (id, email, password_hash, name, role, requires_2fa)
VALUES (
    'aaaaaaaa-0000-4000-8000-000000000003',
    'viewer@viralefy.test',
    '$2b$12$pALE53S9QG5zONaE3iIQYuSBOGmRZ9wzUFQKq/k1yczT8UNDTxrgq',
    'Viewer Test',
    'viewer',
    false
)
ON CONFLICT (email) DO UPDATE SET
    role          = EXCLUDED.role,
    name          = EXCLUDED.name,
    requires_2fa  = EXCLUDED.requires_2fa,
    password_hash = EXCLUDED.password_hash;
