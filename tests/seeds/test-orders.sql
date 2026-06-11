-- tests/seeds/test-orders.sql
--
-- Orders pra os 3 normal users de test-users.sql:
--   user_a → 2 orders paid
--   user_b → 1 order pending
--   user_c → sem orders
--
-- IDs com prefixo dddddddd-* pra fácil cleanup (clean-seeds limpa por
-- email do user, mas os orders caem via DELETE em cascata através do
-- DELETE explícito do clean-seeds quando necessário).
--
-- O plan_id é escolhido dinamicamente: pegamos o plano ativo de menor
-- sort_order. Isso evita seed quebrar caso o catálogo seja recriado.
-- Se não houver plano ativo, ROLLBACK silencioso (SELECT vazio → INSERT
-- skip via WHERE EXISTS subquery).
--
-- amount_cents = 100 (R$ 1,00) — token-only pra evitar números enormes nos
-- dashboards de prod ao mexer com seeds.

DO $$
DECLARE
    v_plan_id TEXT;
BEGIN
    SELECT id INTO v_plan_id
    FROM plans
    WHERE active = true
    ORDER BY sort_order ASC, created_at ASC
    LIMIT 1;

    IF v_plan_id IS NULL THEN
        RAISE NOTICE 'test-orders.sql: nenhum plano ativo, pulando seed de orders';
        RETURN;
    END IF;

    -- User A: 2 paid orders
    INSERT INTO orders (id, user_id, plan_id, status, amount_cents, currency)
    VALUES
        ('dddddddd-0000-4000-8000-00000000a001',
         'bbbbbbbb-0000-4000-8000-00000000000a', v_plan_id, 'paid', 100, 'BRL'),
        ('dddddddd-0000-4000-8000-00000000a002',
         'bbbbbbbb-0000-4000-8000-00000000000a', v_plan_id, 'paid', 100, 'BRL')
    ON CONFLICT (id) DO UPDATE SET
        status       = EXCLUDED.status,
        amount_cents = EXCLUDED.amount_cents;

    -- User B: 1 pending order — usado por scripts cross-user pra tentar
    -- ler/mutar order de B logado como A.
    INSERT INTO orders (id, user_id, plan_id, status, amount_cents, currency)
    VALUES
        ('dddddddd-0000-4000-8000-00000000b001',
         'bbbbbbbb-0000-4000-8000-00000000000b', v_plan_id, 'pending', 100, 'BRL')
    ON CONFLICT (id) DO UPDATE SET
        status       = EXCLUDED.status,
        amount_cents = EXCLUDED.amount_cents;

    -- User C: sem orders (intencional).
END;
$$;
