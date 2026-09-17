-- =====================================================================
-- iAkauntan :: 0625 a rule that reads the bank line
--
-- The bank half of this product is further along than it looks.
-- `statement_import.dart` reads CSV by header name and MT940 from the
-- specification; `bank_transactions` holds the lines with
-- `is_reconciled`, `matched_table` and `matched_id` already on them;
-- `complete_bank_reconciliation` closes a period and refuses a repeat.
-- What has never existed is the step between: something that looks at
-- "GIRO TNB BILL PAYMENT" and knows it is electricity.
--
-- So a bookkeeper imports two hundred lines and codes two hundred lines
-- by hand, every month, against the same twenty descriptions. That is
-- the single biggest recurring cost in SME bookkeeping and it is what
-- every cloud package competes on.
--
-- ---------------------------------------------------------------------
-- This migration SUGGESTS. It does not post.
--
-- Deliberately, and the line is worth drawing in the schema rather than
-- in a screen. Everything here is `stable` and reads; nothing writes a
-- journal, creates a voucher or sets `matched_id`. A rule that posted
-- would be a rule that posts a mistake two hundred times before anybody
-- reads the first one.
--
-- Applying a suggestion is a separate migration and a separate
-- decision, and it will want an audit trail this one does not need.
--
-- ---------------------------------------------------------------------
-- Two constraints that are the whole design
--
--   * `bank_rules_says_something` -- a rule with no condition matches
--     every line on the statement. It reads as an empty form and
--     behaves as a catch-all, which is the worst thing a rule can be.
--   * `bank_rules_does_something` -- a rule with no action is a rule
--     that matches and then does nothing, which is indistinguishable
--     from no rule at all except that somebody believes it works.
--
-- Both are silent. Neither would ever raise at run time. They are
-- constraints because "the form should validate it" is a rule that
-- holds until somebody writes a row another way.
--
-- ---------------------------------------------------------------------
-- Direction is derived, never stored twice
--
-- `bank_transactions.amount` is signed -- positive is money in -- and
-- `transaction_type` is a label that came off the statement. A rule
-- says `in` or `out` and that is compared against the SIGN, because a
-- statement that calls a refund a "deposit" and one that calls it
-- "other" must match the same rule.
-- =====================================================================

create table public.bank_rules (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,

  name text not null,

  -- Lower first. Ties broken by id so the order is total and a
  -- suggestion does not change between two reads.
  sort_order integer not null default 100,
  is_active boolean not null default true,

  -- ------------------------------------------------------------------
  -- Conditions. All optional, all ANDed, all case-insensitive.
  -- ------------------------------------------------------------------

  -- Null means every account. A rule about a card statement should not
  -- fire on the current account.
  bank_account_id uuid,

  direction text check (direction in ('in', 'out')),
  description_contains text,
  reference_contains text,
  amount_min numeric(18, 2),
  amount_max numeric(18, 2),

  -- ------------------------------------------------------------------
  -- What to suggest when it matches.
  -- ------------------------------------------------------------------
  account_id uuid,
  contact_id uuid,
  tax_code_id uuid,
  memo text,

  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint bank_rules_says_something check (
    description_contains is not null
    or reference_contains is not null
    or amount_min is not null
    or amount_max is not null
    or direction is not null
    or bank_account_id is not null),

  constraint bank_rules_does_something check (
    account_id is not null
    or contact_id is not null
    or tax_code_id is not null),

  -- An amount window that cannot contain anything is a rule that will
  -- never fire, written by somebody who thinks it will.
  constraint bank_rules_window_is_a_window check (
    amount_min is null or amount_max is null or amount_min <= amount_max),

  -- Every reference is the same-org composite `0513` and `0514`
  -- established, not the plain key. A rule that coded one company's
  -- bank lines to another company's expense account would be a
  -- cross-tenant leak written by autocomplete, and
  -- `tenant_foreign_keys.sql` fails the build over exactly this.
  constraint bank_rules_bank_same_org
    foreign key (org_id, bank_account_id)
    references public.bank_accounts (org_id, id) on delete cascade,
  constraint bank_rules_account_same_org
    foreign key (org_id, account_id)
    references public.accounts (org_id, id) on delete restrict,
  -- `set null (column)` rather than a bare `set null`: the reference is
  -- a PAIR, and nulling the pair would null `org_id`, which is not
  -- nullable. Naming the column is what makes "the contact went, the
  -- rule stays" expressible at all, and `tenant_foreign_keys.sql`
  -- refuses the bare form for precisely that reason.
  constraint bank_rules_contact_same_org
    foreign key (org_id, contact_id)
    references public.contacts (org_id, id) on delete set null (contact_id),
  constraint bank_rules_tax_code_same_org
    foreign key (org_id, tax_code_id)
    references public.tax_codes (org_id, id) on delete set null (tax_code_id)
);

comment on table public.bank_rules is
  'What a bank line means, matched on its words and its amount. Reads '
  'only: 0625 suggests a coding and posts nothing. 0625.';

create index bank_rules_order_idx
  on public.bank_rules (org_id, sort_order, id) where is_active;

create trigger set_updated_at before update on public.bank_rules
  for each row execute function app.set_updated_at();

alter table public.bank_rules enable row level security;

create policy bank_rules_read on public.bank_rules
  for select to authenticated using (app.can_read_ledger(org_id));
create policy bank_rules_write on public.bank_rules
  for all to authenticated
  using (app.can_post(org_id)) with check (app.can_post(org_id));

grant select, insert, update, delete on public.bank_rules to authenticated;
revoke all on public.bank_rules from anon;

-- ---------------------------------------------------------------------
-- Does this rule describe this line?
--
-- One function, so the list screen, the suggestion and the coverage
-- count cannot drift apart. Three implementations of a matching rule
-- is three answers to "why did it not fire".
-- ---------------------------------------------------------------------
create or replace function app.bank_rule_matches(
  p_rule public.bank_rules,
  p_txn public.bank_transactions)
returns boolean
language sql
immutable
-- Pinned even though this reads no table: `search_path.sql` asks it of
-- every function in `app` and `public` without exception, and an
-- exception is how the next one that DOES read a table gets missed.
set search_path = public, pg_temp
as $$
  select p_rule.is_active
     and (p_rule.bank_account_id is null
          or p_rule.bank_account_id = p_txn.bank_account_id)
     -- Against the sign, not against `transaction_type`: see the
     -- header. A statement that calls a refund a deposit and one that
     -- calls it other have to match the same rule.
     and (p_rule.direction is null
          or (p_rule.direction = 'in' and p_txn.amount > 0)
          or (p_rule.direction = 'out' and p_txn.amount < 0))
     and (p_rule.description_contains is null
          or coalesce(p_txn.description, '')
             ilike '%' || p_rule.description_contains || '%')
     and (p_rule.reference_contains is null
          or coalesce(p_txn.reference, '')
             ilike '%' || p_rule.reference_contains || '%')
     -- The window is compared against the SIZE of the line. A rule
     -- saying "between 50 and 200" is about two hundred ringgit
     -- whichever way it went, and asking somebody to write -200 to -50
     -- for a payment is asking them to get it wrong.
     and (p_rule.amount_min is null or abs(p_txn.amount) >= p_rule.amount_min)
     and (p_rule.amount_max is null or abs(p_txn.amount) <= p_rule.amount_max);
$$;

-- ---------------------------------------------------------------------
-- What the rules say about one line
-- ---------------------------------------------------------------------
create or replace function public.suggest_bank_coding(p_transaction_id uuid)
returns table (
  rule_id uuid,
  rule_name text,
  account_id uuid,
  account_code text,
  account_name text,
  contact_id uuid,
  contact_name text,
  tax_code_id uuid,
  memo text)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare v_txn public.bank_transactions;
begin
  select * into v_txn from public.bank_transactions t where t.id = p_transaction_id;
  if v_txn.id is null then
    raise exception 'No such bank line.' using errcode = '22023';
  end if;
  if not app.can_read_ledger(v_txn.org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  -- The FIRST match, not every match. A bookkeeper orders the rules
  -- and expects the order to decide; handing back four suggestions is
  -- handing the decision back.
  return query
    select r.id, r.name, r.account_id, a.code, a.name,
           r.contact_id, c.name, r.tax_code_id, r.memo
      from public.bank_rules r
      left join public.accounts a on a.id = r.account_id
      left join public.contacts c on c.id = r.contact_id
     where r.org_id = v_txn.org_id
       and app.bank_rule_matches(r, v_txn)
     order by r.sort_order, r.id
     limit 1;
end $$;

revoke all on function public.suggest_bank_coding(uuid) from public, anon;
grant execute on function public.suggest_bank_coding(uuid) to authenticated;

comment on function public.suggest_bank_coding(uuid) is
  'The first rule that describes this bank line, and what it says to '
  'code it as. Suggests; writes nothing. 0625.';

-- ---------------------------------------------------------------------
-- What a rule would do to the statement in front of you
--
-- The affordance that makes a rule safe to write. A rule is a pattern
-- somebody guesses at, and the question immediately after writing one
-- is "how many lines does that catch, and are they the ones I meant".
-- Without an answer the only way to find out is to apply it.
--
-- Counts only lines no earlier rule has already claimed, because that
-- is what the rule will actually see.
-- ---------------------------------------------------------------------
create or replace function public.bank_rule_coverage(
  p_org_id uuid,
  p_bank_account_id uuid default null)
returns table (
  rule_id uuid,
  rule_name text,
  sort_order integer,
  is_active boolean,
  matches bigint)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.can_read_ledger(p_org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  return query
  with lines as (
    select t.* from public.bank_transactions t
     where t.org_id = p_org_id
       and not t.is_reconciled
       and (p_bank_account_id is null
            or t.bank_account_id = p_bank_account_id)
  ),
  claimed as (
    select l.id as txn_id,
           (select r.id from public.bank_rules r
             where r.org_id = p_org_id
               and app.bank_rule_matches(r, l)
             order by r.sort_order, r.id
             limit 1) as rule_id
      from lines l
  )
  select r.id, r.name, r.sort_order, r.is_active,
         count(cl.txn_id)
    from public.bank_rules r
    left join claimed cl on cl.rule_id = r.id
   where r.org_id = p_org_id
   group by r.id, r.name, r.sort_order, r.is_active
   order by r.sort_order, r.id;
end $$;

revoke all on function public.bank_rule_coverage(uuid, uuid) from public, anon;
grant execute on function public.bank_rule_coverage(uuid, uuid) to authenticated;

comment on function public.bank_rule_coverage(uuid, uuid) is
  'How many unreconciled lines each rule would claim, counting only '
  'the ones no earlier rule takes first. What makes a rule safe to '
  'write. 0625.';

-- ---------------------------------------------------------------------
-- And how much of the statement nothing explains
--
-- The number that says whether the rules are worth having. A screen
-- that shows only what matched cannot tell a bookkeeper that a hundred
-- and forty lines still need typing.
-- ---------------------------------------------------------------------
create or replace function public.bank_lines_unexplained(
  p_org_id uuid,
  p_bank_account_id uuid default null)
returns bigint
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare v_n bigint;
begin
  if not app.can_read_ledger(p_org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  select count(*) into v_n
    from public.bank_transactions t
   where t.org_id = p_org_id
     and not t.is_reconciled
     and t.matched_id is null
     and (p_bank_account_id is null
          or t.bank_account_id = p_bank_account_id)
     and not exists (
       select 1 from public.bank_rules r
        where r.org_id = p_org_id and app.bank_rule_matches(r, t));
  return v_n;
end $$;

revoke all on function public.bank_lines_unexplained(uuid, uuid)
  from public, anon;
grant execute on function public.bank_lines_unexplained(uuid, uuid)
  to authenticated;

comment on function public.bank_lines_unexplained(uuid, uuid) is
  'Unreconciled bank lines that no rule describes and nothing is '
  'matched to -- the ones still to be typed. 0625.';

-- ---------------------------------------------------------------------
-- And onto the change feed
--
-- `0547` wakes every screen watching a company when one of its tables
-- moves, and `live_change_feed.sql` fails the build on a table with an
-- `org_id` that is missing the triggers. `bank_rules` earns them: it is
-- edited by a person, two bookkeepers can be on the reconciliation
-- screen at once, and a rule added by one should change what the other
-- sees. It is not a read-receipt table, which is the only exception
-- that list keeps.
-- ---------------------------------------------------------------------
create trigger live_change_insert after insert on public.bank_rules
  referencing new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_update after update on public.bank_rules
  referencing old table as old_rows new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_delete after delete on public.bank_rules
  referencing old table as old_rows
  for each statement execute function app.note_live_change();

do $do$
begin
  if not has_function_privilege('authenticated',
       'public.suggest_bank_coding(uuid)', 'execute')
     or not has_function_privilege('authenticated',
       'public.bank_rule_coverage(uuid, uuid)', 'execute')
     or not has_function_privilege('authenticated',
       'public.bank_lines_unexplained(uuid, uuid)', 'execute') then
    raise exception 'A bank rule is reachable by nobody.';
  end if;
  if not has_table_privilege('authenticated', 'public.bank_rules', 'select')
  then
    raise exception 'bank_rules has a policy and no grant to reach it.';
  end if;
end
$do$;
