-- =====================================================================
-- iAkauntan :: 0731 where the card money lands
--
-- The LAST heading fallback in a posting function.
-- `app.post_receipt_internal` has kept it on purpose since `0728`,
-- whose header gives the reason: every `pos_tender_types` row has a
-- null `bank_account_id`, so refusing would "stop the till rather than
-- correct it", and what was missing was a fact nobody in a session
-- could supply -- where each tender's money lands.
--
-- The fact, from the user: **card and e-wallet settle into the
-- company's own bank account a few days later -- MBB for theirs -- or
-- into another account where one is defined.** Cash stays in the
-- drawer. On the sale date the receipt debits that bank account, and
-- the few days until the statement shows it are an unmatched item on
-- the reconciliation, which is the same treatment a cheque in transit
-- gets and is what a reconciliation is for. The acquirer's fee is
-- already modelled: `receipts.bank_charges` posts to
-- `app.bank_charge_account` (`0635`), so the bank is debited net.
--
-- A card-settlement-in-transit account -- an asset saying what the
-- acquirer still owes -- is the more accurate model and is NOT built
-- here, by decision. It needs a payout record, a posting function, a
-- screen and a second reconciliation. The tender's account is a
-- COLUMN rather than a rule, so that change stays additive.
--
-- ## Resolved and written down, not chosen in the dark
--
-- `app.post_receipt_internal` does not simply refuse a receipt with no
-- bank account, because three callers reach it without one and none of
-- them is a person who declined to answer -- the list is in the
-- function. It RESOLVES the account by the rule above and **writes it
-- onto the receipt**, refusing only when the company has no bank
-- account at all.
--
-- That is the difference from the fallback it replaces. 1120 was
-- chosen at posting time and left no trace, so a year of entries
-- reached the heading unnoticed. An account resolved here appears on
-- the receipt, in every list that reads one, and on the reconciliation
-- that has to agree with it -- and a person who disagrees can change
-- it.
--
-- ## What the audit of the last three days actually found, corrected
--
-- `0728`, `0729` and `0730` each describe the heading as a live mess in
-- customers' books: "twelve companies have one, with real balances",
-- "97 lines across 14 companies". The counts were right. The
-- characterisation was wrong, and this migration is where it gets put
-- straight, because it changes what was urgent:
--
--   bank accounts pointing at the heading   11 demo,  1 real
--   ledger lines on the heading             96 demo,  1 real
--   companies with a POS tender              5 demo,  0 real
--
-- The one real bank account is YUSOF ZAIN & CO's CIMB. The one real
-- line is GESWANT & CO's -22.50, which is `EXP-2026-00001` and was
-- already on the list of things waiting on a person. The eleven demo
-- accounts are recreated on 1121-1199 by `app.demo_bank_account` at the
-- next `app.demo_rebuild()`, so they put themselves right.
--
-- **So no real till is stopped by the refusal below.** The reason
-- `0728` gave for keeping the fallback was sound and the thing it was
-- protecting turned out to be demo data. Worth writing down: three
-- migrations in a row inherited a sentence about scale that none of
-- them had measured.
--
-- ## A default written down is not a fallback chosen in the dark
--
-- `app.tender_type_settlement_account` fills a tender's
-- `bank_account_id` when it is left null, and that is deliberately
-- NOT the same shape as the thing this series has spent three days
-- removing. The difference is where the answer ends up: a trigger
-- writes it onto the row, where a person can see it, change it, and
-- disagree with it. A posting function choosing an account at post
-- time leaves nothing behind -- which is how a year of entries reached
-- the heading without anybody noticing.
--
-- There is no screen for editing a tender type. Tenders are read by
-- the till and written only by the demo seeders, which is the whole
-- reason all thirteen rows are null -- nobody could have set one. That
-- editor is the follow-up this migration does not pretend to be.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Where this tender's money lands
-- ---------------------------------------------------------------------
--
-- The order is the user's rule. A tender that names an account keeps
-- it; one that does not gets the account the money would actually
-- reach:
--
--   cash and anything that counts in the drawer -> the till, which is
--     a `bank_accounts` row of type `cash`. `bank_accounts.account_type`
--     has permitted `cash` since `0003`, so a drawer is an ordinary
--     bank account with a ledger account of its own.
--   everything else -> the settlement account a payment gateway names,
--     and otherwise the company's default active bank account.
--
-- Left NULL where a company has no bank account at all. That is not a
-- hole: `app.post_receipt_internal` then refuses the posting and says
-- to add one, which is better than inventing an account for money that
-- has to be reconciled against a statement.
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
  '0731.';

drop trigger if exists tender_type_settlement_account
  on public.pos_tender_types;
create trigger tender_type_settlement_account
  before insert or update on public.pos_tender_types
  for each row execute function app.tender_type_settlement_account();

comment on column public.pos_tender_types.bank_account_id is
  'Where this tender''s money lands: the till for cash, the account a '
  'card or e-wallet settles into days later for the rest. Filled by '
  'app.tender_type_settlement_account() when left null, and settable '
  'to anything else in the company. A receipt carries it, and 0731 '
  'refuses to post one without it.';

-- ---------------------------------------------------------------------
-- The thirteen rows that exist
-- ---------------------------------------------------------------------
--
-- All thirteen are in demo companies -- there is no real till -- so
-- this is tidying the demo rather than touching anybody's books.
-- Written as an UPDATE through the trigger rather than repeating the
-- rule: setting `bank_account_id` to null and back is how a BEFORE
-- trigger gets asked the question.
update public.pos_tender_types
   set bank_account_id = null, updated_at = now()
 where bank_account_id is null;

-- ---------------------------------------------------------------------
-- A demo company is born with somewhere to put money
-- ---------------------------------------------------------------------
--
-- `app.demo_warung` sells at a counter on line 283 and the company it
-- sells for had no bank account at all -- `app.demo_purchases` creates
-- one later in the rebuild, and the sale comes first. Four more POS
-- seeders are in the same position. Under the old fallback the takings
-- went to the 1120 heading and the demo looked fine.
--
-- Fixed at the one place every demo company passes through, rather
-- than in five seeders: 22 lines instead of 1,080, and a shop that
-- takes cash now has a drawer before it opens.
--
-- `cash`, named in Malay like the rest of the demo. `app.demo_purchases`
-- still makes its "Maybank Current Account" afterwards, because the
-- lookup in `app.demo_bank_account` is now asked for a TYPE -- a till
-- is not a current account and must not be handed back as one. That is
-- the one change to `0730`'s helper.
create or replace function app.demo_bank_account(
  p_org            uuid,
  p_name           text,
  p_bank_name      text default null,
  p_account_number text default null,
  p_type           text default 'current',
  p_bank_code      text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id     uuid;
  v_gl     uuid;
  v_code   text;
  v_parent uuid;
begin
  -- An org that has been seeded before keeps the account it already
  -- has -- heading and all, because a seeder has no business repointing
  -- an account that carries postings. `account_type` is part of the
  -- question now: a drawer and a current account are different places
  -- and a shop has both.
  select b.id into v_id from public.bank_accounts b
   where b.org_id = p_org and b.is_active and not b.is_client_account
     and b.account_type = p_type
   order by b.is_default desc, b.created_at
   limit 1;
  if v_id is not null then
    return v_id;
  end if;

  if p_type = 'cash' then
    -- A leaf, and the one a till belongs on. Unchanged from what the
    -- seeders did before.
    select id into v_gl from public.accounts
     where org_id = p_org and code = '1110';
  end if;

  if v_gl is null then
    select id into v_parent from public.accounts
     where org_id = p_org and code = '1100' limit 1;

    -- The next code with no LIVE account on it.
    select to_char(n, 'FM0000') into v_code
      from generate_series(1121, 1199) as n
     where not exists (
       select 1 from public.accounts a
        where a.org_id = p_org and a.code = to_char(n, 'FM0000')
          and a.deleted_at is null)
     order by n
     limit 1;

    if v_code is null then
      raise exception 'The bank range 1121-1199 is full in this company.'
        using errcode = '23514';
    end if;

    -- `0532`: the chart holds one account per code, retired ones
    -- included -- `accounts_org_id_code_key` does not care that a row
    -- is soft-deleted -- so a code whose account was retired must be
    -- REVIVED and cannot be inserted.
    v_gl := app.revive_account(p_org, v_code);
    if v_gl is null then
      insert into public.accounts
        (org_id, code, name, account_type, account_subtype, parent_id,
         is_group)
      values (p_org, v_code, p_name, 'asset', 'bank', v_parent, false)
      returning id into v_gl;
    end if;
  end if;

  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, bank_code, account_number,
     account_type, currency, opening_balance, current_balance,
     is_active, is_default)
  values (p_org, v_gl, p_name, p_bank_name, p_bank_code, p_account_number,
          p_type, 'MYR', 0, 0, true,
          not exists (select 1 from public.bank_accounts b
                       where b.org_id = p_org and b.is_active))
  returning id into v_id;

  return v_id;
end;
$$;

comment on function app.demo_bank_account(uuid, text, text, text, text, text) is
  'The bank account a demo tenant pays from: the one it already has OF '
  'THAT TYPE, or a new one on its own ledger account in 1121-1199 (or '
  '1110 for a cash drawer). Demo seeders used to insert one on the 1120 '
  'heading, which 0730 refuses. The type is part of the lookup from '
  '0731, because a till is not a current account and a shop has both.';

CREATE OR REPLACE FUNCTION app.demo_company(p_owner uuid, p_name text, p_entity_type app.entity_type, p_registration_no text, p_tin text, p_msic_code text, p_activity text, p_state_code text, p_city text, p_postcode text, p_address text, p_phone text, p_email text, p_fye_month smallint DEFAULT 12)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare v_org uuid;
begin
  perform app.demo_act_as(p_owner);

  -- Deliberately not registered for SST here; see 0185. Where a demo
  -- company should be registered, the caller uses
  -- set_sst_registration() afterwards.
  v_org := public.create_organization(
    p_name, null, p_entity_type::text, p_registration_no, p_tin, p_msic_code,
    p_activity, p_state_code, p_city, p_postcode, p_address,
    p_phone, p_email, false, null, p_fye_month);

  update public.organizations set is_demo = true where id = v_org;

  -- The drawer, before anything can be sold out of it. `0731`: five POS
  -- seeders completed a counter sale in a company with no bank account,
  -- and the takings went to the 1120 heading because that was what the
  -- fallback did. It is a `cash` account on 1110, so the current
  -- account `app.demo_purchases` makes later is still made.
  perform app.demo_bank_account(v_org, 'Wang Tunai', null, null, 'cash');

  return v_org;
end $function$;

-- ---------------------------------------------------------------------
-- app.post_receipt_internal -- restated, the last fallback removed
--
-- md5 of the definition this replaces: 6d66b6668f4628fa50a9cdfd57617e8c
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.post_receipt_internal(p_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_rcp        public.receipts;
  v_entries    jsonb := '[]'::jsonb;
  v_bank_acct  uuid;
  v_bank       uuid;
  v_ar_acct    uuid;
  v_entry_id   uuid;
  v_rate       numeric(18, 8);
  v_net        numeric(18, 2);
  v_fx         numeric(18, 2) := 0;
begin
  select * into v_rcp from public.receipts where id = p_id;
  if not found then raise exception 'Receipt % not found', p_id; end if;
  if v_rcp.gl_entry_id is not null then
    raise exception 'Receipt % is already posted', v_rcp.receipt_no;
  end if;

  v_rate := coalesce(v_rcp.exchange_rate, 1);

  select a.id into v_bank_acct from public.bank_accounts b
    join public.accounts a on a.id = b.account_id
   where b.id = v_rcp.bank_account_id;

  -- This is where the heading used to be: a receipt that named no bank
  -- account was debited to 1120, the parent of every bank account, so
  -- the money had arrived somewhere that appears on no reconciliation
  -- and can be agreed against no statement.
  --
  -- Three callers reach here without an account, and none of them is a
  -- person who declined to answer:
  --
  --   `complete_pos_sale` takes it from the tender type, and every
  --     tender row in production has none because there is no screen
  --     for editing one.
  --   the same function gives a basket cleared entirely by loyalty
  --     points a receipt for ZERO (`0212`), with no tender at all.
  --   `record_group_payment` looks for `is_default and is_active` and
  --     finds nothing when a company's default account has been
  --     closed. Its own comment says what happened next: "left null
  --     the posting falls through to cash (1120) and no bank balance
  --     moves at all, which is the wrong answer for every company that
  --     banks".
  --
  -- So the rule the user gave for the till is applied here, where every
  -- one of those paths passes: the settlement account a gateway names,
  -- else the company's default ACTIVE account, else the oldest active
  -- one. A closed account is never chosen -- nothing would reconcile
  -- against it again -- and a client account is never chosen, because
  -- money held for a client is not the firm's to bank.
  --
  -- **And the answer is written back onto the receipt.** That is the
  -- difference between this and the fallback it replaces: 1120 was
  -- chosen at posting time and left no trace, which is how a year of
  -- entries reached the heading unnoticed. A resolved account is on the
  -- row, in every list, and on the reconciliation that has to agree
  -- with it.
  if v_bank_acct is null then
    select b.id, a.id into v_bank, v_bank_acct
      from public.bank_accounts b
      join public.accounts a on a.id = b.account_id
     where b.org_id = v_rcp.org_id
       and b.is_active
       and not b.is_client_account
     order by (b.id = (select g.settlement_bank_account_id
                         from public.org_payment_gateways g
                        where g.org_id = v_rcp.org_id
                          and g.settlement_bank_account_id is not null
                        order by g.created_at limit 1)) desc nulls last,
              b.is_default desc, b.created_at
     limit 1;

    if v_bank_acct is null then
      raise exception
        'Receipt % says the money arrived and this company has no bank '
        'account for it to arrive in. Add one first -- a cash drawer '
        'counts, since a till is an ordinary account of type cash.',
        v_rcp.receipt_no
        using errcode = '23514';
    end if;
  else
    v_bank := v_rcp.bank_account_id;
  end if;

  select coalesce(c.receivable_account_id,
                  (select id from public.accounts where org_id = v_rcp.org_id and code = '1210'))
    into v_ar_acct from public.contacts c where c.id = v_rcp.contact_id;

  v_net := round((v_rcp.amount - coalesce(v_rcp.bank_charges, 0)) * v_rate, 2);

  -- Dr Bank (net of charges), Dr Bank charges, Cr Receivable.
  v_entries := v_entries || jsonb_build_object(
    'account_id', v_bank_acct, 'description', 'Receipt ' || v_rcp.receipt_no,
    'debit', v_net, 'credit', 0, 'contact_id', v_rcp.contact_id);

  if coalesce(v_rcp.bank_charges, 0) > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.bank_charge_account(v_rcp.org_id, v_rcp.payment_method_id),
      'description', 'Bank charges',
      'debit', round(v_rcp.bank_charges * v_rate, 2), 'credit', 0);
  end if;

  v_entries := v_entries || jsonb_build_object(
    'account_id', v_ar_acct, 'description', 'Receipt ' || v_rcp.receipt_no,
    'debit', 0, 'credit', round(v_rcp.amount * v_rate, 2), 'contact_id', v_rcp.contact_id);

  -- The currency movement between invoice and receipt.
  --
  -- fc_debit and fc_credit are stated as zero rather than left to be
  -- derived: this is a ringgit adjustment with no foreign amount behind
  -- it, and deriving one would invent dollars that were never invoiced.
  v_fx := app.realised_fx_on_settlement(p_id, true, v_rcp.currency, v_rate);

  if v_fx > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', v_ar_acct, 'description', 'Exchange gain on ' || v_rcp.receipt_no,
      'debit', v_fx, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0,
      'contact_id', v_rcp.contact_id);
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.fx_account(v_rcp.org_id, true),
      'description', 'Exchange gain on ' || v_rcp.receipt_no,
      'debit', 0, 'credit', v_fx, 'fc_debit', 0, 'fc_credit', 0);
  elsif v_fx < 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.fx_account(v_rcp.org_id, false),
      'description', 'Exchange loss on ' || v_rcp.receipt_no,
      'debit', -v_fx, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0);
    v_entries := v_entries || jsonb_build_object(
      'account_id', v_ar_acct, 'description', 'Exchange loss on ' || v_rcp.receipt_no,
      'debit', 0, 'credit', -v_fx, 'fc_debit', 0, 'fc_credit', 0,
      'contact_id', v_rcp.contact_id);
  end if;

  v_entry_id := public.create_gl_entry(
    v_rcp.org_id, v_rcp.receipt_date, 'receipt'::app.journal_source, v_entries,
    'Receipt ' || v_rcp.receipt_no, 'receipts', v_rcp.id, v_rcp.reference,
    v_rcp.currency, v_rate);

  update public.receipts
     set gl_entry_id = v_entry_id, status = 'posted',
         -- Written down rather than resolved again by the next reader.
         bank_account_id = v_bank,
         base_amount = round(v_rcp.amount * v_rate, 2),
         fx_gain_loss = v_fx,
         posted_at = now(), posted_by = auth.uid()
   where id = p_id;

  -- `v_bank`, not `v_rcp.bank_account_id`: the row as read may have
  -- had none, and this used to be a `where id = <null>` that quietly
  -- updated nothing while the ledger said the bank had grown.
  update public.bank_accounts
     set current_balance = current_balance + v_net
   where id = v_bank;

  return v_entry_id;
end;
$function$;
