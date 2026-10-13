-- =====================================================================
-- iAkauntan :: 0850 an import is finished once
--
-- `rollback_import_batch` (`0610`) removes what an import wrote, and
-- refuses a batch whose status is `posted`: "a posted import has hit
-- the ledger", and is reversed with a journal rather than deleted. The
-- status was the only thing in the way, and it moved freely --
-- `finish_import_batch` sets whatever it is given without asking what
-- the batch already is, and an administrator may write the table.
--
-- Measured on 13 October 2026, locally, as the owner with the role
-- `authenticated`, on an import finished as `posted` that had written a
-- RM50,000 opening-balance journal: `finish_import_batch(batch,
-- 'failed')` was accepted on the posted batch, and the rollback then
-- deleted the posted journal and both its lines from the ledger, and
-- the imported customer with them. Setting the status back to `staging`
-- by hand did the same. The rollback is a definer, so the revoke that
-- keeps the ledger append-only (`0238`) did not stand in its way.
--
-- Answered "posted and rolled back are final": `an_import_is_finished_once`
--
--   * refuses moving a batch out of `posted` or `rolled_back`, WHOEVER
--     asks -- `finish_import_batch` is a definer and is the road that
--     was measured;
--   * refuses a client's own statement -- role `authenticated` or
--     `anon`, at the top trigger depth -- that changes a batch's status
--     at all. It moves through start, finish and rollback. A label or a
--     note is still a person's to edit.
--
-- NOT security definer: a definer would always answer "the owner".
--
-- Nothing in the app or the edge functions calls the import functions
-- yet, and production held no import batch on 13 October.
-- =====================================================================

create or replace function app.an_import_is_finished_once()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  -- Whoever asks: `finish_import_batch` is a definer.
  if old.status in ('posted', 'rolled_back') then
    raise exception
      'This import batch is %, and stays so. A posted import has reached '
      'the ledger and is reversed with a journal; one rolled back has '
      'already been undone. A new run is a new batch.',
      old.status
      using errcode = '55000';
  end if;

  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return new;
  end if;

  raise exception
    'An import batch''s status moves through start_import_batch, '
    'finish_import_batch and rollback_import_batch, not by hand.'
    using errcode = '42501';
end $$;

revoke all on function app.an_import_is_finished_once()
  from public, anon, authenticated;

comment on function app.an_import_is_finished_once() is
  'On import_batches: refuses moving a batch out of posted or '
  'rolled_back, whoever asks, and a client''s own change of status. '
  '0850.';

create trigger an_import_is_finished_once
  before update on public.import_batches
  for each row execute function app.an_import_is_finished_once();
