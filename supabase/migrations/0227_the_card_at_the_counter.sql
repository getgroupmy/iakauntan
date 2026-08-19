-- ---------------------------------------------------------------------
-- 0227  Loyalty at the counter: finding the member, naming the sale,
--       and what the till is allowed to show
-- ---------------------------------------------------------------------
--
-- 0212 built the ledger and the two acts that move it —
-- `enrol_loyalty_member` and `redeem_loyalty_points` — and left them
-- with no caller. Wiring them to a screen turned out to need two things
-- that did not exist, both of which are the database's job rather than
-- the till's.
--
-- ## A cashier has a phone number, not a contact id
--
-- `loyalty_account_balance(contact)` answers the question you can only
-- ask once you already know who somebody is. At a counter you have what
-- the customer says: a card number, a mobile, or a name half-remembered.
-- `loyalty_lookup` takes that one string and searches all three.
--
-- The order matters. A card number is exact and is checked first, so
-- scanning a card never returns a list to choose from; the fuzzy
-- matches come after, and are capped, because a cashier holding up a
-- queue does not scroll.
--
-- ## Points come off a sale, and a sale has to know whose they are
--
-- `redeem_loyalty_points` reads `pos_sales.contact_id`, and until now
-- nothing could set it on a parked sale: the contact was passed when
-- the sale opened or when it completed, and neither is the moment a
-- customer produces a card. `name_pos_sale_customer` fills that gap and
-- refuses on anything but a parked sale, because renaming a completed
-- sale is changing who an issued invoice was made out to — which is
-- `request_einvoice_for_sale`'s job, with LHDN's rules attached.
--
-- ## One read for the whole panel
--
-- `pos_sale_member` returns the row the tender sheet draws: who is on
-- the bill, what they hold, what is already being redeemed against it,
-- and the two programme numbers the screen needs to stop somebody
-- asking for a redemption the rules will refuse. One round trip, so the
-- panel cannot show a name and a balance that disagree about which
-- customer they belong to.

-- ---------------------------------------------------------------------
-- Finding a member from what the customer said
-- ---------------------------------------------------------------------
create or replace function public.loyalty_lookup(
  p_org   uuid,
  p_query text)
returns table (
  account_id uuid,
  contact_id uuid,
  name       text,
  card_no    text,
  phone      text,
  points     integer,
  worth      numeric,
  matched_on text)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  with q as (select btrim(coalesce(p_query, '')) as t),
  hits as (
    select a.id as account_id,
           a.contact_id,
           c.name,
           a.card_no,
           coalesce(nullif(btrim(c.mobile), ''), nullif(btrim(c.phone), '')) as phone,
           app.loyalty_balance(a.id) as points,
           round(app.loyalty_balance(a.id) * p.redeem_value_per_point, 2) as worth,
           case
             when a.card_no is not null and lower(a.card_no) = lower((select t from q))
               then 'card'
             when coalesce(c.mobile, c.phone, '') like '%' || (select t from q) || '%'
               then 'phone'
             else 'name'
           end as matched_on
      from public.loyalty_accounts a
      join public.loyalty_programs p on p.id = a.program_id
      join public.contacts c on c.id = a.contact_id
     where a.org_id = p_org
       and a.is_active
       and p.is_active
       and c.deleted_at is null
       and (select length(t) from q) > 0
       and (
         lower(coalesce(a.card_no, '')) = lower((select t from q))
         or coalesce(c.mobile, '') like '%' || (select t from q) || '%'
         or coalesce(c.phone, '')  like '%' || (select t from q) || '%'
         or c.name ilike '%' || (select t from q) || '%')
       and app.can_read_module(a.org_id, 'pos'))
  select account_id, contact_id, name, card_no, phone, points, worth, matched_on
    from hits
   -- Exact before fuzzy. A scanned card is an answer, not a shortlist,
   -- and a cashier with a queue behind them does not scroll.
   order by case matched_on when 'card' then 0 when 'phone' then 1 else 2 end,
            name
   limit 20;
$$;

grant execute on function public.loyalty_lookup(uuid, text) to authenticated;

comment on function public.loyalty_lookup(uuid, text) is
  'Finds a member from a card number, a phone or part of a name. Exact card matches sort first, so scanning never returns a list to choose from.';

-- ---------------------------------------------------------------------
-- Saying whose bill this is
-- ---------------------------------------------------------------------
create or replace function public.name_pos_sale_customer(
  p_sale    uuid,
  p_contact uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale public.pos_sales;
  v_ok   boolean;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_sale.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;

  -- Only while it is still a basket. Once the sale has completed the
  -- name on it is the name on an issued invoice, and changing that is
  -- `request_einvoice_for_sale`, which carries LHDN's rules about who a
  -- document may be re-addressed to.
  if v_sale.status <> 'parked' then
    raise exception
      'That sale is already %. Naming the buyer on an issued invoice '
      'goes through the e-Invoice request instead.', v_sale.status
      using errcode = '23514';
  end if;

  -- Checked before anything is written. Points are held against an
  -- account, so a bill moved to a different customer while somebody
  -- else's points sit on it would be spending the wrong balance.
  -- `redeem_loyalty_points(sale, 0)` clears one, and it is a tap on the
  -- same panel — which is why this refuses rather than silently
  -- dropping the redemption.
  if v_sale.loyalty_points_redeemed > 0
     and v_sale.contact_id is distinct from p_contact then
    raise exception
      'Take the points off this bill before putting it under a '
      'different customer.'
      using errcode = '23514';
  end if;

  if p_contact is null then
    update public.pos_sales s set contact_id = null where s.id = p_sale;
    return p_sale;
  end if;

  select true into v_ok from public.contacts c
   where c.id = p_contact and c.org_id = v_sale.org_id
     and c.deleted_at is null;
  if not coalesce(v_ok, false) then
    raise exception 'No such customer.' using errcode = 'P0002';
  end if;

  update public.pos_sales s set contact_id = p_contact where s.id = p_sale;
  return p_sale;
end;
$$;

revoke all on function public.name_pos_sale_customer(uuid, uuid) from public, anon;
grant execute on function public.name_pos_sale_customer(uuid, uuid) to authenticated;

comment on function public.name_pos_sale_customer(uuid, uuid) is
  'Puts a customer on a parked sale, which is what loyalty redemption reads. Refuses once the sale has completed.';

-- ---------------------------------------------------------------------
-- The whole member panel, in one read
-- ---------------------------------------------------------------------
create or replace function public.pos_sale_member(p_sale uuid)
returns table (
  contact_id      uuid,
  contact_name    text,
  account_id      uuid,
  card_no         text,
  program         text,
  points          integer,
  worth           numeric,
  -- What the account will hold once this bill is paid. Shown beside
  -- `points` on purpose: `redeem_loyalty_points` records the intent on
  -- the sale and writes the ledger entries only at completion, so the
  -- balance is genuinely still the old one — and a panel that showed
  -- only that number next to "300 being used" would have the cashier
  -- telling the customer a figure they will not have.
  points_after    integer,
  -- What this bill is already taking, so the panel can show a
  -- redemption that has been applied rather than offering it twice.
  points_redeemed integer,
  discount        numeric,
  min_redeem      integer,
  value_per_point numeric,
  -- What the customer would earn by paying this bill as it stands.
  -- Shown because "and you'll get 75 points" is the reason somebody
  -- gives their number at all.
  --
  -- An estimate, and it says so on the screen. `pos_settle_loyalty`
  -- earns on what was actually paid, which includes the five-sen
  -- rounding — and the rounding is not decided until somebody says how
  -- much of the bill is cash. A number that pretended otherwise would
  -- be wrong by a point on the sales that round.
  would_earn      integer)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select c.id,
         c.name,
         a.id,
         a.card_no,
         p.name,
         case when a.id is null then 0 else app.loyalty_balance(a.id) end,
         case when a.id is null then 0
              else round(app.loyalty_balance(a.id) * p.redeem_value_per_point, 2)
         end,
         case when a.id is null then 0
              else app.loyalty_balance(a.id) - coalesce(s.loyalty_points_redeemed, 0)
         end,
         s.loyalty_points_redeemed,
         s.loyalty_discount,
         coalesce(p.min_redeem_points, 0),
         coalesce(p.redeem_value_per_point, 0),
         case when p.id is null then 0
              else floor(s.total_amount * p.earn_points_per_myr)::integer
         end
    from public.pos_sales s
    left join public.contacts c on c.id = s.contact_id
    -- The programme is the org's, not the account's: a bill with no
    -- member on it still has to be able to say what joining would be
    -- worth, and the panel offering enrolment is the one that says it.
    left join public.loyalty_programs p
           on p.org_id = s.org_id and p.is_active
    left join public.loyalty_accounts a
           on a.program_id = p.id and a.contact_id = c.id and a.is_active
   where s.id = p_sale
     and app.can_read_module(s.org_id, 'pos');
$$;

grant execute on function public.pos_sale_member(uuid) to authenticated;

comment on function public.pos_sale_member(uuid) is
  'Who is on a bill, what they hold, what this bill is already redeeming and what paying it would earn. One read, so the panel cannot show a name and a balance belonging to different customers.';
