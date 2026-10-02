-- =====================================================================
-- iAkauntan :: 0732 a shop can say where its money goes
--
-- `0731` gave `pos_tender_types.bank_account_id` a rule -- the till for
-- cash, the settlement account for a card -- and wrote the answer onto
-- the row. It also recorded why all thirteen rows in production were
-- null: **there is no screen for editing a tender type.** They are read
-- by the till and written only by demo seeders, so "or into another
-- account where one is defined" was a half of the rule nobody could
-- reach.
--
-- This is the other half: an upsert and a delete, and the screen that
-- calls them. The table has had a write policy and a grant since
-- `0208`, so the client could in principle have written it directly --
-- and this is a function instead for the reason `CLAUDE.md` gives: a
-- rule enforced only in Dart is not enforced. Everything below is
-- asserted in `supabase/tests/pos_tender_types.sql`.
--
-- ## Two kinds where no money arrives
--
-- `0731`'s trigger fills the account for any tender that is not a
-- drawer. That was wrong for two of the seven kinds, and the editor is
-- what made it obvious:
--
--   `on_account` is the customer owing it. Nothing is handed over, and
--     `complete_pos_sale` takes a basket that is wholly on account and
--     writes no receipt at all. An account on that row would say money
--     reached a bank.
--   `loyalty` is points coming off the basket. The sale ends at zero
--     and `0212` gives it a receipt for zero so it is a completed sale
--     rather than a stuck one -- but no money moved, and
--     `app.post_receipt_internal` resolves an account for that zero
--     itself, so the tender does not need one.
--
-- A VOUCHER is deliberately not in that list. A voucher the shop sold
-- was paid for when it was sold; one a third party issued is settled by
-- the issuer later, which is money arriving. Which of those a shop
-- means is a question for the shop, so the rule stays "the default,
-- and change it if that is wrong" rather than a guess written into the
-- schema.
--
-- ## What the editor cannot do, and why
--
-- It cannot clear the account on a tender that takes money. The
-- trigger fills it again, by design: money has to land somewhere, and
-- a till whose takings land nowhere is the defect this series spent
-- three days removing. The screen says so rather than offering a
-- control that quietly undoes itself.
--
-- It cannot delete a tender that has taken money. `pos_tenders`
-- references the type `on delete restrict` -- deliberately, since
-- `0208` copies the KIND onto each tender so that retiring a type does
-- not change what last month's drawer was counted against. The
-- refusal says to switch it off instead, which is what a shop means.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The rule, with the two kinds that take no money left alone
-- ---------------------------------------------------------------------
create or replace function app.tender_type_settlement_account()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_drawer boolean;
begin
  if new.bank_account_id is not null then
    return new;
  end if;

  -- Nothing arrives for these two, so nothing is filled in. `0732`:
  -- `on_account` is the customer owing it and `loyalty` is points
  -- coming off the basket. An account on either would say money
  -- reached a bank.
  if new.kind in ('on_account', 'loyalty') then
    return new;
  end if;

  v_drawer := new.kind = 'cash' or coalesce(new.counts_in_drawer, false);

  if v_drawer then
    select b.id into new.bank_account_id
      from public.bank_accounts b
     where b.org_id = new.org_id and b.is_active
       and b.account_type = 'cash'
       and not b.is_client_account
     order by b.is_default desc, b.created_at
     limit 1;
  else
    select g.settlement_bank_account_id into new.bank_account_id
      from public.org_payment_gateways g
     where g.org_id = new.org_id
       and g.settlement_bank_account_id is not null
     order by g.created_at
     limit 1;
  end if;

  -- The company's own account, which for a shop with one account is
  -- the only answer there is.
  if new.bank_account_id is null then
    select b.id into new.bank_account_id
      from public.bank_accounts b
     where b.org_id = new.org_id and b.is_active
       and not b.is_client_account
     order by b.is_default desc, b.created_at
     limit 1;
  end if;

  return new;
end;
$$;

comment on function app.tender_type_settlement_account() is
  'Fills pos_tender_types.bank_account_id when a tender is created '
  'without one: the till for cash and anything counted in the drawer, '
  'a gateway settlement account where one is defined, otherwise the '
  'company default. BEFORE, so the answer is on the row where somebody '
  'can see it and change it rather than chosen at posting time. Null '
  'only where the company has no bank account, and then '
  'app.post_receipt_internal refuses the posting and says to add one. '
  '0731. Since 0732 the on_account and loyalty kinds are left alone, '
  'because no money arrives for either.';

-- ---------------------------------------------------------------------
-- Adding or amending one
-- ---------------------------------------------------------------------
create or replace function public.upsert_pos_tender_type(
  p_id       uuid,
  p_org      uuid,
  p_code     text,
  p_name     text,
  p_kind     app.pos_tender_kind,
  p_payment_mode text default null,
  p_bank_account uuid default null,
  p_counts_in_drawer boolean default null,
  p_gives_change boolean default null,
  p_opens_drawer boolean default null,
  p_sort     integer default null,
  p_active   boolean default true)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id     uuid := p_id;
  v_code   text := upper(btrim(coalesce(p_code, '')));
  v_name   text := btrim(coalesce(p_name, ''));
  v_drawer boolean;
  v_taken  text;
begin
  if not app.can_write_module(p_org, 'pos') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if v_name = '' then
    raise exception 'Give the tender a name -- it is what the till puts '
      'on the button.' using errcode = '23514';
  end if;
  if v_code = '' then
    raise exception 'Give the tender a short code. It is what a report '
      'groups by and what an import matches on.' using errcode = '23514';
  end if;

  -- A readable refusal rather than `pos_tender_types_org_id_code_key`.
  -- The code is what a report groups by, so two of them is two columns
  -- that should have been one.
  select t.name into v_taken from public.pos_tender_types t
   where t.org_id = p_org and t.code = v_code
     and (v_id is null or t.id <> v_id);
  if v_taken is not null then
    raise exception 'The code % is already %''s.', v_code, v_taken
      using errcode = '23505';
  end if;

  if p_payment_mode is not null
     and not exists (select 1 from public.ref_payment_modes m
                      where m.code = p_payment_mode) then
    raise exception
      'There is no LHDN payment mode %. The till reports this on an '
      'e-Invoice raised from a sale, so it has to be one they publish.',
      p_payment_mode using errcode = '23503';
  end if;

  -- Somebody else's bank account, which `0519`'s composite key would
  -- also refuse -- but with a message about a constraint rather than
  -- about the shop.
  if p_bank_account is not null
     and not exists (select 1 from public.bank_accounts b
                      where b.id = p_bank_account and b.org_id = p_org) then
    raise exception 'That bank account is not this company''s.'
      using errcode = '42501';
  end if;

  -- And the two kinds where no money arrives. See the header: an
  -- account here would say it did.
  if p_bank_account is not null and p_kind in ('on_account', 'loyalty') then
    raise exception
      'A % tender takes no money, so it has nowhere to bank. On account '
      'is the customer owing it; points come off the basket.', p_kind
      using errcode = '23514';
  end if;

  -- Cash gives change and opens the drawer unless told otherwise; a
  -- card does neither. Held as columns since `0208` rather than
  -- inferred from the kind, because a shop that takes cheques over the
  -- counter puts them in the drawer -- so these are DEFAULTS for a new
  -- row and whatever was asked for when it is given.
  v_drawer := coalesce(p_counts_in_drawer, p_kind = 'cash');

  if v_id is null then
    insert into public.pos_tender_types (
      org_id, code, name, kind, payment_mode_code, bank_account_id,
      counts_in_drawer, gives_change, opens_drawer, sort_order, is_active)
    values (
      p_org, v_code, v_name, p_kind, p_payment_mode, p_bank_account,
      v_drawer,
      coalesce(p_gives_change, p_kind = 'cash'),
      coalesce(p_opens_drawer, p_kind = 'cash'),
      coalesce(p_sort, (select coalesce(max(sort_order), 0) + 10
                          from public.pos_tender_types
                         where org_id = p_org)),
      coalesce(p_active, true))
    returning id into v_id;
  else
    update public.pos_tender_types t
       set code = v_code,
           name = v_name,
           kind = p_kind,
           payment_mode_code = p_payment_mode,
           -- `coalesce`, not the argument: a null here means "leave it"
           -- and the trigger would fill it again anyway for a tender
           -- that takes money. The screen says as much.
           bank_account_id = coalesce(p_bank_account, t.bank_account_id),
           counts_in_drawer = coalesce(p_counts_in_drawer, t.counts_in_drawer),
           gives_change = coalesce(p_gives_change, t.gives_change),
           opens_drawer = coalesce(p_opens_drawer, t.opens_drawer),
           sort_order = coalesce(p_sort, t.sort_order),
           is_active = coalesce(p_active, t.is_active),
           updated_at = now()
     where t.id = v_id and t.org_id = p_org;
    if not found then
      raise exception 'No such tender in this company.' using errcode = 'P0002';
    end if;
  end if;

  -- Clearing the account on a kind that takes no money is the one case
  -- where null has to mean null, because the trigger leaves those
  -- alone and `coalesce` above would keep a stale one.
  if p_bank_account is null and p_kind in ('on_account', 'loyalty') then
    update public.pos_tender_types set bank_account_id = null
     where id = v_id and org_id = p_org;
  end if;

  return v_id;
end;
$$;

comment on function public.upsert_pos_tender_type is
  'Adds or amends a way of paying at the till: its button name, its '
  'short code, its kind, the LHDN payment mode an e-Invoice reports, '
  'and WHERE THE MONEY LANDS. A null bank account on an amendment '
  'means leave it, because app.tender_type_settlement_account fills '
  'one for any tender that takes money -- the on_account and loyalty '
  'kinds take none and are refused an account outright. 0732.';

revoke all on function public.upsert_pos_tender_type(
  uuid, uuid, text, text, app.pos_tender_kind, text, uuid,
  boolean, boolean, boolean, integer, boolean) from public, anon;
grant execute on function public.upsert_pos_tender_type(
  uuid, uuid, text, text, app.pos_tender_kind, text, uuid,
  boolean, boolean, boolean, integer, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- Removing one, or saying why it cannot go
-- ---------------------------------------------------------------------
create or replace function public.delete_pos_tender_type(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org  uuid;
  v_name text;
  v_used integer;
begin
  select t.org_id, t.name into v_org, v_name
    from public.pos_tender_types t where t.id = p_id;
  if v_org is null then
    return false;
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;

  select count(*) into v_used from public.pos_tenders
   where tender_type_id = p_id;
  if v_used > 0 then
    raise exception
      '% has taken money % times, so it stays on the books. Switch it '
      'off instead and the till stops offering it.', v_name, v_used
      using errcode = '23503';
  end if;

  delete from public.pos_tender_types where id = p_id;
  return true;
end;
$$;

comment on function public.delete_pos_tender_type(uuid) is
  'Removes a way of paying that has never been used. One that has '
  'taken money stays, because pos_tenders references it on delete '
  'restrict so that retiring a tender cannot change what last '
  'month''s drawer was counted against -- the refusal says to switch '
  'it off instead. False where there is no such tender. 0732.';

revoke all on function public.delete_pos_tender_type(uuid) from public, anon;
grant execute on function public.delete_pos_tender_type(uuid) to authenticated;
