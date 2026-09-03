-- =====================================================================
-- 0501  Filing the month's consolidated e-Invoice is a writing job
--
-- `consolidate_pos_einvoices` asked one question before filing: does
-- this person have write access to the e-Invoice MODULE. That is not
-- the same question as whether they may write anything at all.
--
-- `app.module_access` returns 'write' for a member who has no access
-- type assigned to them -- which is most members of most companies --
-- whatever their role. The overlay is meant to narrow what a writer may
-- reach, not to decide who is a writer; deciding that is what the role
-- is for, and everywhere else the two are asked together. So a member
-- explicitly set to `viewer` could file a statutory return to LHDN
-- naming the month's takings.
--
-- `prepare_einvoice`, the individual filing, already asks
-- `app.can_write`. These are two routes to the same act -- telling LHDN
-- what a shop sold -- and there is no reading of the guideline under
-- which one of them needs a writer and the other does not. The
-- consolidated route now asks the same question.
--
-- Deliberately NOT changed: selling. `complete_pos_sale` and
-- `request_einvoice_for_sale` stay on the module bar, because a cashier
-- is not an accountant and naming the buyer is part of the sale. The
-- month end is not.
-- =====================================================================

create or replace function public.consolidate_pos_einvoices(
  p_org   uuid,
  p_month date default (date_trunc('month', current_date) - interval '1 month')::date)
returns table (
  consolidation_id uuid,
  period_start     date,
  period_end       date,
  due_date         date,
  document_count   integer,
  total_amount     numeric,
  added            integer)
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_from   date := date_trunc('month', p_month)::date;
  v_to     date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  v_con    uuid;
  v_status text;
  v_added  integer := 0;
begin
  if not app.can_write_module(p_org, 'einvoice') then
    raise exception 'not permitted to file e-Invoices for this organization'
      using errcode = '42501';
  end if;

  -- The module says which company's e-Invoices; the role says whether
  -- this is somebody who files anything.
  if not app.can_write(p_org) then
    raise exception
      'Filing the month''s consolidated e-Invoice is a writing job, and '
      'this account is read-only.' using errcode = '42501';
  end if;

  select c.id, c.status into v_con, v_status
    from public.einvoice_consolidations c
   where c.org_id = p_org and c.period_start = v_from and c.period_end = v_to;

  if v_con is not null and v_status not in ('draft', 'generated') then
    raise exception
      'The consolidation for % has already been submitted. A sale that '
      'missed it needs its own e-Invoice.', to_char(v_from, 'Mon YYYY')
      using errcode = '23514';
  end if;

  if v_con is null then
    insert into public.einvoice_consolidations
      (org_id, period_start, period_end, status, created_by)
    values (p_org, v_from, v_to, 'draft', auth.uid())
    returning id into v_con;
  end if;

  -- Every completed counter sale in the month that nobody claimed, and
  -- that has not already been given its own e-Invoice.
  v_added := app.pos_consolidation_absorb(p_org, v_con, v_from, v_to);

  -- Totals recomputed from the items rather than accumulated, for the
  -- reason every other total in this database is derived: a counter is
  -- wrong the moment a row is removed.
  update public.einvoice_consolidations c
     set document_count = (select count(*) from public.einvoice_consolidation_items i
                            where i.consolidation_id = c.id),
         total_amount   = (select coalesce(sum(i.amount), 0)
                             from public.einvoice_consolidation_items i
                            where i.consolidation_id = c.id)
   where c.id = v_con;

  return query
    select c.id, c.period_start, c.period_end, c.due_date,
           c.document_count, c.total_amount, v_added
      from public.einvoice_consolidations c where c.id = v_con;
end;
$$;
