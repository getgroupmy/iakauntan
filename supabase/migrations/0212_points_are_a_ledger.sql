-- Points: the thing a shop gives away that has to be counted anyway.
--
-- ## The ledger is the balance
--
-- A `points_balance` column on the customer is a counter, and a counter
-- is wrong the moment a row behind it is removed or a job runs twice.
-- Every other running total in this database is derived from its source
-- rows, and this one is no different: `loyalty_entries` is append-only
-- and the balance is their sum. Earning writes a positive row,
-- redeeming a negative one, and there is nothing to reconcile because
-- there is only one copy of the fact.
--
-- ## Redemption is a discount, not a tender
--
-- 0208 declared a `loyalty` tender kind, and using it would have been
-- the obvious move. It is the wrong one. A tender settles a debt with
-- money that lands in a named account; points are not money and land
-- nowhere. Recording redemption as a tender leaves the invoice at full
-- value and closes it with something that never reaches a bank, so the
-- books show revenue the shop was never paid.
--
-- Points reduce what is charged. That is a discount, it belongs on the
-- invoice, and `sales_documents.discount_amount` is the field the
-- schema already has for it -- which `prepare_einvoice` maps to the
-- MyInvois total discount, so LHDN is told the same number the customer
-- was charged. The tender kind stays declared and unused; a shop that
-- later wants gross revenue against a points liability can add the
-- accrual without moving anything built here.
--
-- ## What earns
--
-- The amount actually paid, after the redemption. Earning on the
-- pre-discount basket pays points for money nobody handed over, and
-- compounds: five hundred points off a hundred-ringgit basket would
-- earn points on the fifty that the points themselves covered. The test
-- asserts this specifically, because it is the arithmetic that looks
-- right either way until somebody works an example.
--
-- ## Expiry, and what this deliberately does not do
--
-- Points expire on dormancy: an account with no earning and no
-- redemption for the program's window loses its balance, in one entry,
-- on the date the sweep runs. That is a real policy and it is exactly
-- computable from the ledger.
--
-- It is NOT lot-level FIFO expiry -- "points earned in March expire in
-- March next year, oldest consumed first" -- which needs redemptions to
-- record which earning lots they drew down and is a larger thing than
-- this stage. Naming the column `dormancy_expiry_months` is the point:
-- a column called `expiry_months` would read as the rule this does not
-- implement.

-- ---------------------------------------------------------------------
-- The programme
-- ---------------------------------------------------------------------
create table if not exists public.loyalty_programs (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations (id) on delete cascade,
  code          text not null,
  name          text not null,

  -- Points per ringgit paid, and what one point is worth coming back.
  -- Two numbers rather than one rate, because a shop that gives 1 point
  -- per ringgit and redeems 100 points for RM1 is running a 1% scheme
  -- and should be able to see both halves of that.
  earn_points_per_myr    numeric(18, 4) not null default 1 check (earn_points_per_myr >= 0),
  redeem_value_per_point numeric(18, 4) not null default 0.01
                         check (redeem_value_per_point >= 0),
  min_redeem_points      integer not null default 0 check (min_redeem_points >= 0),

  -- Null means points do not expire. See the header for what this
  -- measures: time since the account last did anything, not time since
  -- a particular point was earned.
  dormancy_expiry_months integer check (dormancy_expiry_months > 0),

  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (org_id, code)
);

-- One live scheme at a time. Two would make "which points did that sale
-- earn" a question with no answer at the till.
create unique index if not exists loyalty_programs_one_active
  on public.loyalty_programs (org_id) where is_active;

create table if not exists public.loyalty_accounts (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  program_id  uuid not null references public.loyalty_programs (id) on delete cascade,
  contact_id  uuid not null references public.contacts (id) on delete cascade,
  card_no     text,
  joined_on   date not null default current_date,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (program_id, contact_id)
);

create unique index if not exists loyalty_accounts_card_no
  on public.loyalty_accounts (org_id, card_no) where card_no is not null;
create index if not exists loyalty_accounts_contact_idx
  on public.loyalty_accounts (contact_id);

-- The ledger. Append-only by policy and by grant: there is a read
-- policy and no write policy, so the only things that can add to it are
-- the SECURITY DEFINER functions below. A customer's balance is not
-- something a client should be able to type.
create table if not exists public.loyalty_entries (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  account_id  uuid not null references public.loyalty_accounts (id) on delete cascade,
  sale_id     uuid references public.pos_sales (id) on delete set null,
  kind        text not null check (kind in ('earn', 'redeem', 'adjust', 'expire')),
  points      integer not null,
  note        text,
  created_by  uuid references auth.users (id),
  created_at  timestamptz not null default now(),

  -- The signs are not decoration: they are what makes the balance a
  -- sum. An 'earn' that stored a negative number would read perfectly
  -- well on a screen and be wrong in the only place it matters.
  constraint loyalty_entries_sign_ck check (
    (kind = 'earn'   and points > 0) or
    (kind = 'redeem' and points < 0) or
    (kind = 'expire' and points < 0) or
    (kind = 'adjust' and points <> 0))
);

create index if not exists loyalty_entries_account_idx
  on public.loyalty_entries (account_id, created_at desc);
create index if not exists loyalty_entries_sale_idx
  on public.loyalty_entries (sale_id) where sale_id is not null;

create trigger set_updated_at before update on public.loyalty_programs
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------
-- What the basket owes the ledger
-- ---------------------------------------------------------------------
alter table public.pos_sales
  add column if not exists loyalty_account_id uuid
    references public.loyalty_accounts (id) on delete set null,
  add column if not exists loyalty_points_redeemed integer not null default 0
    check (loyalty_points_redeemed >= 0),
  add column if not exists loyalty_discount numeric(18, 2) not null default 0
    check (loyalty_discount >= 0),
  add column if not exists loyalty_points_earned integer not null default 0
    check (loyalty_points_earned >= 0);

comment on column public.pos_sales.loyalty_points_redeemed is
  'Points the customer put against this basket. Held here while the sale is parked; only written to the ledger when it completes.';

-- ---------------------------------------------------------------------
-- Balance: a sum, not a column
-- ---------------------------------------------------------------------
create or replace function app.loyalty_balance(p_account uuid)
returns integer
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select coalesce(sum(e.points), 0)::integer
    from public.loyalty_entries e where e.account_id = p_account;
$$;

revoke all on function app.loyalty_balance(uuid) from public, anon, authenticated;

-- The same number, for a screen, with who it belongs to.
create or replace function public.loyalty_account_balance(p_contact uuid)
returns table (
  account_id uuid,
  program    text,
  card_no    text,
  points     integer,
  worth      numeric,
  last_activity timestamptz)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select a.id, p.name, a.card_no,
         app.loyalty_balance(a.id),
         round(app.loyalty_balance(a.id) * p.redeem_value_per_point, 2),
         (select max(e.created_at) from public.loyalty_entries e where e.account_id = a.id)
    from public.loyalty_accounts a
    join public.loyalty_programs p on p.id = a.program_id
   where a.contact_id = p_contact
     and a.is_active
     and app.can_read_module(a.org_id, 'pos');
$$;

grant execute on function public.loyalty_account_balance(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Signing somebody up at the counter
-- ---------------------------------------------------------------------
create or replace function public.enrol_loyalty_member(
  p_contact uuid,
  p_card_no text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org     uuid;
  v_program uuid;
  v_account uuid;
begin
  select c.org_id into v_org from public.contacts c where c.id = p_contact;
  if v_org is null then
    raise exception 'No such customer.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;

  select p.id into v_program from public.loyalty_programs p
   where p.org_id = v_org and p.is_active;
  if v_program is null then
    raise exception
      'This company has no loyalty programme running.' using errcode = 'P0002';
  end if;

  -- Idempotent. A cashier who taps twice enrols one member, and gets
  -- back the account they already had rather than an error they have to
  -- explain to somebody holding a card.
  select a.id into v_account from public.loyalty_accounts a
   where a.program_id = v_program and a.contact_id = p_contact;
  if v_account is not null then
    if p_card_no is not null then
      update public.loyalty_accounts a set card_no = p_card_no where a.id = v_account;
    end if;
    return v_account;
  end if;

  insert into public.loyalty_accounts (org_id, program_id, contact_id, card_no)
  values (v_org, v_program, p_contact, p_card_no)
  returning id into v_account;
  return v_account;
end;
$$;

revoke all on function public.enrol_loyalty_member(uuid, text) from public, anon;
grant execute on function public.enrol_loyalty_member(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- Putting points against a basket
-- ---------------------------------------------------------------------
--
-- This does not touch the ledger. It records the intent on the sale and
-- lets the basket fall; the entries are written when the sale completes.
-- A parked sale that is abandoned has cost the customer nothing, which
-- is the only defensible behaviour: a balance that fell because a
-- cashier changed their mind is money taken for a transaction that
-- never happened.
create or replace function public.redeem_loyalty_points(
  p_sale   uuid,
  p_points integer)
returns table (
  points_applied integer,
  discount       numeric,
  new_total      numeric,
  -- What the account will hold once this sale completes. Not what it
  -- holds now: the ledger is untouched until then, and a till that
  -- said otherwise would be reporting a balance that does not exist.
  points_after   integer)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale    public.pos_sales;
  v_outlet  public.pos_outlets;
  v_program public.loyalty_programs;
  v_account uuid;
  v_contact uuid;
  v_balance integer;
  v_worth   numeric;
  v_basket  numeric;
  v_points  integer;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_sale.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if v_sale.status <> 'parked' then
    raise exception 'That sale is already %.', v_sale.status using errcode = '23514';
  end if;
  if p_points is null or p_points < 0 then
    raise exception 'Points redeemed cannot be negative.' using errcode = '23514';
  end if;

  select * into v_outlet from public.pos_outlets where id = v_sale.outlet_id;
  v_contact := coalesce(v_sale.contact_id, v_outlet.walk_in_contact_id);

  select * into v_program from public.loyalty_programs p
   where p.org_id = v_sale.org_id and p.is_active;
  if v_program.id is null then
    raise exception 'This company has no loyalty programme running.'
      using errcode = 'P0002';
  end if;

  select a.id into v_account from public.loyalty_accounts a
   where a.program_id = v_program.id and a.contact_id = v_contact and a.is_active;
  if v_account is null then
    raise exception
      'This sale is not on a member''s account. Say who the customer is first.'
      using errcode = 'P0002';
  end if;

  -- Zero clears a redemption that was applied and then thought better
  -- of, which is a thing that happens at a counter and should not need
  -- the sale to be voided.
  if p_points = 0 then
    update public.pos_sales s
       set loyalty_account_id = v_account,
           loyalty_points_redeemed = 0,
           loyalty_discount = 0
     where s.id = p_sale;
    perform app.recalc_pos_sale(p_sale);
    select s.total_amount into v_basket from public.pos_sales s where s.id = p_sale;
    points_applied := 0;
    discount := 0;
    new_total := v_basket;
    points_after := app.loyalty_balance(v_account);
    return next;
    return;
  end if;

  if p_points < v_program.min_redeem_points then
    raise exception
      'This programme redeems from % points.', v_program.min_redeem_points
      using errcode = '23514';
  end if;

  -- The balance is checked against the ledger, not against the column
  -- that would have been easier to read.
  v_balance := app.loyalty_balance(v_account);
  if p_points > v_balance then
    raise exception
      'That is % points and the account has %.', p_points, v_balance
      using errcode = '23514';
  end if;

  -- The basket before this redemption. Read from the lines rather than
  -- from `total_amount`, which already has any earlier redemption taken
  -- off it -- reading that would let two calls stack until the sale was
  -- free.
  select coalesce(sum(l.line_subtotal), 0) + coalesce(sum(l.tax_amount), 0)
    into v_basket from public.pos_sale_lines l where l.sale_id = p_sale;

  v_worth  := round(p_points * v_program.redeem_value_per_point, 2);
  v_points := p_points;

  -- Points cannot buy more than the basket. Rather than refuse, take
  -- only what is needed and leave the rest on the account: a customer
  -- who says "use my points" means "use what they are worth here".
  if v_worth > v_basket then
    -- Floor, not ceiling. Rounding the points up would take one more
    -- than the basket is worth and give nothing back for it, which is
    -- a sen-sized theft repeated on every over-redemption.
    v_points := least(
      floor(v_basket / nullif(v_program.redeem_value_per_point, 0))::integer,
      p_points);
    v_worth  := round(v_points * v_program.redeem_value_per_point, 2);
  end if;

  update public.pos_sales s
     set loyalty_account_id = v_account,
         loyalty_points_redeemed = v_points,
         loyalty_discount = v_worth
   where s.id = p_sale;

  perform app.recalc_pos_sale(p_sale);

  points_applied := v_points;
  discount := v_worth;
  select s.total_amount into new_total from public.pos_sales s where s.id = p_sale;
  points_after := v_balance - v_points;
  return next;
end;
$$;

revoke all on function public.redeem_loyalty_points(uuid, integer) from public, anon;
grant execute on function public.redeem_loyalty_points(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------
-- The ledger entries a completed sale owes
-- ---------------------------------------------------------------------
--
-- Called by `complete_pos_sale` and by nothing else. Split out so the
-- restatement below differs from 0209 by one line rather than by forty,
-- which is the difference between a diff somebody can check and one
-- they take on trust.
create or replace function app.pos_settle_loyalty(
  p_sale uuid,
  p_paid numeric)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale    public.pos_sales;
  v_program public.loyalty_programs;
  v_account uuid;
  v_earned  integer := 0;
begin
  select * into v_sale from public.pos_sales where id = p_sale;

  select * into v_program from public.loyalty_programs p
   where p.org_id = v_sale.org_id and p.is_active;
  if v_program.id is null then
    return;
  end if;

  v_account := v_sale.loyalty_account_id;
  if v_account is null then
    select a.id into v_account from public.loyalty_accounts a
     where a.program_id = v_program.id
       and a.contact_id = v_sale.contact_id
       and a.is_active;
  end if;
  if v_account is null then
    return;                       -- the walk-in earns nothing
  end if;

  -- The redemption, now that the sale is real. Checked again against
  -- the ledger: the basket may have been parked for an hour, and the
  -- customer may have spent the same points at the other till.
  if coalesce(v_sale.loyalty_points_redeemed, 0) > 0 then
    if v_sale.loyalty_points_redeemed > app.loyalty_balance(v_account) then
      raise exception
        'Those points are no longer on the account. Take the redemption '
        'off and ring the sale up again.'
        using errcode = '23514';
    end if;
    insert into public.loyalty_entries
      (org_id, account_id, sale_id, kind, points, note, created_by)
    values (v_sale.org_id, v_account, p_sale, 'redeem',
            -v_sale.loyalty_points_redeemed,
            'Redeemed on ' || v_sale.sale_no, v_sale.sold_by);
  end if;

  -- Earned on what was actually paid. See the header: earning on the
  -- pre-discount basket pays points for money nobody handed over.
  v_earned := floor(greatest(coalesce(p_paid, 0), 0) * v_program.earn_points_per_myr)::integer;
  if v_earned > 0 then
    insert into public.loyalty_entries
      (org_id, account_id, sale_id, kind, points, note, created_by)
    values (v_sale.org_id, v_account, p_sale, 'earn', v_earned,
            'Earned on ' || v_sale.sale_no, v_sale.sold_by);
  end if;

  update public.pos_sales s
     set loyalty_account_id = v_account,
         loyalty_points_earned = v_earned
   where s.id = p_sale;
end;
$$;

revoke all on function app.pos_settle_loyalty(uuid, numeric) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- A points adjustment somebody has to sign for
-- ---------------------------------------------------------------------
create or replace function public.adjust_loyalty_points(
  p_account uuid,
  p_points  integer,
  p_note    text)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org uuid;
begin
  select a.org_id into v_org from public.loyalty_accounts a where a.id = p_account;
  if v_org is null then
    raise exception 'No such loyalty account.' using errcode = 'P0002';
  end if;
  -- Deliberately narrower than selling. Handing out points is handing
  -- out money, and a cashier who can do it unwitnessed is a control
  -- nobody has.
  if not app.can_admin(v_org) then
    raise exception 'Only an owner or admin can adjust points.'
      using errcode = '42501';
  end if;
  if p_points = 0 then
    raise exception 'An adjustment of nothing is not an adjustment.'
      using errcode = '23514';
  end if;
  if nullif(btrim(coalesce(p_note, '')), '') is null then
    raise exception 'Say why. An unexplained adjustment is the one the '
      'auditor asks about.' using errcode = '23514';
  end if;
  if p_points < 0 and -p_points > app.loyalty_balance(p_account) then
    raise exception 'That would take the account below zero.'
      using errcode = '23514';
  end if;

  insert into public.loyalty_entries
    (org_id, account_id, kind, points, note, created_by)
  values (v_org, p_account, 'adjust', p_points, btrim(p_note), auth.uid());

  return app.loyalty_balance(p_account);
end;
$$;

revoke all on function public.adjust_loyalty_points(uuid, integer, text) from public, anon;
grant execute on function public.adjust_loyalty_points(uuid, integer, text) to authenticated;

-- ---------------------------------------------------------------------
-- The dormancy sweep
-- ---------------------------------------------------------------------
--
-- Writes one entry per account it clears, so the balance stays a sum
-- and the customer can be shown why it fell. Idempotent: an account
-- already at zero has nothing to expire, so running it twice in a day
-- writes nothing the second time.
create or replace function public.expire_loyalty_points(p_org uuid)
returns table (
  account_id uuid,
  contact    text,
  points     integer,
  last_activity timestamptz)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_program public.loyalty_programs;
  v_row     record;
  v_balance integer;
begin
  if not app.can_admin(p_org) then
    raise exception 'Only an owner or admin can expire points.'
      using errcode = '42501';
  end if;

  select * into v_program from public.loyalty_programs p
   where p.org_id = p_org and p.is_active;
  if v_program.id is null or v_program.dormancy_expiry_months is null then
    return;                       -- nothing expires
  end if;

  for v_row in
    select a.id, c.name as contact_name,
           coalesce(max(e.created_at), a.joined_on::timestamptz) as last_at
      from public.loyalty_accounts a
      join public.contacts c on c.id = a.contact_id
      left join public.loyalty_entries e on e.account_id = a.id
     where a.program_id = v_program.id
     group by a.id, c.name, a.joined_on
    having coalesce(max(e.created_at), a.joined_on::timestamptz)
             < now() - make_interval(months => v_program.dormancy_expiry_months)
  loop
    v_balance := app.loyalty_balance(v_row.id);
    if v_balance <= 0 then
      continue;
    end if;
    insert into public.loyalty_entries
      (org_id, account_id, kind, points, note, created_by)
    values (p_org, v_row.id, 'expire', -v_balance,
            format('Dormant since %s', to_char(v_row.last_at, 'DD Mon YYYY')),
            auth.uid());

    account_id := v_row.id;
    contact := v_row.contact_name;
    points := v_balance;
    last_activity := v_row.last_at;
    return next;
  end loop;
end;
$$;

revoke all on function public.expire_loyalty_points(uuid) from public, anon;
grant execute on function public.expire_loyalty_points(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
alter table public.loyalty_programs enable row level security;
alter table public.loyalty_accounts enable row level security;
alter table public.loyalty_entries  enable row level security;

create policy loyalty_programs_read on public.loyalty_programs for select
  to authenticated using (app.can_read_module(org_id, 'pos'));
create policy loyalty_programs_write on public.loyalty_programs for all
  to authenticated using (app.can_admin(org_id)) with check (app.can_admin(org_id));

create policy loyalty_accounts_read on public.loyalty_accounts for select
  to authenticated using (app.can_read_module(org_id, 'pos'));
create policy loyalty_accounts_write on public.loyalty_accounts for all
  to authenticated using (app.can_write_module(org_id, 'pos'))
  with check (app.can_write_module(org_id, 'pos'));

-- Read only. There is no write policy on purpose: a balance a client
-- could type is not a balance.
create policy loyalty_entries_read on public.loyalty_entries for select
  to authenticated using (app.can_read_module(org_id, 'pos'));

grant select, insert, update, delete on public.loyalty_programs to authenticated;
grant select, insert, update, delete on public.loyalty_accounts to authenticated;
grant select on public.loyalty_entries to authenticated;

-- ---------------------------------------------------------------------
-- The two functions from 0209 that had to learn about this
-- ---------------------------------------------------------------------
create or replace function app.recalc_pos_sale(p_sale uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_sub numeric; v_tax numeric; v_disc numeric; v_loy numeric;
begin
  select coalesce(sum(l.line_subtotal), 0),
         coalesce(sum(l.tax_amount), 0),
         coalesce(sum(l.discount_amount), 0)
    into v_sub, v_tax, v_disc
    from public.pos_sale_lines l where l.sale_id = p_sale;

  -- Points already put against this basket. Read here rather than
  -- passed in, so every path that recalculates a sale -- adding a line,
  -- removing one, changing a quantity -- keeps the redemption applied
  -- instead of quietly dropping it.
  select coalesce(s.loyalty_discount, 0) into v_loy
    from public.pos_sales s where s.id = p_sale;

  update public.pos_sales s
     set subtotal = v_sub,
         tax_amount = v_tax,
         discount_amount = v_disc,
         -- The exact basket. Rounding is decided at tender time and
         -- written then, because until somebody chooses how to pay
         -- there is no answer to give.
         -- Never below zero: points cannot buy more than the basket
         -- and hand back the difference in cash.
         total_amount = greatest(round(v_sub + v_tax - v_loy, 2), 0)
   where s.id = p_sale;
end;
$$;

create or replace function public.complete_pos_sale(
  p_sale    uuid,
  p_tenders jsonb,
  p_contact uuid default null)
returns table (
  sale_id     uuid,
  invoice_no  text,
  total       numeric,
  cash_due    numeric,
  change_due  numeric,
  rounding    numeric)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale     public.pos_sales;
  v_outlet   public.pos_outlets;
  v_round    boolean;
  v_noncash  numeric := 0;
  v_cashin   numeric := 0;
  v_cashdue  numeric;
  v_adj      numeric;
  v_change   numeric;
  v_contact  uuid;
  v_inv      uuid;
  v_rcp      uuid;
  v_no       text;
  v_line     record;
  v_t        record;
  v_n        integer := 0;
  v_kind     app.pos_tender_kind;
  v_bank     uuid;
  v_mode     text;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_sale.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if v_sale.status <> 'parked' then
    raise exception 'That sale is already %.', v_sale.status
      using errcode = '23514';
  end if;
  -- Aliased, because `sale_id` is also an OUT parameter of this
  -- function and plpgsql cannot tell which one an unqualified reference
  -- means. It refuses rather than guessing, which is the right choice
  -- and only says so at run time.
  if not exists (select 1 from public.pos_sale_lines l where l.sale_id = p_sale) then
    raise exception 'There is nothing on this sale to pay for.'
      using errcode = '23514';
  end if;

  select * into v_outlet from public.pos_outlets where id = v_sale.outlet_id;
  select coalesce(ps.round_cash_to_5sen, true) into v_round
    from public.pos_settings ps where ps.org_id = v_sale.org_id;
  v_round := coalesce(v_round, true);

  -- --------------------------------------------------------------
  -- What is being paid with what
  -- --------------------------------------------------------------
  for v_t in
    select (e ->> 'type')::uuid   as type_id,
           (e ->> 'amount')::numeric as amount,
            e ->> 'reference'     as reference
      from jsonb_array_elements(coalesce(p_tenders, '[]'::jsonb)) e
  loop
    if v_t.amount is null or v_t.amount <= 0 then
      raise exception 'A tender needs an amount.' using errcode = '23514';
    end if;
    select tt.kind into v_kind from public.pos_tender_types tt
     where tt.id = v_t.type_id and tt.org_id = v_sale.org_id and tt.is_active;
    if v_kind is null then
      raise exception 'That is not a tender this company accepts.'
        using errcode = 'P0002';
    end if;
    if v_kind = 'cash' then
      v_cashin := v_cashin + v_t.amount;
    else
      v_noncash := v_noncash + v_t.amount;
    end if;
    v_n := v_n + 1;
  end loop;

  -- A basket covered entirely by points has nothing left to tender,
  -- and that is a completed sale rather than an unpaid one. Without
  -- this, a customer with enough points to clear the till could put
  -- them all against the basket and then find the sale could not be
  -- rung up at all -- a dead end reachable from the screen that offers
  -- the redemption.
  if v_n = 0 and v_sale.total_amount > 0 then
    raise exception 'A sale has to be paid for.' using errcode = '23514';
  end if;

  -- 0208's rule: round what is left after everything that is not cash.
  v_cashdue := app.pos_cash_due(v_sale.total_amount, v_noncash, v_round);
  v_adj     := app.pos_rounding_adjustment(v_sale.total_amount, v_noncash, v_round);
  v_change  := round(v_cashin - v_cashdue, 2);

  if v_change < 0 then
    raise exception
      'Short by %. The customer still owes that much.', -v_change
      using errcode = '23514';
  end if;
  -- Non-cash cannot over-pay: a card charged more than the basket is a
  -- refund waiting to happen, not a sale.
  if v_noncash > v_sale.total_amount + 0.005 and v_cashin = 0 then
    raise exception
      'That is more than the basket comes to. Charge the card the right '
      'amount, or take the difference as a refund.'
      using errcode = '23514';
  end if;

  v_contact := coalesce(p_contact, v_sale.contact_id, v_outlet.walk_in_contact_id);
  if v_contact is null then
    raise exception
      'This outlet has no walk-in customer set, so an anonymous sale has '
      'nobody to bill. Set one on the outlet.'
      using errcode = '23502';
  end if;

  -- --------------------------------------------------------------
  -- The invoice
  -- --------------------------------------------------------------
  v_no := app.next_document_number_internal(v_sale.org_id, 'invoice');

  -- No salesperson. `sales_documents.salesperson_id` points at
  -- `public.salespeople` — a commission record — and not at the user
  -- who rang the sale up. A cashier is not automatically one of those,
  -- and 0105 has a trigger that says so. Who served the customer is on
  -- `pos_sales.sold_by`, which is the right place for it; a shop that
  -- pays counter commission can map the two later.
  insert into public.sales_documents (
    org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
    exchange_rate, status, notes, created_by)
  values (
    v_sale.org_id, 'invoice', v_no, current_date, current_date, v_contact,
    'MYR', 1, 'draft',
    'Counter sale ' || v_sale.sale_no, v_sale.sold_by)
  returning id into v_inv;

  for v_line in
    select * from public.pos_sale_lines l where l.sale_id = p_sale order by l.line_no
  loop
    insert into public.sales_document_lines (
      org_id, document_id, line_no, line_type, item_id, description,
      quantity, uom_code, unit_price, discount_amount, tax_code_id,
      tax_rate, is_tax_inclusive, warehouse_id)
    values (
      v_sale.org_id, v_inv, v_line.line_no, 'item', v_line.item_id,
      v_line.description, v_line.quantity, v_line.uom_code,
      v_line.unit_price, v_line.discount_amount, v_line.tax_code_id,
      v_line.tax_rate, v_line.is_tax_inclusive, v_line.warehouse_id);
  end loop;

  -- After the lines, because the totals trigger fires on line changes
  -- and would otherwise impose the organization's rounding on a card
  -- sale. See the header: this is POS taking a number the trigger
  -- normally owns, and the test asserts the result.
  update public.sales_documents d
     set rounding_amount = v_adj,
         -- The redemption, on the header rather than spread across the
         -- lines. `sales_documents.discount_amount` is exactly the
         -- field for a discount that belongs to the document, and
         -- `prepare_einvoice` already maps it to the MyInvois total
         -- discount, so what LHDN is told matches what was charged.
         discount_amount = coalesce(v_sale.loyalty_discount, 0),
         total_amount    = round(v_sale.total_amount + v_adj, 2),
         base_total_amount = round(v_sale.total_amount + v_adj, 2),
         balance_amount  = round(v_sale.total_amount + v_adj, 2)
   where d.id = v_inv;

  perform app.post_sales_document_internal(v_inv);

  -- --------------------------------------------------------------
  -- The receipt, and the debt closing behind it
  -- --------------------------------------------------------------
  -- Banked against the first tender's account. A shop splitting one
  -- sale across two accounts is real and is not this migration's
  -- problem; what matters here is that the money lands somewhere named
  -- rather than in the current account by default.
  select tt.bank_account_id, tt.payment_mode_code
    into v_bank, v_mode
    from public.pos_tender_types tt
   where tt.id = ((p_tenders -> 0) ->> 'type')::uuid;

  v_no := app.next_document_number_internal(v_sale.org_id, 'receipt');

  insert into public.receipts (
    org_id, receipt_no, receipt_date, contact_id, payment_mode_code,
    bank_account_id, currency, exchange_rate, amount, base_amount,
    status, notes, created_by)
  values (
    v_sale.org_id, v_no, current_date, v_contact, v_mode, v_bank,
    'MYR', 1,
    round(v_sale.total_amount + v_adj, 2),
    round(v_sale.total_amount + v_adj, 2),
    'draft', 'Counter sale ' || v_sale.sale_no, v_sale.sold_by)
  returning id into v_rcp;

  -- Only when there is something to allocate. `payment_allocations`
  -- checks that its amount is positive, and it is right to: an
  -- allocation of nothing is not an allocation. A basket cleared by
  -- points leaves an invoice for zero, which already owes nothing, so
  -- there is nothing for a receipt to settle against it.
  if round(v_sale.total_amount + v_adj, 2) > 0 then
    insert into public.payment_allocations
      (org_id, receipt_id, invoice_id, amount, allocated_by)
    values
      (v_sale.org_id, v_rcp, v_inv, round(v_sale.total_amount + v_adj, 2),
       v_sale.sold_by);
  end if;

  perform app.post_receipt_internal(v_rcp);

  -- --------------------------------------------------------------
  -- And the tenders, now that they are known to be good
  -- --------------------------------------------------------------
  for v_t in
    select (e ->> 'type')::uuid as type_id,
           (e ->> 'amount')::numeric as amount,
            e ->> 'reference' as reference,
           row_number() over () as rn,
           count(*) over () as total_rows
      from jsonb_array_elements(p_tenders) e
  loop
    select tt.kind into v_kind from public.pos_tender_types tt
     where tt.id = v_t.type_id;
    insert into public.pos_tenders
      (org_id, sale_id, tender_type_id, kind, amount, change_given, reference)
    values
      (v_sale.org_id, p_sale, v_t.type_id, v_kind, v_t.amount,
       -- Change comes out of the last tender offered, which is the one
       -- the customer is standing there waiting for.
       case when v_t.rn = v_t.total_rows then v_change else 0 end,
       v_t.reference);
  end loop;

  update public.pos_sales s
     set status = 'completed',
         completed_at = now(),
         contact_id = v_contact,
         rounding_amount = v_adj,
         total_amount = round(v_sale.total_amount + v_adj, 2),
         invoice_id = v_inv,
         receipt_id = v_rcp
   where s.id = p_sale;

  -- --------------------------------------------------------------
  -- And the points, last
  -- --------------------------------------------------------------
  -- Nothing above this line touches the loyalty ledger. A parked sale
  -- holds no points: it can be abandoned, and a customer whose balance
  -- fell when a cashier changed their mind has been robbed by a
  -- transaction that never happened.
  perform app.pos_settle_loyalty(p_sale, round(v_sale.total_amount + v_adj, 2));

  sale_id := p_sale;
  select d.doc_no into invoice_no from public.sales_documents d where d.id = v_inv;
  -- Scaled to the sen on the way out. `numeric` with no declared scale
  -- is exact and prints as 10.8500000000000000, which reaches the till
  -- as a string and is the one number a customer reads back off a
  -- receipt. Correct is not the same as legible.
  total := round(v_sale.total_amount + v_adj, 2);
  cash_due := round(v_cashdue, 2);
  change_due := round(v_change, 2);
  rounding := round(v_adj, 2);
  return next;
end;
$$;
