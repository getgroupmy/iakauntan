-- =====================================================================
-- iAkauntan :: 0153 how far a migration has got
--
-- 0103, 0150, 0151 and 0152 built six importers, and between them they
-- are a *job* rather than six features: the invoices name customers by
-- code, so the contact list has to be there first; the trial balance
-- compares against the invoices, so they have to be there before it; and
-- the stock is checked against the inventory figure the trial balance
-- brought in. Done out of order they refuse each other, one message at a
-- time, and nothing anywhere says what the order is or whether you have
-- finished.
--
-- This is that. Six lines and a verdict.
--
-- ---------------------------------------------------------------------
-- Counts, not ticks
--
-- A tick would have to decide what "done" means, and for four of the six
-- steps there is no honest answer. A firm of accountants has no stock
-- and no items; a company that has always been cash has no unpaid
-- invoices. Zero is a perfectly finished state for any of them and a
-- tick would be either a lie or a nag.
--
-- So each step reports what is there and leaves the judgement to the
-- person doing the migration, who knows whether their old system had
-- three hundred customers or none.
--
-- ---------------------------------------------------------------------
-- The one line that is a verdict
--
-- `3900 Opening Balance Equity`. That one is not a matter of opinion:
-- when everything has been carried across it is zero, and while it is
-- not, the amount in it is the part of the old books that has not.
-- 0150 created the account for exactly this and 0151 is what clears it.
--
-- It is reported last because it is the only line that can say the
-- migration is *finished*, and reported as an amount rather than a tick
-- because the amount is what somebody goes looking for.
-- =====================================================================

create or replace function public.report_migration_progress(p_org_id uuid)
returns table (
  step_no  integer,
  step     text,
  quantity numeric,
  detail   text)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_suspense numeric;
  v_settled  boolean;
  v_entries  integer;
begin
  if not app.can_read_ledger(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  select balance, settled, entries
    into v_suspense, v_settled, v_entries
    from public.report_opening_balance_suspense(p_org_id);

  return query
  select 1, 'Customers and suppliers'::text,
         (select count(*)::numeric from public.contacts c
           where c.org_id = p_org_id and c.deleted_at is null),
         'Everything else names them by code, so this goes first.'::text
  union all
  select 2, 'Items',
         (select count(*)::numeric from public.items it
           where it.org_id = p_org_id and it.deleted_at is null),
         'Only needed if you sell stock or want the codes on invoices.'
  union all
  select 3, 'Open invoices',
         (select count(*)::numeric
            from public.sales_documents d
            join public.gl_entries e on e.id = d.gl_entry_id
           where d.org_id = p_org_id and e.source = 'opening_balance'),
         'What customers still owed at the changeover.'
  union all
  select 4, 'Open bills',
         (select count(*)::numeric
            from public.purchase_documents d
            join public.gl_entries e on e.id = d.gl_entry_id
           where d.org_id = p_org_id and e.source = 'opening_balance'),
         'What was still owed to suppliers.'
  union all
  select 5, 'Opening trial balance',
         (select count(*)::numeric from public.gl_entries e
           where e.org_id = p_org_id
             and e.source_table = 'opening_trial_balance'
             and e.status = 'posted'),
         'Everything else from the old balance sheet. Brought in once.'
  union all
  select 6, 'Opening stock',
         (select count(*)::numeric from public.stock_movements m
           where m.org_id = p_org_id
             and m.movement_type = 'opening_balance'),
         'Quantities behind the inventory figure. Posts no journal.'
  union all
  -- The verdict. Deliberately not a count of anything.
  select 7, 'Opening Balance Equity',
         round(v_suspense, 2),
         case
           when v_entries = 0 then
             'Nothing has been brought across yet.'
           when v_settled then
             'Nil, which means everything from the old books is here.'
           when v_suspense > 0 then
             'A credit balance: something was brought in with nothing on '
             'the other side of it. Usually the trial balance is still to '
             'come.'
           else
             'A debit balance: the trial balance expected more than was '
             'brought across. Compare its receivables and payables against '
             'the open invoices and bills.'
         end
   order by 1;
end $$;

revoke all on function public.report_migration_progress(uuid)
  from public, anon;
grant execute on function public.report_migration_progress(uuid)
  to authenticated;

comment on function public.report_migration_progress(uuid) is
  'The six imports that make up moving onto this system, in the order '
  'they have to be done, with what is there for each — and the balance '
  'of 3900, which is the only one of the seven that can say the '
  'migration is finished.';
