-- Susu Protocol — checkpoint monotonicity (real Postgres behavioral test)
--
-- Runs in CI against the same PostgreSQL 17 the migration-guards job uses, after
-- the migrations have been applied. It exercises the
-- `advance_indexer_checkpoint` SQL function directly — the database-level guard
-- introduced for issue #11 — and asserts the acceptance criteria:
--
--   1. An initial checkpoint can be inserted.
--   2. A higher ledger advances the checkpoint.
--   3. An equal ledger is a no-op.
--   4. A lower ledger is a no-op.
--   5. Reverse-order / out-of-order writes leave the higher ledger behind.
--
-- Each step raises an exception with a label on failure, so the CI step
-- (`psql -v ON_ERROR_STOP=1`) fails loudly rather than passing silently. The
-- `updated_at` timer is also checked, because a no-op must not reset the
-- staleness window that `check_indexer_health` watches.
--
-- Local run:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/checkpoint_monotonic.sql

\set ON_ERROR_STOP on

do $$
declare
  v_ledger bigint;
  v_start bigint;
  v_updated_at timestamptz;
  v_updated_at_after timestamptz;
begin
  -- Start from a clean slate so the test is independent of migration order.
  delete from public.indexer_checkpoints where id = 'default';

  -- 1. The first advance inserts the row.
  perform public.advance_indexer_checkpoint(5000, 1);
  select last_processed_ledger, updated_at into v_ledger, v_updated_at
    from public.indexer_checkpoints where id = 'default';
  if v_ledger is null then
    raise exception '1. initial insert: expected a row, found none';
  elsif v_ledger <> 5000 then
    raise exception '1. initial insert: expected 5000, got %', v_ledger;
  end if;

  -- 2. A strictly greater ledger advances.
  perform public.advance_indexer_checkpoint(5100, 1);
  select last_processed_ledger into v_ledger from public.indexer_checkpoints where id = 'default';
  if v_ledger <> 5100 then
    raise exception '2. higher ledger: expected 5100, got %', v_ledger;
  end if;

  -- 3. An equal ledger is a no-op, and must not bump updated_at.
  perform pg_sleep(0.01); -- ensure now() can move if it were (wrongly) written
  perform public.advance_indexer_checkpoint(5100, 1);
  select last_processed_ledger, updated_at into v_ledger, v_updated_at_after
    from public.indexer_checkpoints where id = 'default';
  if v_ledger <> 5100 then
    raise exception '3. equal ledger: expected 5100, got %', v_ledger;
  end if;
  if v_updated_at is distinct from v_updated_at_after then
    raise exception '3. equal ledger: updated_at moved from % to %', v_updated_at, v_updated_at_after;
  end if;

  -- 4. A lower ledger is a no-op, and must not bump updated_at.
  perform public.advance_indexer_checkpoint(4900, 1);
  select last_processed_ledger, updated_at into v_ledger, v_updated_at_after
    from public.indexer_checkpoints where id = 'default';
  if v_ledger <> 5100 then
    raise exception '4. lower ledger: expected 5100, got %', v_ledger;
  end if;
  if v_updated_at is distinct from v_updated_at_after then
    raise exception '4. lower ledger: updated_at moved from % to %', v_updated_at, v_updated_at_after;
  end if;

  -- 5. Reverse order: a higher value followed by a lower value keeps the higher.
  --    (5100 is already stored; 5050 must be rejected.)
  perform public.advance_indexer_checkpoint(5050, 1);
  select last_processed_ledger into v_ledger from public.indexer_checkpoints where id = 'default';
  if v_ledger <> 5100 then
    raise exception '5a. 5100 then 5050: expected 5100, got %', v_ledger;
  end if;

  -- 5b. The opposite order, from a clean slate: 5050 first, then 5100, ends at 5100.
  delete from public.indexer_checkpoints where id = 'default';
  perform public.advance_indexer_checkpoint(5050, 1);
  perform public.advance_indexer_checkpoint(5100, 1);
  select last_processed_ledger into v_ledger from public.indexer_checkpoints where id = 'default';
  if v_ledger <> 5100 then
    raise exception '5b. 5050 then 5100: expected 5100, got %', v_ledger;
  end if;

  -- 5c. The same two writes in the other completion order: 5100 first, then 5050.
  delete from public.indexer_checkpoints where id = 'default';
  perform public.advance_indexer_checkpoint(5100, 1);
  perform public.advance_indexer_checkpoint(5050, 1);
  select last_processed_ledger into v_ledger from public.indexer_checkpoints where id = 'default';
  if v_ledger <> 5100 then
    raise exception '5c. 5100 then 5050: expected 5100, got %', v_ledger;
  end if;

  -- 6. start_ledger is carried by the initial insert and is stable afterwards.
  delete from public.indexer_checkpoints where id = 'default';
  perform public.advance_indexer_checkpoint(6000, 700);
  select start_ledger into v_ledger from public.indexer_checkpoints where id = 'default';
  if v_ledger <> 700 then
    raise exception '6. start_ledger: expected 700, got %', v_ledger;
  end if;

  -- 7. start_ledger is immutable across an advance: even if a caller passes a
  --    different start_ledger on a higher-ledger advance, the stored value is
  --    preserved. Only a full rebuild (delete + re-insert) may change it.
  perform public.advance_indexer_checkpoint(7000, 999);
  select last_processed_ledger, start_ledger into v_ledger, v_start
    from public.indexer_checkpoints where id = 'default';
  if v_ledger <> 7000 then
    raise exception '7. advance: expected last_processed_ledger 7000, got %', v_ledger;
  end if;
  if v_start <> 700 then
    raise exception '7. start_ledger immutability: expected 700 (preserved), got %', v_start;
  end if;

  -- Cleanup: leave the table empty so re-running the test (or the guards) is
  -- unaffected by this script's data.
  delete from public.indexer_checkpoints where id = 'default';

  raise notice 'checkpoint_monotonic: all assertions passed';
end $$;
