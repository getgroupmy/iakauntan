-- =====================================================================
-- iAkauntan :: reporting across a company group
--
-- ---------------------------------------------------------------------
-- This is combination, not consolidation, and the difference matters
--
-- 0132 named the relationship between companies. This adds up their
-- books — and stops short of calling the result consolidated accounts,
-- because it is not one, and a report that claims to be one when it is
-- not is worse than no report at all.
--
-- What is here: every company in the group that the person asking is a
-- member of, summed account code by account code, in one column. That
-- is a *combined* trial balance. It is what an owner wants on a Monday
-- morning — how big is the whole thing, where is the cash — and it is
-- honest arithmetic.
--
-- What is deliberately NOT here is the elimination that turns a
-- combination into a consolidation under MFRS 10:
--
--   * inter-company receivables against the matching payables,
--   * inter-company sales against the matching purchases,
--   * unrealised profit in stock one company bought from another,
--   * minority interest where a subsidiary is not wholly owned,
--   * translation where the companies keep different currencies.
--
-- The first two are visible in `report_group_intercompany` below, so an
-- accountant can see exactly what a consolidation would remove and do
-- it deliberately. The rest need ownership percentages and stock
-- lineage this schema does not yet record.
--
-- ---------------------------------------------------------------------
-- Why elimination is not simply "drop the inter-company rows"
--
-- Two obvious implementations are both wrong, and the reason is worth
-- recording so nobody rediscovers it in a filed set of accounts.
--
-- Excluding *lines* whose contact is a group company drops the
-- receivable and the revenue but leaves the SST on the invoice behind,
-- because a tax line carries no contact — so the combined trial balance
-- stops balancing.
--
-- Excluding whole *entries* balances, and deletes real money. An
-- inter-company payment has a bank line with no contact on it; drop the
-- entry and the paying company's cash never leaves, so consolidated
-- cash is overstated by every settlement the group has ever made.
--
-- Correct elimination matches pairs of balances and turnover, and it is
-- a deliberate piece of work rather than a filter. Hence the report.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A customer or supplier that is another company in the group
--
-- Needed by the report below, and by inter-company billing when that is
-- built: raising an invoice in one company and the matching bill in the
-- other needs to know they are the same relationship seen from two
-- sides.
-- ---------------------------------------------------------------------
alter table public.contacts
  add column linked_org_id uuid references public.organizations (id)
    on delete set null;

create index contacts_linked_org_idx on public.contacts (linked_org_id)
  where linked_org_id is not null;

comment on column public.contacts.linked_org_id is
  'When this customer or supplier is another company in the same group, '
  'the organization it stands for. Set by link_group_contact().';

-- Linking is not a free-text edit, because pointing a contact at an
-- organization the person cannot see would let them learn that it
-- exists. Both sides are checked.
create or replace function public.link_group_contact(
  p_contact_id uuid, p_org_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_owner uuid;
  v_group uuid;
begin
  select org_id into v_owner from public.contacts where id = p_contact_id;
  if v_owner is null then
    raise exception 'No such contact';
  end if;
  if not app.can_write(v_owner) then
    raise exception 'You cannot edit this company''s contacts'
      using errcode = '42501';
  end if;

  -- Unlinking is always allowed; it removes an assertion rather than
  -- making one.
  if p_org_id is null then
    update public.contacts set linked_org_id = null where id = p_contact_id;
    return;
  end if;

  select group_id into v_group from public.organizations where id = v_owner;
  if v_group is null then
    raise exception 'This company is not in a group'
      using errcode = '42501';
  end if;

  -- The target must be in the same group *and* one the caller can
  -- already reach. Without the second test this becomes a way to
  -- discover which companies exist.
  if not exists (
    select 1 from public.organizations o
     where o.id = p_org_id and o.group_id = v_group
       and app.is_org_member(o.id))
  then
    raise exception 'That is not a company in this group that you belong to'
      using errcode = '42501';
  end if;

  if p_org_id = v_owner then
    raise exception 'A company cannot be its own customer'
      using errcode = '42501';
  end if;

  update public.contacts set linked_org_id = p_org_id where id = p_contact_id;
end; $$;

revoke all on function public.link_group_contact(uuid, uuid) from public, anon;
grant execute on function public.link_group_contact(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- The companies a combined report may add up
--
-- Only those the caller is a member of. Somebody who belongs to one
-- company in a group of five gets a report over one company, not five —
-- the group names a relationship, it does not grant access to books.
-- ---------------------------------------------------------------------
create or replace function app.group_orgs(p_org_id uuid)
returns table (org_id uuid, base_currency text)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select o.id, o.base_currency
    from public.organizations o
   where app.is_org_member(p_org_id)
     and app.is_org_member(o.id)
     and o.group_id is not null
     and o.group_id = (select group_id from public.organizations
                        where id = p_org_id);
$$;

revoke all on function app.group_orgs(uuid) from public, anon;
grant execute on function app.group_orgs(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- The combined trial balance
--
-- Summed by account *code*, because ids are per company and the seeded
-- chart is shared. A company that has added an account the others do
-- not have appears as its own row, which is right — it is a real
-- balance that belongs to the group.
--
-- Mixed currencies are refused rather than added. Adding MYR to SGD
-- produces a number that looks like money and is not, and the fix —
-- translating at closing and average rates with the difference to a
-- translation reserve — is a piece of work, not a coalesce.
-- ---------------------------------------------------------------------
create or replace function public.report_group_trial_balance(
  p_org_id uuid, p_from date default null, p_to date default current_date)
returns table (
  code             text,
  name             text,
  account_type     app.account_type,
  account_subtype  app.account_subtype,
  companies        integer,
  opening_balance  numeric,
  debit            numeric,
  credit           numeric,
  closing_balance  numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_currencies text[];
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'You are not a member of this company'
      using errcode = '42501';
  end if;

  select array_agg(distinct g.base_currency)
    into v_currencies
    from app.group_orgs(p_org_id) g;

  if v_currencies is null then
    raise exception 'This company is not in a group'
      using errcode = '42501';
  end if;

  if array_length(v_currencies, 1) > 1 then
    raise exception
      'The companies in this group keep their books in different '
      'currencies (%). Adding them together would produce a number that '
      'is not money. Translating them properly is not built yet.',
      array_to_string(v_currencies, ', ')
      using errcode = '22000';
  end if;

  return query
  with orgs as (select g.org_id from app.group_orgs(p_org_id) g),
  per_company as (
    select t.code, t.name, t.account_type, t.account_subtype,
           t.opening_balance, t.debit, t.credit, t.closing_balance
      from orgs o
      cross join lateral public.report_trial_balance(o.org_id, p_from, p_to) t)
  select p.code,
         -- The name from whichever company uses that code; they are the
         -- same seeded chart, and where they are not, one of them has to
         -- win and it may as well be the first alphabetically.
         min(p.name),
         min(p.account_type),
         min(p.account_subtype),
         count(*)::integer,
         round(sum(p.opening_balance), 2),
         round(sum(p.debit), 2),
         round(sum(p.credit), 2),
         round(sum(p.closing_balance), 2)
    from per_company p
   group by p.code
  having sum(abs(p.opening_balance)) + sum(p.debit) + sum(p.credit) <> 0
   order by p.code;
end; $$;

revoke all on function public.report_group_trial_balance(uuid, date, date)
  from public, anon;
grant execute on function public.report_group_trial_balance(uuid, date, date)
  to authenticated;

-- ---------------------------------------------------------------------
-- What a consolidation would have to eliminate
--
-- Every balance and every amount of turnover between two companies in
-- the group, from both sides. An accountant reads this next to the
-- combined trial balance and knows exactly what the combination
-- overstates.
--
-- Both sides are shown rather than netted on purpose. When they do not
-- agree — and they routinely do not, because one side has posted the
-- invoice and the other has not yet received it — the difference is the
-- thing worth looking at, and netting hides it.
-- ---------------------------------------------------------------------
create or replace function public.report_group_intercompany(
  p_org_id uuid, p_from date default null, p_to date default current_date)
returns table (
  from_org_id    uuid,
  from_org       text,
  to_org_id      uuid,
  to_org         text,
  contact_id     uuid,
  contact_name   text,
  receivable     numeric,
  payable        numeric,
  revenue        numeric,
  expense        numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'You are not a member of this company'
      using errcode = '42501';
  end if;

  return query
  with orgs as (select g.org_id from app.group_orgs(p_org_id) g),
  lines as (
    select l.org_id, c.linked_org_id, c.id as contact_id, c.name as contact_name,
           a.account_type, a.account_subtype, l.debit, l.credit
      from public.gl_lines l
      join public.gl_entries e on e.id = l.entry_id
      join public.contacts c on c.id = l.contact_id
      join public.accounts a on a.id = l.account_id
     where l.org_id in (select org_id from orgs)
       and c.linked_org_id in (select org_id from orgs)
       and e.status = 'posted'
       and e.entry_date <= p_to
       and (p_from is null or e.entry_date >= p_from))
  select l.org_id, mine.name, l.linked_org_id, theirs.name,
         l.contact_id, l.contact_name,
         round(sum(case when l.account_subtype = 'accounts_receivable'
                        then l.debit - l.credit else 0 end), 2),
         round(sum(case when l.account_subtype = 'accounts_payable'
                        then l.credit - l.debit else 0 end), 2),
         round(sum(case when l.account_type = 'revenue'
                        then l.credit - l.debit else 0 end), 2),
         round(sum(case when l.account_type = 'expense'
                        then l.debit - l.credit else 0 end), 2)
    from lines l
    join public.organizations mine on mine.id = l.org_id
    join public.organizations theirs on theirs.id = l.linked_org_id
   group by l.org_id, mine.name, l.linked_org_id, theirs.name,
            l.contact_id, l.contact_name
  having sum(abs(l.debit)) + sum(abs(l.credit)) <> 0
   order by mine.name, theirs.name;
end; $$;

revoke all on function public.report_group_intercompany(uuid, date, date)
  from public, anon;
grant execute on function public.report_group_intercompany(uuid, date, date)
  to authenticated;
