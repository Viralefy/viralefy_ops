-- tests/seeds/test-superadmin.sql
--
-- Persona "superadmin" pra suite tests/authz/ e tests/integration/.
-- Idempotente: ON CONFLICT DO UPDATE garante que re-rodar não duplica
-- e ressincroniza role/name/requires_2fa caso alguém tenha mexido manualmente.
--
-- Login real bloqueia (requires_2fa=true por default em prod via 036_twofa).
-- Scripts authz mintam token RS256 diretamente via /etc/viralefy/jwt-rs256.pem
-- (ver tests/lib-authz.sh::mint_admin_token), mas deixamos requires_2fa=false
-- nesses test admins pra eventualmente permitir login real em smoke E2E.
--
-- Senha test-only: SimTest!Super123 — prefixo SimTest! é blacklisted no
-- validador de senha em prod (futuro: PasswordPolicy.reject_test_prefix).
-- Hash bcrypt cost 12 pré-computado.
--
-- Cleanup: viralefy-test clean-seeds → DELETE WHERE email LIKE '%@viralefy.test'.

INSERT INTO admins (id, email, password_hash, name, role, requires_2fa)
VALUES (
    'aaaaaaaa-0000-4000-8000-000000000001',
    'superadmin@viralefy.test',
    '$2b$12$pALE53S9QG5zONaE3iIQYuSBOGmRZ9wzUFQKq/k1yczT8UNDTxrgq',
    'Super Admin Test',
    'superadmin',
    false
)
ON CONFLICT (email) DO UPDATE SET
    role          = EXCLUDED.role,
    name          = EXCLUDED.name,
    requires_2fa  = EXCLUDED.requires_2fa,
    password_hash = EXCLUDED.password_hash;
