-- =====================================================================
-- iAkauntan :: consolidation, and the elimination that makes it one
--
-- 0142 added up the group's books and was careful to call the result a
-- *combined* trial balance, listing what a consolidation under MFRS 10
-- needs that a combination does not:
--
--   * inter-company receivables against the matching payables,
--   * inter-company sales against the matching purchases,
--   * unrealised profit in stock one company bought from another,
--   * minority interest where a subsidiary is not wholly owned,
--   * translation where the companies keep different currencies.
--
-- This does the first two, records what is needed for the fourth, and
-- refuses rather than guessing at the rest.
--
-- ---------------------------------------------------------------------
-- Why elimination is a matching problem, not a filter
--
-- 0142 wrote down why the two obvious implementations are wrong, and
-- that reasoning still holds. Excluding *lines* whose contact is a group
-- company drops the receivable and the revenue and leaves the SST behind,
-- because a tax line carries no contact — so the trial balance stops
-- balancing. Excluding whole *entries* balances and deletes real money,
-- because an inter-company payment has a bank line on it.
--
-- So nothing is excluded. What happens instead is what a group
-- accountant does on paper: match the two sides, and post a balanced
-- adjustment for the part that agrees.
--
--   A's receivable from B      1,080  Cr  ← eliminated
--   B's payable to A           1,080  Dr  ← eliminated
--   A's revenue from B         1,000  Dr  ← eliminated
--   B's cost from A            1,000  Cr  ← eliminated
--
-- Four adjustments summing to zero, by construction. What is left is
-- A's output tax and B's input tax, which are *not* eliminated and must
-- not be: A genuinely owes Customs and B genuinely paid. They are not
-- amounts between the two companies at all.
--
-- ---------------------------------------------------------------------
-- Only what matches, and the rest is reported
--
-- Where the two sides disagree — and they routinely do, because one
-- company has posted the invoice and the other has not yet received it
-- — nothing is eliminated for that pair and that category. Not the
-- smaller of the two, not an average: nothing.
--
-- Eliminating the lesser amount would balance and would quietly bury the
-- difference inside the consolidated figures, where nobody would look
-- for it again. The difference is the thing worth looking at, so it
-- comes out as a row in `report_group_elimination_check` and the
-- consolidation says how many are outstanding. Reconcile, then
-- consolidate: that is the order the work is actually done in.
--
-- ---------------------------------------------------------------------
-- Ownership, and what this still refuses to do
--
-- A consolidation of a subsidiary that is not wholly owned has to strip
-- out the share belonging to somebody else. That calculation needs the
-- percentage, and until now nothing in this schema recorded one — so a
-- report claiming to consolidate would have been claiming something it
-- had no way to know.
--
-- The percentage is recorded here, and anything short of 100% is
-- refused by name. Unrealised profit in stock needs lineage this schema
-- does not keep and is refused the same way; mixed currencies were
-- already refused by 0142 and still are.
-- =====================================================================

alter table public.organizations
  add column parent_org_id uuid references public.organizations (id)
    on delete set null,
  add column owned_percent numeric(9, 4)
    check (owned_percent is null
           or (owned_percent > 0 and owned_percent <= 100));

comment on column public.organizations.parent_org_id is
  'The company in the same group that owns this one. Null for the '
  'ultimate parent, and for a company nobody has recorded ownership for.';
comment on column public.organizations.owned_percent is
  'How much of this company the parent owns. 100 means wholly owned; '
  'anything less needs minority interest, which is not computed, so the '
  'consolidated report refuses rather than understating it.';

-- ---------------------------------------------------------------------
-- Recording who owns whom
-- ---------------------------------------------------------------------
create or replace function public.set_group_ownership(
  p_org_id uuid, p_parent_org_id uuid, p_percent numeric)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_group uuid;
begin
  -- Administrator of the company being owned. Deliberately not of the
  -- parent: this states a fact about *this* company's share capital, and
  -- the person who runs this company is the one who knows it.
  if not app.can_admin(p_org_id) then
    raise exception 'You cannot change this company''s ownership'
      using errcode = '42501';
  end if;

  if p_parent_org_id is null then
    update public.organizations
       set parent_org_id = null, owned_percent = null
     where id = p_org_id;
    return;
  end if;

  if p_parent_org_id = p_org_id then
    raise exception 'A company cannot own itself' using errcode = '42501';
  end if;

  select group_id into v_group from public.organizations where id = p_org_id;
  if v_group is null then
    raise exception 'This company is not in a group' using errcode = '42501';
  end if;

  -- The parent has to be in the same group and one the caller can
  -- already reach — the same rule `link_group_contact` uses, and for the
  -- same reason: otherwise this becomes a way to discover which
  -- companies exist.
  if not exists (
    select 1 from public.organizations o
     where o.id = p_parent_org_id and o.group_id = v_group
       and app.is_org_member(o.id))
  then
    raise exception 'That is not a company in this group that you belong to'
      using errcode = '42501';
  end if;

  if p_percent is null or p_percent <= 0 or p_percent > 100 then
    raise exception 'Ownership must be more than 0 and at most 100 percent';
  end if;

  -- One level. A owns B owns C is a real structure and consolidating it
  -- needs the chain walked and the indirect share computed; refusing it
  -- here is better than a number that looks right for two levels and is
  -- wrong for three.
  if exists (select 1 from public.organizations
              where id = p_parent_org_id and parent_org_id is not null) then
    raise exception
      'That company is itself owned by another, and consolidating a chain '
      'of holdings is not built. Record the ultimate parent instead.';
  end if;

  update public.organizations
     set parent_org_id = p_parent_org_id, owned_percent = p_percent
   where id = p_org_id;
end; $$;

revoke all on function public.set_group_ownership(uuid, uuid, numeric)
  from public, anon;
grant execute on function public.set_group_ownership(uuid, uuid, numeric)
  to authenticated;

-- ---------------------------------------------------------------------
-- Amounts between two companies, by the account they sit in
--
-- By *code* rather than by account id, because an adjustment has to land
-- on a row of the combined trial balance and that is grouped by code.
-- ---------------------------------------------------------------------
create or replace function app.group_intercompany_lines(
  p_org_id uuid, p_from date default null, p_to date default current_date)
returns table (
  org_id       uuid,
  counterparty uuid,
  category     text,
  code         text,
  amount       numeric)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  with orgs as (select g.org_id from app.group_orgs(p_org_id) g)
  select l.org_id,
         c.linked_org_id,
         case
           when a.account_subtype = 'accounts_receivable' then 'receivable'
           when a.account_subtype = 'accounts_payable'    then 'payable'
           when a.account_type    = 'revenue'             then 'revenue'
           when a.account_type    = 'expense'             then 'expense'
         end,
         a.code,
         -- A magnitude, whichever side of the ledger it sits on. The
         -- direction is implied by the category and applied when the
         -- adjustment is built.
         round(sum(case
           when a.account_subtype = 'accounts_receivable' then l.debit - l.credit
           when a.account_subtype = 'accounts_payable'    then l.credit - l.debit
           when a.account_type    = 'revenue'             then l.credit - l.debit
           when a.account_type    = 'expense'             then l.debit - l.credit
         end), 2)
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
    join public.contacts c on c.id = l.contact_id
    join public.accounts a on a.id = l.account_id
   where l.org_id in (select org_id from orgs)
     and c.linked_org_id in (select org_id from orgs)
     and c.linked_org_id <> l.org_id
     and e.status = 'posted'
     and e.entry_date <= p_to
     and (p_from is null or e.entry_date >= p_from)
     and (a.account_subtype in ('accounts_receivable', 'accounts_payable')
          or a.account_type in ('revenue', 'expense'))
   group by l.org_id, c.linked_org_id, 3, a.code
  having round(sum(case
           when a.account_subtype = 'accounts_receivable' then l.debit - l.credit
           when a.account_subtype = 'accounts_payable'    then l.credit - l.debit
           when a.account_type    = 'revenue'             then l.credit - l.debit
           when a.account_type    = 'expense'             then l.debit - l.credit
         end), 2) <> 0;
$$;

revoke all on function app.group_intercompany_lines(uuid, date, date)
  from public, anon;
grant execute on function app.group_intercompany_lines(uuid, date, date)
  to authenticated;

-- ---------------------------------------------------------------------
-- Whether each pair reconciles
--
-- Two categories per ordered pair: what one is owed against what the
-- other owes, and what one sold against what the other bought.
-- ---------------------------------------------------------------------
create or replace function public.report_group_elimination_check(
  p_org_id uuid, p_from date default null, p_to date default current_date)
returns table (
  from_org     text,
  to_org       text,
  what         text,
  their_side   numeric,
  our_side     numeric,
  difference   numeric,
  eliminated   boolean)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'You are not a member of this company'
      using errcode = '42501';
  end if;

  return query
  with lines as (select * from app.group_intercompany_lines(p_org_id, p_from, p_to)),
  totals as (
    select l.org_id, l.counterparty, l.category, sum(l.amount) as amount
      from lines l group by l.org_id, l.counterparty, l.category),
  pairs as (
    select r.org_id as a, r.counterparty as b,
           'Balances owed'::text as what,
           r.amount as a_side,
           coalesce(p.amount, 0) as b_side
      from totals r
      left join totals p
        on p.org_id = r.counterparty and p.counterparty = r.org_id
       and p.category = 'payable'
     where r.category = 'receivable'
    union all
    select s.org_id, s.counterparty, 'Trading'::text,
           s.amount, coalesce(x.amount, 0)
      from totals s
      left join totals x
        on x.org_id = s.counterparty and x.counterparty = s.org_id
       and x.category = 'expense'
     where s.category = 'revenue')
  select seller.name, buyer.name, pairs.what,
         pairs.a_side, pairs.b_side,
         round(pairs.a_side - pairs.b_side, 2),
         round(pairs.a_side - pairs.b_side, 2) = 0
    from pairs
    join public.organizations seller on seller.id = pairs.a
    join public.organizations buyer  on buyer.id  = pairs.b
   order by seller.name, buyer.name, pairs.what;
end; $$;

revoke all on function public.report_group_elimination_check(uuid, date, date)
  from public, anon;
grant execute on function public.report_group_elimination_check(uuid, date, date)
  to authenticated;

-- ---------------------------------------------------------------------
-- The adjustments themselves, per account code
--
-- Signed to be *added* to the combined closing balance: an asset comes
-- down, a liability comes up toward zero, revenue comes up toward zero
-- and a cost comes down. Across a matched pair they sum to zero, which
-- is what keeps the consolidated trial balance in balance — and there is
-- an assertion for exactly that.
-- ---------------------------------------------------------------------
create or replace function app.group_eliminations(
  p_org_id uuid, p_from date default null, p_to date default current_date)
returns table (code text, adjustment numeric)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  with lines as (select * from app.group_intercompany_lines(p_org_id, p_from, p_to)),
  totals as (
    select l.org_id, l.counterparty, l.category, sum(l.amount) as amount
      from lines l group by l.org_id, l.counterparty, l.category),
  -- A pair reconciles when the two sides agree exactly. Only then is
  -- anything eliminated: see the header.
  matched as (
    select t.org_id, t.counterparty, t.category
      from totals t
      join totals o
        on o.org_id = t.counterparty and o.counterparty = t.org_id
       and o.category = case t.category
             when 'receivable' then 'payable'
             when 'payable'    then 'receivable'
             when 'revenue'    then 'expense'
             else 'revenue' end
     where round(t.amount - o.amount, 2) = 0)
  select l.code,
         round(sum(l.amount * case l.category
           when 'receivable' then -1   -- an asset comes down
           when 'payable'    then  1   -- a liability comes up toward zero
           when 'revenue'    then  1   -- revenue comes up toward zero
           else                   -1   -- a cost comes down
         end), 2)
    from lines l
    join matched m
      on m.org_id = l.org_id and m.counterparty = l.counterparty
     and m.category = l.category
   group by l.code;
$$;

revoke all on function app.group_eliminations(uuid, date, date)
  from public, anon;
grant execute on function app.group_eliminations(uuid, date, date)
  to authenticated;

-- ---------------------------------------------------------------------
-- The consolidated trial balance
-- ---------------------------------------------------------------------
create or replace function public.report_group_consolidated_trial_balance(
  p_org_id uuid, p_from date default null, p_to date default current_date)
returns table (
  code                 text,
  name                 text,
  account_type         app.account_type,
  account_subtype      app.account_subtype,
  companies            integer,
  combined_balance     numeric,
  elimination          numeric,
  consolidated_balance numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_partial text;
  v_unowned text;
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'You are not a member of this company'
      using errcode = '42501';
  end if;

  -- Anything short of wholly owned needs minority interest, and this
  -- does not compute one. Named rather than refused in general, because
  -- "cannot consolidate" is not an answer somebody can act on.
  select string_agg(o.name || ' (' || o.owned_percent || '%)', ', ')
    into v_partial
    from app.group_orgs(p_org_id) g
    join public.organizations o on o.id = g.org_id
   where o.id <> p_org_id and o.owned_percent is not null
     and o.owned_percent < 100;

  if v_partial is not null then
    raise exception
      'These companies are not wholly owned: %. Consolidating them needs '
      'minority interest, which is not built — the group''s share of '
      'their profit and net assets would have to be split out, and this '
      'report would understate it silently.', v_partial
      using errcode = '22000';
  end if;

  select string_agg(o.name, ', ') into v_unowned
    from app.group_orgs(p_org_id) g
    join public.organizations o on o.id = g.org_id
   where o.id <> p_org_id and o.parent_org_id is null;

  if v_unowned is not null then
    raise exception
      'Nobody has recorded who owns %. A consolidation cannot be produced '
      'without it: whether the whole of a subsidiary belongs to the group '
      'is the question minority interest turns on. Record it in Settings.',
      v_unowned
      using errcode = '22000';
  end if;

  return query
  with e as (
    select g.code, sum(g.adjustment) as adjustment
      from app.group_eliminations(p_org_id, p_from, p_to) g
     group by g.code)
  select t.code, t.name, t.account_type, t.account_subtype, t.companies,
         t.closing_balance,
         coalesce(e.adjustment, 0),
         round(t.closing_balance + coalesce(e.adjustment, 0), 2)
    from public.report_group_trial_balance(p_org_id, p_from, p_to) t
    left join e on e.code = t.code
   order by t.code;
end; $$;

revoke all on function
  public.report_group_consolidated_trial_balance(uuid, date, date)
  from public, anon;
grant execute on function
  public.report_group_consolidated_trial_balance(uuid, date, date)
  to authenticated;
