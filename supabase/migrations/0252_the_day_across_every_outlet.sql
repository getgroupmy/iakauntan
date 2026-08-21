-- =====================================================================
-- The day, across every outlet
--
-- A company with three shops has three of everything: three floor
-- plans, three open-order lists, three drawers to count. Every POS
-- screen takes an outlet and answers about that outlet, which is right
-- for the person standing in it and useless to the person who owns all
-- three. `pos_sales_by_channel` and the Z-report are both per outlet;
-- group consolidation is a monthly accounting roll-up and says nothing
-- about this afternoon.
--
-- So there is nowhere to answer "how are we doing today", which is the
-- question an owner asks first and asks constantly.
--
-- ---------------------------------------------------------------------
-- One row per shop, and the two clocks that differ
--
-- Everything in it is about the trading day named, except the count of
-- open bills, which is about *now* -- a bill left parked has no day yet
-- and the useful reading of it is "there are four still open at this
-- moment". They are separate columns and the screen labels them
-- separately, because a number that silently means a different clock
-- from the one beside it is worse than no number.
--
-- The day is the shop's own: `at time zone 'Asia/Kuala_Lumpur'`, the
-- same boundary 0248 uses. A bill settled at eleven at night belongs to
-- the night it happened on.
--
-- ---------------------------------------------------------------------
-- Cash separately, because cash is what goes missing
--
-- Gross is what was sold; the cash column is what should be in a drawer
-- at the end of it -- `amount - change_given`, the same arithmetic
-- `app.pos_expected_cash` does for one shift. An owner comparing three
-- shops is usually comparing that one number.
--
-- Voided bills are on the row too. 0248 gave them a report of their
-- own; this puts the count where somebody sees it without going to
-- look, which is the difference between a report and a signal.
-- =====================================================================

create or replace function public.pos_day_board(
  p_org  uuid,
  p_date date default (now() at time zone 'Asia/Kuala_Lumpur')::date)
returns table (
  outlet_id     uuid,
  outlet_name   text,
  bills         integer,
  gross         numeric,
  cash          numeric,
  non_cash      numeric,
  average_bill  numeric,
  -- Now, not on p_date. See the header.
  open_bills    integer,
  open_value    numeric,
  voided_bills  integer,
  voided_value  numeric)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  with done as (
    select s.outlet_id,
           count(*)::integer                as bills,
           coalesce(sum(s.total_amount), 0) as gross
      from public.pos_sales s
     where s.org_id = p_org
       and s.status = 'completed'
       and (s.completed_at at time zone 'Asia/Kuala_Lumpur')::date = p_date
     group by s.outlet_id
  ),
  paid as (
    select s.outlet_id,
           coalesce(sum(t.amount - t.change_given)
                    filter (where t.kind = 'cash'), 0) as cash,
           coalesce(sum(t.amount - t.change_given)
                    filter (where t.kind <> 'cash'), 0) as non_cash
      from public.pos_sales s
      join public.pos_tenders t on t.sale_id = s.id
     where s.org_id = p_org
       and s.status = 'completed'
       and (s.completed_at at time zone 'Asia/Kuala_Lumpur')::date = p_date
     group by s.outlet_id
  ),
  still_open as (
    select s.outlet_id,
           count(*)::integer                as bills,
           coalesce(sum(s.total_amount), 0) as value
      from public.pos_sales s
     where s.org_id = p_org and s.status = 'parked'
     group by s.outlet_id
  ),
  written_off as (
    select s.outlet_id,
           count(*)::integer                as bills,
           coalesce(sum(s.total_amount), 0) as value
      from public.pos_sales s
     where s.org_id = p_org
       and s.status = 'voided'
       and (s.voided_at at time zone 'Asia/Kuala_Lumpur')::date = p_date
     group by s.outlet_id
  )
  select o.id,
         o.name,
         coalesce(d.bills, 0),
         coalesce(d.gross, 0),
         coalesce(p.cash, 0),
         coalesce(p.non_cash, 0),
         -- Nought rather than a division by nought on a shop that has
         -- not sold anything yet today.
         case when coalesce(d.bills, 0) = 0 then 0
              else round(d.gross / d.bills, 2) end,
         coalesce(k.bills, 0),
         coalesce(k.value, 0),
         coalesce(w.bills, 0),
         coalesce(w.value, 0)
    from public.pos_outlets o
    left join done        d on d.outlet_id = o.id
    left join paid        p on p.outlet_id = o.id
    left join still_open  k on k.outlet_id = o.id
    left join written_off w on w.outlet_id = o.id
   where o.org_id = p_org
     and o.is_active
     and app.can_read_module(p_org, 'pos')
   -- A shop that sold nothing is still on the board, at the bottom.
   -- Its absence would read as "no problem" when it is the problem.
   order by coalesce(d.gross, 0) desc, o.name;
$$;

grant execute on function public.pos_day_board(uuid, date) to authenticated;

comment on function public.pos_day_board(uuid, date) is
  'One row per outlet for a trading day: bills, gross, cash and non-cash taken, average bill, what was written off — and how many bills are open right now, which is the one column on a different clock.';

-- ---------------------------------------------------------------------
-- And an address to send it to at one in the morning
-- ---------------------------------------------------------------------
--
-- On `email_settings` beside the reminder settings rather than on the
-- outlet, because the digest covers every outlet and there is one
-- person who wants it.
alter table public.email_settings
  add column if not exists sales_digest_to text;

comment on column public.email_settings.sales_digest_to is
  'Where yesterday''s trading goes each morning. Empty means no digest, which is the default: a mail nobody asked for is spam however useful it is.';

-- ---------------------------------------------------------------------
-- Yesterday, in an email
-- ---------------------------------------------------------------------
--
-- The body is built here rather than through `app.render_email`,
-- deliberately. Every other message is a sentence with a name and an
-- amount substituted into it, which is exactly what a template is for;
-- this one is a table whose number of rows is the number of shops. A
-- template language that could express it would be a programming
-- language, and the shop would be maintaining it.
--
-- Returns how many were queued, so the daily job's log says something.
create or replace function app.queue_sales_digest(
  p_on date default (now() at time zone 'Asia/Kuala_Lumpur')::date)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  r      record;
  b      record;
  v_body text;
  v_tot  numeric;
  v_bill integer;
  v_open integer;
  v_void integer;
  v_n    integer := 0;
begin
  for r in
    select s.org_id, s.sales_digest_to, s.from_name, s.reply_to, o.name as org
      from public.email_settings s
      join public.organizations o on o.id = s.org_id
     where s.is_enabled
       and coalesce(btrim(s.sales_digest_to), '') <> ''
       and coalesce(o.status, 'active') = 'active'
       and app.has_module(s.org_id, 'pos')
  loop
    v_body := '';
    v_tot  := 0;
    v_bill := 0;
    v_open := 0;
    v_void := 0;

    for b in select * from public.pos_day_board(r.org_id, p_on) loop
      v_body := v_body || rpad(b.outlet_name, 24)
             || lpad(b.bills::text, 5) || ' bills   '
             || lpad(to_char(b.gross, 'FM999G999G990D00'), 12)
             || case when b.voided_bills > 0
                     then '   (' || b.voided_bills || ' written off, '
                          || to_char(b.voided_value, 'FM999G999G990D00') || ')'
                     else '' end
             || E'\n';
      v_tot  := v_tot + b.gross;
      v_bill := v_bill + b.bills;
      v_open := v_open + b.open_bills;
      v_void := v_void + b.voided_bills;
    end loop;

    -- A shop that was shut has nothing to report, and a mail every
    -- Monday saying "nothing happened on Sunday" is how a digest gets
    -- filtered into a folder nobody opens. Written off with no sales
    -- still goes: that is the day worth asking about.
    if v_bill = 0 and v_void = 0 then
      continue;
    end if;

    v_body :=
      r.org || ' — ' || to_char(p_on, 'FMDay DD Mon YYYY') || E'\n\n'
      || v_body
      || E'\n' || rpad('Total', 24) || lpad(v_bill::text, 5) || ' bills   '
      || lpad(to_char(v_tot, 'FM999G999G990D00'), 12) || E'\n'
      || case when v_open > 0
              then E'\n' || v_open || ' bill(s) still open at the time this '
                   || 'was sent.' || E'\n'
              else '' end;

    begin
      insert into public.email_outbox
        (org_id, to_email, subject, body, reply_to, from_name,
         template_code, dedupe_key)
      values (
        r.org_id, btrim(r.sales_digest_to),
        r.org || ' — takings for ' || to_char(p_on, 'FMDD Mon'),
        v_body, r.reply_to, coalesce(r.from_name, r.org),
        'sales_digest',
        'digest:' || r.org_id::text || ':' || p_on::text);
      v_n := v_n + 1;
    exception when unique_violation then
      -- Already queued for that day. The job running twice is not an
      -- error, and a second copy of yesterday would be.
      null;
    end;
  end loop;

  return v_n;
end;
$$;

revoke all on function app.queue_sales_digest(date)
  from public, anon, authenticated;

comment on function app.queue_sales_digest(date) is
  'Queues one plain-text digest per company that asked for one: every outlet''s bills and takings for the day, the total, and how many bills are still open. Silent on a day with no trading at all.';

-- ---------------------------------------------------------------------
-- Hung off the nightly run
-- ---------------------------------------------------------------------
--
-- `pg_cron` calls this at 17:00 UTC, which is one in the morning in
-- Kuala Lumpur, with `p_on` already the new date -- so the day that
-- just ended is `p_on - 1`, and that is what an owner opening their
-- phone at breakfast wants to read.
--
-- In its own block like the other tidy-ups 0147 added: a digest that
-- fails must not take the recurring invoices down with it.
create or replace function app.run_daily_jobs(p_on date default current_date)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare o record;
begin
  perform app.run_recurring_journals(p_on);
  perform app.run_recurring_documents(p_on);
  perform app.queue_overdue_reminders(p_on);

  begin
    perform public.chat_expire_calls();
  exception when others then
    raise warning 'chat_expire_calls failed: %', sqlerrm;
  end;

  begin
    perform public.prune_device_tokens();
  exception when others then
    raise warning 'prune_device_tokens failed: %', sqlerrm;
  end;

  begin
    perform app.queue_sales_digest(p_on - 1);
  exception when others then
    raise warning 'queue_sales_digest failed: %', sqlerrm;
  end;

  for o in select id from public.organizations
            where coalesce(status, 'active') = 'active'
  loop
    if extract(month from p_on) = 1 and extract(day from p_on) = 1 then
      perform app.roll_leave_year(o.id, extract(year from p_on)::integer);
    end if;

    if extract(day from p_on) = 1 and app.has_module(o.id, 'einvoice') then
      perform app.roll_einvoice_consolidation(
        o.id, (p_on - interval '1 month')::date);
    end if;
  end loop;
end;
$$;

revoke all on function app.run_daily_jobs(date) from public, anon, authenticated;
