-- =====================================================================
-- iAkauntan :: 0862 client money is the ledger's, and the fee earner's
--
-- A law firm's client account is a trust ledger. Every member read it:
--
--   * `client_account_transactions` -- each receipt, payment and
--     transfer of client money, line by line (`is_org_member`);
--   * `matter_client_balance` -- what a matter holds;
--   * `report_matter_summary`'s `client_funds` -- the same, for every
--     matter on the Matters screen.
--
-- Measured on 13 October 2026, locally, as a `sales` member who is the
-- matter's fee earner: the receipt "Purchase price, held in trust" of
-- 850,000.00, and the matter's 850,000.00 -- by the table, the
-- function and the summary alike. Every write already asks
-- `app.can_post`.
--
-- Answered "ledger roles, plus the matter's own fee earner". There is
-- no lawyer role: a fee earner may hold any, and the money held on
-- their own file is theirs to know. So `app.can_read_client_money`
-- answers for a current member of the matter's company who reads the
-- ledger or is named its fee earner, and:
--
--   * the select policy asks it of the line's matter;
--   * `matter_client_balance` gives the balance to such a member and
--     nothing -- not nought -- to anybody else;
--   * `report_matter_summary` still lists every matter to every
--     member, `client_funds` blank where the answer is no.
-- =====================================================================

-- Who may read a matter's client money: a member of its company who
-- reads the ledger, or the member named as the matter's fee earner.
-- A definer, so that the policy below can ask it of `matters` whatever
-- the caller reads there; nothing in it is the caller's to choose.
create or replace function app.can_read_client_money(p_matter uuid)
returns boolean
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select exists (
    select 1 from public.matters m
     where m.id = p_matter
       and app.is_org_member(m.org_id)
       and (app.can_read_ledger(m.org_id) or m.fee_earner = auth.uid()));
$$;

revoke all on function app.can_read_client_money(uuid) from public, anon;
grant execute on function app.can_read_client_money(uuid) to authenticated;

alter policy client_account_transactions_select on public.client_account_transactions
  using (app.can_read_client_money(matter_id));

-- Restated from `0549`, its text unchanged but for the marked lines.
create or replace function public.matter_client_balance(p_matter uuid)
returns numeric
language sql stable security definer
set search_path = public, app, pg_temp as $$
  -- `0862`: blank, not nought, to a member who may not read it.
  select case when app.can_read_client_money(p_matter) then (
  select coalesce(sum(t.amount), 0)
    from public.client_account_transactions t
    join public.matters m on m.id = t.matter_id
   where t.matter_id = p_matter
     and t.status <> 'void'
     and app.is_org_member(m.org_id)) end;
$$;

-- Restated from `0022`, its text unchanged but for the marked lines.
create or replace function public.report_matter_summary(p_org_id uuid)
returns table (
  matter_id uuid, matter_no text, matter_name text, client_name text,
  status app.matter_status, client_funds numeric,
  unbilled_time numeric, unbilled_disbursements numeric,
  billed numeric, outstanding numeric)
language sql stable security definer
set search_path = public, app, pg_temp as $$
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
     and app.is_org_member(p_org_id)
   order by m.matter_no;
$$;
