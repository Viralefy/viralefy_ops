-- tests/seeds/test-users.sql
--
-- 3 personas "normal user" pra cobrir BOLA cross-user (User A não vê dados
-- de User B) e cenários de isolation em rotas /v1/me/*.
--
-- IDs fixos (UUID-shaped TEXT) pra os scripts authz referenciarem por
-- substituição direta sem precisar SELECT.
--
-- Senha test-only: SimTest!User123 (bcrypt cost 12). Login real funciona
-- — user 2FA é opt-in, não exigido (admins é que têm requires_2fa default
-- true). Os scripts user-bola.sh / cross-user-write.sh fazem login real
-- via POST /v1/auth/user/login e usam o JWT (`role: "user"`) retornado.
--
-- `instagram` é NOT NULL em users (schema 001_init); colocamos um handle
-- por persona alinhado com o e-mail.

INSERT INTO users (id, email, name, instagram, password_hash)
VALUES
    (
        'bbbbbbbb-0000-4000-8000-00000000000a',
        'user-a@viralefy.test',
        'User A Test',
        'user_a_test',
        '$2b$12$0gtciEjV4tFkhvtMayWES.7i2fFMZzbYC5FmYxBQ1LzHePN.n9l8a'
    ),
    (
        'bbbbbbbb-0000-4000-8000-00000000000b',
        'user-b@viralefy.test',
        'User B Test',
        'user_b_test',
        '$2b$12$0gtciEjV4tFkhvtMayWES.7i2fFMZzbYC5FmYxBQ1LzHePN.n9l8a'
    ),
    (
        'bbbbbbbb-0000-4000-8000-00000000000c',
        'user-c@viralefy.test',
        'User C Test',
        'user_c_test',
        '$2b$12$0gtciEjV4tFkhvtMayWES.7i2fFMZzbYC5FmYxBQ1LzHePN.n9l8a'
    )
ON CONFLICT (email) DO UPDATE SET
    name          = EXCLUDED.name,
    instagram     = EXCLUDED.instagram,
    password_hash = EXCLUDED.password_hash;

-- Perfis sociais pra cobrir GET/DELETE em /v1/me/profiles/{id} entre A e B.
INSERT INTO profiles (id, user_id, platform, handle, display_name, verified)
VALUES
    ('cccccccc-0000-4000-8000-00000000000a', 'bbbbbbbb-0000-4000-8000-00000000000a',
     'instagram', 'user_a_handle', 'A handle', false),
    ('cccccccc-0000-4000-8000-00000000000b', 'bbbbbbbb-0000-4000-8000-00000000000b',
     'instagram', 'user_b_handle', 'B handle', false)
ON CONFLICT (id) DO UPDATE SET
    handle       = EXCLUDED.handle,
    display_name = EXCLUDED.display_name;
