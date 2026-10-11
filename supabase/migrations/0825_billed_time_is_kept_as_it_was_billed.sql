-- =====================================================================
-- iAkauntan :: 0825 billed time is kept as it was billed
--
-- `bill_project_time` and `bill_matter_time` invoice the billable time
-- in a range and mark each entry billed, with the invoice it went on;
-- `close_project` writes off what is left. The next run reads
-- `is_billed` and nothing else to know what has been invoiced. The
-- timesheet editor sends the date, the minutes, whether it is billable,
-- the project and the description -- never `is_billed` or `invoice_id`
-- -- but the table's policies let a client write every column.
--
-- Measured on 11 October 2026, locally, as the owner with the role
-- `authenticated`: two hours at RM300 billed on INV-2026-00001, RM600.
-- The same entry raised by hand to eight hours, its `is_billed` and
-- `invoice_id` cleared, and the project billed again: INV-2026-00002,
-- RM2,400 -- the customer invoiced twice for one day's work. And the
-- billed entry could be deleted after.
--
-- Answered "freeze once billed", as `0824` did for a posted expense. A
-- trigger refuses a client's own statement -- role `authenticated` or
-- `anon`, at the top trigger depth -- that changes `is_billed` or
-- `invoice_id` on any entry; that changes a billed entry's minutes,
-- rate (and so its amount), date, project, matter, person or billable
-- flag, or deletes it; or that creates an entry already billed.
-- Unbilled time is edited as before, and a billed entry's description
-- and activity can still be put right. The billing functions run as
-- their owner and pass. NOT security definer.
--
-- It fires LAST, unlike `0813`'s and `0824`'s: `apply_billing_rate` and
-- `calc_amount` rewrite the rate and the amount in the same statement,
-- so the row this trigger compares has to be the one about to be
-- written, not the one the client sent.
--
-- Production held twenty-eight entries, twelve billed, every billed one
-- on an invoice, on 11 October.
-- =====================================================================

create or replace function app.billed_time_is_kept()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  -- What the invoice was built from. Not `amount`: `calc_amount` works
  -- it out from the minutes and the rate on every write, so a typed one
  -- never reaches the row, and both of those are here.
  c_frozen constant text[] := array[
    'org_id', 'user_id', 'project_id', 'matter_id', 'entry_date',
    'minutes', 'hourly_rate', 'is_billable'];
  v_old jsonb;
  v_new jsonb;
  v_col text;
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return coalesce(new, old);
  end if;

  if tg_op = 'INSERT' then
    if new.is_billed or new.invoice_id is not null then
      raise exception
        'Time is logged unbilled. It is billed by billing it, which puts '
        'it on an invoice.'
        using errcode = '42501';
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    if old.is_billed then
      raise exception
        'Time of % on % has been billed, and the invoice it went on '
        'stands on it. Put it right on the invoice, with a credit note.',
        old.minutes || ' minutes', old.entry_date
        using errcode = '42501';
    end if;
    return old;
  end if;

  if new.is_billed is distinct from old.is_billed
     or new.invoice_id is distinct from old.invoice_id then
    raise exception
      'Time becomes billed by billing it, which puts it on an invoice -- '
      'not by being marked so; and billed time is put right on the '
      'invoice, with a credit note, not by being marked unbilled.'
      using errcode = '42501';
  end if;

  if old.is_billed then
    v_old := to_jsonb(old);
    v_new := to_jsonb(new);
    foreach v_col in array c_frozen loop
      if v_new -> v_col is distinct from v_old -> v_col then
        raise exception
          'Time of % on % has been billed, and its % is what the invoice '
          'was built from. Its description can still be put right.',
          old.minutes || ' minutes', old.entry_date, v_col
          using errcode = '42501';
      end if;
    end loop;
  end if;

  return new;
end $$;

revoke all on function app.billed_time_is_kept() from public, anon, authenticated;

comment on function app.billed_time_is_kept() is
  'On time_entries: refuses a client''s own statement that writes '
  'is_billed or invoice_id, changes a billed entry''s figures, dates or '
  'whose it is, deletes a billed entry, or creates one billed. Fires '
  'last, after the rate and amount triggers. The billing functions '
  'pass. 0825.';

create trigger z_billed_time_is_kept
  before insert or update or delete on public.time_entries
  for each row execute function app.billed_time_is_kept();
