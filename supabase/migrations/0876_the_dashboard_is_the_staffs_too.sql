-- =====================================================================
-- iAkauntan :: 0876 the dashboard is the staff's too
--
-- `0873`-`0875` found the definers that answer any member by looking
-- for those that ask `is_org_member` and nothing narrower anywhere in
-- their body. That missed the ones that ask something narrower for one
-- figure and `is_org_member` for the rest: `dashboard_summary` keeps the
-- bank balance to a ledger reader and gives anybody in the company the
-- revenue, expenses, receivables, payables, overdue, drafts, e-invoices,
-- pipeline and low stock; `report_project_budget` and
-- `tax_estimate_payment_summary` keep the money to a ledger reader and
-- give the rest -- every project, every instalment's date -- to anybody;
-- `report_matter_summary` keeps the client money to its readers and
-- gives every matter with its unbilled time and invoices to anybody.
-- And `ai_ask` asks whether the company holds the AI, not whether she
-- may use it, which `0871` says she may not.
--
-- Measured on 13 October 2026, locally, after `0875`, as an `employee`
-- member with no access type, with the role `authenticated`:
-- `dashboard_summary` answered her, counting the company's draft
-- invoice, and `report_project_budget` gave her the project.
--
-- Production held no `employee` member on 13 October.
--
-- As in `0873`, each body below is the live one with
-- `app.is_staff_member(` in place of `app.is_org_member(` and nothing
-- else changed. `employee_definers.sql` stops looking for "nothing
-- narrower" -- the test that missed these -- and names every definer
-- that asks `is_org_member` at all, as left open to her or as guarded
-- by something narrower before it reads, and fails on one that is
-- neither.
-- =====================================================================

-- dashboard_summary: 1 membership check
CREATE OR REPLACE FUNCTION public.dashboard_summary(p_org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT app.today())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_from date := coalesce(p_from, date_trunc('month', app.today())::date);
  v_result jsonb;
begin
  if not app.is_staff_member(p_org_id) then
    raise exception 'Not a member of this organization' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'revenue', (
      select coalesce(sum(base_total_amount), 0) from public.sales_documents
       where org_id = p_org_id and doc_type = 'invoice'
         and status not in ('draft', 'void') and deleted_at is null
         and doc_date between v_from and p_to),
    'expenses', (
      select coalesce(sum(base_total_amount), 0) from public.purchase_documents
       where org_id = p_org_id and doc_type = 'bill'
         and status not in ('draft', 'void') and deleted_at is null
         and doc_date between v_from and p_to),
    'receivables', (
      select coalesce(sum(balance_amount), 0) from public.sales_documents
       where org_id = p_org_id and doc_type = 'invoice'
         and status not in ('draft', 'void') and deleted_at is null),
    'payables', (
      select coalesce(sum(balance_amount), 0) from public.purchase_documents
       where org_id = p_org_id and doc_type = 'bill'
         and status not in ('draft', 'void') and deleted_at is null),
    'overdue_receivables', (
      select coalesce(sum(balance_amount), 0) from public.sales_documents
       where org_id = p_org_id and doc_type = 'invoice'
         and status not in ('draft', 'void') and deleted_at is null
         and due_date < app.today() and balance_amount > 0),
    -- `0858`. The bank's balance is the ledger's, and only a reader of
    -- the ledger is given it; anybody else is given nothing, not nought.
    'bank_balance', case when app.can_read_ledger(p_org_id) then (
      select coalesce(sum(current_balance), 0) from public.bank_accounts
       where org_id = p_org_id and is_active) end,
    'draft_invoices', (
      select count(*) from public.sales_documents
       where org_id = p_org_id and doc_type = 'invoice'
         and status = 'draft' and deleted_at is null),
    'einvoice_pending', (
      select count(*) from public.einvoice_documents
       where org_id = p_org_id and status in ('draft', 'queued', 'submitted')),
    'einvoice_invalid', (
      select count(*) from public.einvoice_documents
       where org_id = p_org_id and status in ('invalid', 'failed')),
    'open_opportunities', (
      select coalesce(sum(amount), 0) from public.opportunities
       where org_id = p_org_id and status = 'open' and deleted_at is null),
    'weighted_pipeline', (
      select coalesce(sum(weighted_amount), 0) from public.opportunities
       where org_id = p_org_id and status = 'open' and deleted_at is null),
    'activities_due', (
      select count(*) from public.activities
       where org_id = p_org_id and status = 'pending'
         and due_date <= app.today() + interval '1 day'),
    'low_stock', (
      select count(*) from public.items
       where org_id = p_org_id and deleted_at is null and track_inventory
         and reorder_level > 0 and quantity_on_hand <= reorder_level)
  ) into v_result;

  return v_result;
end;
$function$;

-- report_matter_summary: 1 membership check
CREATE OR REPLACE FUNCTION public.report_matter_summary(p_org_id uuid)
 RETURNS TABLE(matter_id uuid, matter_no text, matter_name text, client_name text, status app.matter_status, client_funds numeric, unbilled_time numeric, unbilled_disbursements numeric, billed numeric, outstanding numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select m.id, m.matter_no, m.name, c.name, m.status,
         -- `0862`: the money held, to whom it may be shown; blank to
         -- everybody else, who still sees the matter and the rest.
         case when app.can_read_client_money(m.id) then
         coalesce((select sum(t.amount) from public.client_account_transactions t
                    where t.matter_id = m.id and t.status <> 'void'), 0) end,
         coalesce((select sum(e.amount) from public.time_entries e
                    where e.matter_id = m.id and e.is_billable and not e.is_billed), 0),
         coalesce((select sum(d.amount + d.tax_amount) from public.disbursements d
                    where d.matter_id = m.id and d.is_billable and not d.is_billed), 0),
         coalesce((select sum(s.total_amount) from public.sales_documents s
                    where s.matter_id = m.id and s.doc_type = 'invoice'
                      and s.status not in ('draft','void') and s.deleted_at is null), 0),
         coalesce((select sum(s.balance_amount) from public.sales_documents s
                    where s.matter_id = m.id and s.doc_type = 'invoice'
                      and s.status not in ('draft','void') and s.deleted_at is null), 0)
    from public.matters m
    join public.contacts c on c.id = m.client_id
   where m.org_id = p_org_id
     and m.deleted_at is null
     and app.is_staff_member(p_org_id)
   order by m.matter_no;
$function$;

-- report_project_budget: 1 membership check
CREATE OR REPLACE FUNCTION public.report_project_budget(p_org_id uuid, p_include_closed boolean DEFAULT false)
 RETURNS TABLE(project_id uuid, code text, name text, customer text, start_date date, end_date date, is_active boolean, budget_amount numeric, cost_to_date numeric, revenue_to_date numeric, unbilled_time numeric, variance numeric, percent_spent numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  -- `0857`. Every member is answered with every project, and only a
  -- reader of the ledger with what the ledger has against it.
  v_ledger constant boolean := app.can_read_ledger(p_org_id);
begin
  if not app.is_staff_member(p_org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  return query
    with ledger as (
      select l.project_code,
             sum(case when a.account_type = 'expense'
                      then l.debit - l.credit else 0 end) as cost,
             sum(case when a.account_type = 'revenue'
                      then l.credit - l.debit else 0 end) as revenue
        from public.gl_lines l
        join public.gl_entries e on e.id = l.entry_id
        join public.accounts a on a.id = l.account_id
       where l.org_id = p_org_id
         and e.status = 'posted'
         and l.project_code is not null
       group by l.project_code
    ),
    unbilled as (
      select t.project_id, sum(t.amount) as amount
        from public.time_entries t
       where t.org_id = p_org_id
         and t.project_id is not null
         and t.is_billable
         and not t.is_billed
       group by t.project_id
    )
    select p.id, p.code, p.name, c.name, p.start_date, p.end_date,
           p.is_active,
           p.budget_amount,
           case when v_ledger then round(coalesce(g.cost, 0), 2) end,
           case when v_ledger then round(coalesce(g.revenue, 0), 2) end,
           round(coalesce(u.amount, 0), 2),
           -- Null when there is no budget, rather than zero. A job with
           -- no budget is not a job exactly on budget, and a report
           -- that says nought either way is answering a question it was
           -- never asked.
           case when not v_ledger or p.budget_amount is null then null
                else round(p.budget_amount - coalesce(g.cost, 0), 2) end,
           case when not v_ledger or coalesce(p.budget_amount, 0) = 0 then null
                else round(coalesce(g.cost, 0) * 100 / p.budget_amount, 1)
           end
      from public.projects p
      left join public.contacts c on c.id = p.contact_id
      left join ledger g on g.project_code = p.code
      left join unbilled u on u.project_id = p.id
     where p.org_id = p_org_id
       and (p_include_closed or p.is_active)
     order by p.code;
end $function$;

-- tax_estimate_payment_summary: 1 membership check
CREATE OR REPLACE FUNCTION public.tax_estimate_payment_summary(p_estimate_id uuid)
 RETURNS TABLE(scheduled_total numeric, paid_total numeric, outstanding_total numeric, instalments integer, instalments_paid integer, overdue_count integer, overdue_total numeric, late_count integer, late_penalty numeric, next_due_on date, next_due_amount numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare e record; r record; v_today date := app.today(); v_ledger boolean;
begin
  select te.* into e from public.tax_estimates te where te.id = p_estimate_id;
  if e.id is null then
    raise exception 'No such estimate' using errcode = 'P0002';
  end if;
  if not app.is_staff_member(e.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  -- `0860`. The dashboard's tax tile asks this of every member for how
  -- many instalments are behind and when the next falls due, and those
  -- stay everybody's. What they come to is the ledger's: blank, not
  -- nought, to a role that does not read it.
  v_ledger := app.can_read_ledger(e.org_id);

  select * into r from public.tax_estimate_rules ru
   where ru.year_of_assessment = e.year_of_assessment
     and ru.form = e.form;

  return query
  with s as (select * from app.tax_estimate_schedule_of(p_estimate_id))
  select
    case when v_ledger then coalesce(sum(s.amount), 0) end,
    case when v_ledger then coalesce(sum(s.paid_amount), 0) end,
    case when v_ledger then coalesce(sum(s.outstanding), 0) end,
    count(*)::integer,
    -- Paid IN FULL (0768). Each of these four read `paid_on`, so an
    -- instalment with any payment recorded against it -- RM1 of
    -- RM10,000, or nil -- was paid, not overdue and not next.
    count(*) filter (where s.paid_on is not null and s.outstanding = 0)::integer,
    -- Due, not covered, and the date has gone. An instalment of nothing
    -- -- which a downward revision leaves behind -- is not overdue,
    -- because there was nothing to pay: its outstanding is nil.
    count(*) filter (
      where s.outstanding > 0 and s.due_on < v_today
    )::integer,
    case when v_ledger then coalesce(sum(s.outstanding) filter (
      where s.outstanding > 0 and s.due_on < v_today), 0) end,
    count(*) filter (where s.paid_late)::integer,
    -- 10% of what was paid late. Says what the charge comes to, not
    -- that LHDN raised it -- which is not something this can know.
    case when v_ledger then
    round(coalesce(sum(s.paid_amount) filter (where s.paid_late), 0)
          * coalesce(r.late_instalment_penalty_percent, 0) / 100, 2) end,
    -- The next one not covered, and what is still to pay on it.
    min(s.due_on) filter (where s.outstanding > 0),
    case when v_ledger then (array_agg(s.outstanding order by s.due_on)
       filter (where s.outstanding > 0))[1] end
  from s;
end; $function$;

-- ai_ask: 1 membership check
CREATE OR REPLACE FUNCTION public.ai_ask(p_org_id uuid, p_question text, p_conversation uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_id    uuid := p_conversation;
  v_price numeric(18, 2) := 0.20;
begin
  if not app.is_staff_member(p_org_id) then
    raise exception 'Not a member of that company' using errcode = '42501';
  end if;
  if not app.has_module(p_org_id, 'ai') then
    raise exception
      'The AI Assistant is not switched on for this company.'
      using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_question, '')), '') is null then
    raise exception 'Ask something.' using errcode = '23514';
  end if;

  if v_id is null then
    insert into public.ai_conversations (org_id, title, created_by)
    values (p_org_id, left(btrim(p_question), 80), auth.uid())
    returning id into v_id;
  else
    -- Somebody else's conversation is not one you may add to, and a
    -- conversation belongs to the company it was started in.
    if not exists (select 1 from public.ai_conversations c
                    where c.id = v_id and c.org_id = p_org_id
                      and (c.created_by = auth.uid()
                           or app.can_admin(p_org_id))) then
      raise exception 'That is not your conversation' using errcode = '42501';
    end if;
    update public.ai_conversations set updated_at = now() where id = v_id;
  end if;

  -- Charged before the answer, and refused when the credit is not
  -- there: the model bills for the attempt, so charging afterwards
  -- would mean a company at nil could ask for ever.
  perform app.move_credit(
    p_org_id, 'usage', -v_price, 'AI question', null, null, true);

  insert into public.ai_messages
    (conversation_id, org_id, role, content, created_by)
  values (v_id, p_org_id, 'user', btrim(p_question), auth.uid());

  return v_id;
end $function$;
