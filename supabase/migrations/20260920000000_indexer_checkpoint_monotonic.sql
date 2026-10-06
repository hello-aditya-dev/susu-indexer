-- Susu Protocol — monotonic checkpoint advancement
--
-- WHY THIS EXISTS
-- `advanceCheckpoint` (db.ts) used an unconditional upsert, so the only thing
-- keeping the checkpoint from moving backwards was `canAdvanceCheckpoint`
-- (index.ts), an in-memory check read from a snapshot that may already be
-- stale by the time the write happens. Out-of-order or concurrent runs could
-- therefore overwrite a newer checkpoint with an older one: run A writes
-- ledger 5100, run B then writes 5050, and the persisted checkpoint regresses.
-- Regressing the checkpoint re-indexes events and can mask a gap, so the guard
-- belongs at the database, not in application memory.
--
-- WHAT IT DOES
-- One atomic statement: insert the checkpoint, or — when a row already exists
-- — advance it only if the new ledger is strictly greater. The
-- `ON CONFLICT DO UPDATE ... WHERE` clause is the guard: when the stored
-- ledger is not strictly less than the new one, the row is left untouched and
-- `updated_at` is not bumped. Because the whole statement is one atomic
-- update, two concurrent writers cannot leave the lower value behind
-- regardless of commit order — the row lock serializes them and the WHERE is
-- re-checked against the committed row.
--
-- `start_ledger` is set by the initial INSERT and never touched again on a
-- subsequent advance. It is the deployment ledger that indexing never goes
-- below, and the only legitimate way to change it is a full rebuild (delete
-- the checkpoint row so the next run re-inserts it). Advancing the checkpoint
-- therefore only writes `last_processed_ledger` and `updated_at`.
--
-- SECURITY
-- Runs as the caller (SECURITY INVOKER). Only `service_role` — used solely by
-- the trusted indexer Edge Function, and which bypasses RLS — is granted
-- EXECUTE. Browser roles get nothing, consistent with the core migration. The
-- function touches only `public.indexer_checkpoints`, which `service_role` may
-- already select, insert and update, so INVOKER is sufficient and avoids the
-- fixed `search_path` obligation a SECURITY DEFINER function would carry; the
-- `search_path` is still pinned for hygiene and everything is schema-qualified.

create or replace function public.advance_indexer_checkpoint(
  p_last_processed_ledger bigint,
  p_start_ledger bigint
)
returns bigint
language sql
security invoker
set search_path = public
as $$
  with ins as (
    insert into public.indexer_checkpoints (id, last_processed_ledger, start_ledger, updated_at)
    values ('default', p_last_processed_ledger, p_start_ledger, now())
    on conflict (id) do update
      set last_processed_ledger = excluded.last_processed_ledger,
          updated_at = now()
      where public.indexer_checkpoints.last_processed_ledger < excluded.last_processed_ledger
  )
  select last_processed_ledger
  from public.indexer_checkpoints
  where id = 'default';
$$;

comment on function public.advance_indexer_checkpoint(bigint, bigint) is
  'Atomically advance the default indexer checkpoint to the given ledger, but only when it is strictly greater than the stored value. Returns the resulting last_processed_ledger.';

-- Only the trusted indexer function (service_role) may call this. A browser
-- never does, and PUBLIC must not either.
revoke all on function public.advance_indexer_checkpoint(bigint, bigint) from public;
revoke all on function public.advance_indexer_checkpoint(bigint, bigint) from anon, authenticated;
grant execute on function public.advance_indexer_checkpoint(bigint, bigint) to service_role;
