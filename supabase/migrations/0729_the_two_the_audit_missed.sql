-- =====================================================================
-- iAkauntan :: 0729 the two the audit missed, and the door behind them
--
-- `0727` closed the 1120 fallback in `post_expense`. `0728` said it had
-- found "the same shape in five more places" and closed four of them.
-- Both were right about what they changed and the COUNT WAS WRONG.
--
-- A sweep of production -- every function in `public` and `app` whose
-- body matches `code = '1120'`, rather than a query filtered to the
-- functions already known -- returns NINE. `0728` reported one. The
-- difference is two posting paths that were never examined:
--
--   dispose_fixed_asset   proceeds received into no account
--   remit_withholding     a remittance paid from no account
--
-- plus six demo seeders, which are data rather than rules and are left.
--
-- ## Why they were missed, which is the part worth keeping
--
-- The scope came from a suggestion naming six functions, and the six
-- were taken as the scope instead of derived. A grep of
-- `supabase/migrations/` for `'1120'` listed twenty files; five were
-- opened. That is run 2183's lesson -- grepping for a token is not
-- grepping for the behaviour -- recurring one level up: ASKING A
-- FILTERED QUESTION CANNOT TELL YOU WHAT YOU DID NOT ASK ABOUT. The
-- query that reported "one remaining" had the answer written into its
-- `where` clause.
--
-- `remit_withholding` had a second reason, and it is the better
-- cautionary tale. `0506`'s header says it "already had the guard and an
-- org-scoped update, so neither needed changing". True -- about the
-- CROSS-TENANT guard. Silent about the fallback. One sentence about one
-- property of a function was read as a verdict on the function.
--
-- And `remit_withholding`'s own comment describes the harm while doing
-- it: it documents refusing another company's bank account because
-- "falling back to the default cash account would post the entry anyway
-- and leave nobody any the wiser".
--
-- ## The cross-tenant hole in dispose_fixed_asset, which is new
--
-- Its bank lookup matched on `b.id` alone. `p_bank_account_id` is an
-- ARGUMENT, so none of `0160`'s composite foreign keys cover it -- those
-- constrain stored columns -- and naming another company's bank account
-- would have debited THEIR ledger account inside this company's
-- journal. Scoped here. This is the same hole `0505` and `0506` closed
-- on the paths where the account is a column.
--
-- ## The second form of the defect, and what is deliberately NOT done
--
-- Refusing a missing account does not catch the other way in: a bank
-- account whose `account_id` points AT the heading. **Twelve companies
-- have one** -- active accounts named "CIMB Current Account", "Maybank
-- Current Account", with real balances -- and a posting naming one of
-- those passes every null check and lands on 1120 anyway. That is most
-- of the 97 lines now sitting on the heading across 14 companies:
-- 53 from receipts, 18 from purchase payments, 25 from manual journals,
-- 1 from `EXP-2026-00001`.
--
-- **Those twelve rows are left exactly as they are, by the user's
-- decision, and nothing here moves a posted line.** Only two of the
-- twelve companies have a second bank account and in both it is
-- `1150 Client Account`, so no company has two accounts resolving to
-- 1120 and nothing is misreconciled between accounts today. It is
-- latent, and it is why the fallback was invisible for a year --
-- including to the fixtures `0728` rewrote.
--
-- Shutting the door behind them -- refusing a NEW bank account that
-- points at the heading -- is wanted and is NOT in this migration, for
-- a reason found by trying it: a trigger doing that fails 29 of the 382
-- assertion files, because **69 fixture sites across 29 files hang
-- their bank account on 1120**. That is the blind spot `0728` wrote up,
-- measured rather than estimated, and it is four times what that
-- write-up implied. Several of those fixtures carry meaning in the
-- insert they would lose -- opening balances, `is_default`, a second
-- account per company, the two `1150` client accounts -- so the sweep
-- is careful work and gets its own change rather than riding along with
-- a two-function fix. `pg_temp.test_bank_account` is what they move to.
--
-- ## And an assertion, because a grep found nine and a human found one
--
-- `supabase/tests/money_names_the_account.sql` now pins the ALLOW-LIST:
-- the set of functions permitted to mention `code = '1120'` is
-- `app.post_receipt_internal` plus the six demo seeders, and anything
-- else fails by name. A tenth cannot appear quietly, and fixing one of
-- the seven requires deleting its line, which is visible in a diff.
--
-- It asserts BOTH directions. An allow-list entry matching nothing is
-- the failure that rots: it means somebody fixed a function and left
-- the exemption behind, and the next reader takes the list for the
-- truth. That is how this migration's own subject survived -- `0506`
-- left a sentence saying a function "needed no changing", and it was
-- read as a verdict rather than as the narrow claim it was.
--
-- ## And the two dialogs, in the same commit
--
-- A refusal in SQL that no screen anticipates is a red snackbar, so
-- both callers now ask. `disposal_dialog.dart` stars "Proceeds into"
-- the moment an amount is typed and drops its "Left blank, they go to
-- cash" helper, WHICH WAS NOT TRUE -- blank went to 1120, and a widget
-- test asserted that sentence, pinning the untrue claim in place.
-- `withholding_screen.dart` replaces a yes-or-no confirmation with a
-- dialog that asks which account the money left, keeping the
-- confirmation's words, since "do it when the money has actually gone"
-- was always the right warning.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.dispose_fixed_asset(p_asset_id uuid, p_date date, p_proceeds numeric DEFAULT 0, p_bank_account_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  a          public.fixed_assets;
  v_entries  jsonb := '[]'::jsonb;
  v_accum    numeric(18, 2);
  v_catchup  numeric(18, 2);
  v_nbv      numeric(18, 2);
  v_result   numeric(18, 2);
  v_asset_ac uuid; v_accum_ac uuid; v_cash_ac uuid; v_expense_ac uuid;
  v_entry_id uuid;
  v_run_id   uuid;
begin
  select * into a from public.fixed_assets where id = p_asset_id;
  if not found then
    raise exception 'Asset % not found', p_asset_id using errcode = 'P0002';
  end if;
  if not app.can_post(a.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  if a.status = 'disposed' then
    raise exception 'Asset % has already been disposed of', a.asset_no
      using errcode = '23514';
  end if;
  if p_date < a.acquisition_date then
    raise exception 'Asset % was acquired on %, after the disposal date %',
      a.asset_no, a.acquisition_date, p_date using errcode = '23514';
  end if;

  -- Catch the charge up to the day it left, and remember by how much:
  -- that part has not been posted anywhere yet.
  v_accum := greatest(app.accumulated_depreciation_at(a, p_date),
                      a.accumulated_depreciation);
  v_catchup := greatest(v_accum - a.accumulated_depreciation, 0);
  v_nbv := a.cost - v_accum;
  v_result := round(coalesce(p_proceeds, 0) - v_nbv, 2);

  -- 1510, not 1500: 1500 is the "Non-Current Assets" header in the
  -- seeded chart and nothing may post to a header.
  v_asset_ac := coalesce(a.asset_account_id,
    (select id from public.accounts where org_id = a.org_id and code = '1510'));
  v_accum_ac := coalesce(a.accumulated_account_id,
    (select id from public.accounts where org_id = a.org_id and code = '1590'));
  -- Proceeds that named no account used to be debited to 1120 Bank
  -- Accounts, the heading the real accounts hang under. Refused now,
  -- and only where there ARE proceeds: a disposal for nothing adds no
  -- cash leg at all and needs no account.
  --
  -- `and b.org_id = a.org_id` is new and is a cross-tenant fix, not
  -- tidying. `p_bank_account_id` is an ARGUMENT, so none of `0160`'s
  -- composite foreign keys cover it -- they constrain stored columns --
  -- and the lookup matched on `b.id` alone. Naming another company's
  -- bank account would have debited THEIR ledger account inside this
  -- company's journal, which is the hole `0505` and `0506` closed on
  -- the paths where the account is stored.
  if coalesce(p_proceeds, 0) > 0 then
    if p_bank_account_id is null then
      raise exception
        'Say which account the % proceeds were received into. Without one '
        'there is nothing for a reconciliation to match.', a.asset_no
        using errcode = '23514';
    end if;
    select ac.id into v_cash_ac from public.bank_accounts b
      join public.accounts ac on ac.id = b.account_id
     where b.id = p_bank_account_id and b.org_id = a.org_id;
    if v_cash_ac is null then
      raise exception
        'That bank account is not this company''s.' using errcode = '42501';
    end if;
  end if;

  if v_asset_ac is null or v_accum_ac is null then
    raise exception
      'No fixed asset (1510) or accumulated depreciation (1590) account in '
      'the chart. Add them, or name accounts on the asset.'
      using errcode = 'P0002';
  end if;

  -- The months between the last run and the disposal. Charged here or
  -- charged nowhere — and if nowhere, relieved from the balance sheet
  -- below without ever reaching the profit and loss.
  if v_catchup > 0 then
    v_expense_ac := coalesce(a.expense_account_id,
      (select id from public.accounts where org_id = a.org_id and code = '6400'));
    if v_expense_ac is null then
      raise exception
        'No depreciation expense (6400) account in the chart, and % has '
        'not been depreciated up to %. Add the account, or name one on '
        'the asset.', a.asset_no, p_date
        using errcode = 'P0002';
    end if;
    v_entries := v_entries
      || jsonb_build_object(
           'account_id', v_expense_ac,
           'description', 'Depreciation of ' || a.asset_no || ' to disposal',
           'debit', v_catchup, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0)
      || jsonb_build_object(
           'account_id', v_accum_ac,
           'description', 'Depreciation of ' || a.asset_no || ' to disposal',
           'debit', 0, 'credit', v_catchup, 'fc_debit', 0, 'fc_credit', 0);
  end if;

  -- Dr accumulated depreciation, Dr proceeds, Cr the asset at cost, and
  -- the difference to gain or loss.
  if v_accum > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', v_accum_ac, 'description', 'Disposal of ' || a.asset_no,
      'debit', v_accum, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0);
  end if;

  if coalesce(p_proceeds, 0) > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', v_cash_ac, 'description', 'Proceeds on ' || a.asset_no,
      'debit', p_proceeds, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0);
  end if;

  v_entries := v_entries || jsonb_build_object(
    'account_id', v_asset_ac, 'description', 'Disposal of ' || a.asset_no,
    'debit', 0, 'credit', a.cost, 'fc_debit', 0, 'fc_credit', 0);

  if v_result > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.disposal_account(a.org_id, true),
      'description', 'Gain on disposal of ' || a.asset_no,
      'debit', 0, 'credit', v_result, 'fc_debit', 0, 'fc_credit', 0);
  elsif v_result < 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.disposal_account(a.org_id, false),
      'description', 'Loss on disposal of ' || a.asset_no,
      'debit', -v_result, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0);
  end if;

  v_entry_id := app.create_gl_entry_internal(
    a.org_id, p_date, 'depreciation'::app.journal_source, v_entries,
    'Disposal of ' || a.asset_no || ' — ' || a.name,
    'fixed_assets', a.id, null, app.base_currency(a.org_id), 1);

  -- The catch-up recorded where every other charge is recorded, so the
  -- asset's history is whole and the schedule's charge for the period
  -- ties to the entries behind it. The run points at the disposal
  -- journal because that is the journal that carried it.
  if v_catchup > 0 then
    insert into public.depreciation_runs
      (org_id, run_date, gl_entry_id, total_amount, posted_by)
    values (a.org_id, p_date, v_entry_id, v_catchup, auth.uid())
    returning id into v_run_id;

    insert into public.depreciation_entries
      (org_id, run_id, asset_id, amount,
       opening_accumulated, closing_accumulated)
    values (a.org_id, v_run_id, a.id, v_catchup,
            a.accumulated_depreciation, v_accum);
  end if;

  update public.fixed_assets
     set status = 'disposed', disposal_date = p_date,
         disposal_proceeds = coalesce(p_proceeds, 0),
         disposal_entry_id = v_entry_id,
         accumulated_depreciation = v_accum,
         depreciated_to = p_date,
         updated_at = now()
   where id = a.id;

  return v_entry_id;
end $function$

;

CREATE OR REPLACE FUNCTION public.remit_withholding(p_id uuid, p_paid_on date DEFAULT CURRENT_DATE, p_bank_account_id uuid DEFAULT NULL::uuid, p_reference text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  c public.withholding_certificates;
  v_bank uuid;
  v_wht uuid;
  v_base numeric(18, 2);
  v_entry uuid;
begin
  select * into c from public.withholding_certificates where id = p_id;
  if not found then
    raise exception 'Certificate % not found', p_id using errcode = 'P0002';
  end if;
  if not app.can_post(c.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  if c.gl_entry_id is null then
    raise exception 'Post the certificate before remitting it'
      using errcode = '22023';
  end if;
  if c.remitted_on is not null then
    raise exception 'Certificate % was already remitted on %',
      c.certificate_no, c.remitted_on using errcode = '22023';
  end if;

  if p_bank_account_id is not null
     and not exists (select 1 from public.bank_accounts b
                      where b.id = p_bank_account_id and b.org_id = c.org_id)
  then
    raise exception 'That bank account belongs to another organization'
      using errcode = '42501';
  end if;

  -- A remittance that named no account used to be credited to 1120
  -- Bank Accounts -- the heading the real accounts hang under -- which
  -- moved no bank balance and showed on no reconciliation. This
  -- function's own comment already named that harm while doing it: it
  -- documented refusing ANOTHER COMPANY's account because "falling back
  -- to the default cash account would post the entry anyway and leave
  -- nobody any the wiser", and then fell back for a missing one.
  --
  -- `0506` read this function and left it alone, correctly, for the
  -- cross-tenant guard above. Its header's "neither needed changing"
  -- was about that guard and said nothing about the fallback; it was
  -- read as a verdict on the whole function, which is how this survived
  -- `0728`.
  if p_bank_account_id is null then
    raise exception
      'Say which account the remittance was paid from. Without one there '
      'is no bank balance to move and nothing for a reconciliation to '
      'match.' using errcode = '23514';
  end if;

  select a.id into v_bank from public.bank_accounts b
    join public.accounts a on a.id = b.account_id
   where b.id = p_bank_account_id and b.org_id = c.org_id;
  if v_bank is null then
    raise exception 'That account is not on this company''s chart.'
      using errcode = 'P0002';
  end if;

  v_wht := app.withholding_account(c.org_id);
  v_base := round(c.tax_amount * coalesce(c.exchange_rate, 1), 2);

  v_entry := public.create_gl_entry(
    c.org_id, p_paid_on, 'withholding'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object(
        'account_id', v_wht,
        'description', 'Remitted ' || c.section || ' ' || c.certificate_no,
        'debit', v_base, 'credit', 0),
      jsonb_build_object(
        'account_id', v_bank,
        'description', 'Remitted ' || c.certificate_no,
        'debit', 0, 'credit', v_base)),
    'Withholding remittance ' || c.certificate_no,
    'withholding_certificates', c.id,
    coalesce(p_reference, c.form_code));

  update public.bank_accounts
     set current_balance = current_balance - v_base
   where id = p_bank_account_id
     and org_id = c.org_id;

  update public.withholding_certificates
     set remitted_on = p_paid_on, remittance_ref = p_reference,
         remittance_gl_entry_id = v_entry, status = 'completed'
   where id = p_id;

  return v_entry;
end; $function$

;

-- ---------------------------------------------------------------------
-- The published descriptions
-- ---------------------------------------------------------------------
--
-- `docs/api/` is generated from these: the summary is the FIRST SENTENCE
-- and the description is the whole comment. Run 2185 went red for
-- replacing one outright and losing three documented refusals, so these
-- are the live text with the smallest change that makes them true.
--
-- `dispose_fixed_asset` is the awkward one: its comment DOCUMENTED the
-- fallback -- "or 1120 if none is named" -- so that clause is now false
-- and is corrected rather than appended to. Everything else in it is
-- preserved word for word, including the sentence about no
-- `bank_transactions` row being written, which is still true and is the
-- reason these proceeds were never reconcilable in the first place.

comment on function public.dispose_fixed_asset(uuid, date, numeric, uuid) is
  'Takes a fixed asset off the books on `p_date` and returns the id of '
  'the journal entry it posted. The entry carries TWO things, not one: '
  'the disposal itself -- accumulated depreciation and any proceeds '
  'debited, the asset relieved at cost, the difference to gain or loss '
  'through `app.disposal_account` -- and THE DEPRECIATION NOBODY HAS '
  'POSTED YET. An asset depreciates daily and the schedule runs '
  'monthly, so on the day it leaves there is almost always a catch-up '
  'owing; it is charged to 6400 here, in this same journal, and filed '
  'as a `depreciation_runs` row pointing at it so the asset''s history '
  'is whole. If there is a catch-up and the chart has no 6400 THE WHOLE '
  'DISPOSAL REFUSES rather than relieving that amount off the balance '
  'sheet without it ever reaching the profit and loss. Accounts come '
  'off the asset where it names them, else 1510, 1590 and 6400 from the '
  'seeded chart (1510 and not 1500, which is a header nothing may post '
  'to). `p_proceeds` debits `p_bank_account_id`''s GL account, and a '
  'disposal WITH proceeds and no account named is REFUSED -- it used to '
  'fall back to 1120, the heading the real accounts hang under, which '
  'moved no bank balance and showed on no reconciliation (0729). A '
  'disposal for nothing needs no account. The account is also checked '
  'against this company: it is an argument, so no foreign key covers '
  'it, and naming another company''s would have debited their ledger '
  'account inside this journal. Proceeds are booked as CASH, never as a '
  'receivable, so a disposal on credit puts money in the ledger that '
  'has not arrived. NO `bank_transactions` ROW IS WRITTEN: the proceeds '
  'are invisible to bank reconciliation until the real credit lands on '
  'the statement. Accumulated depreciation is never reduced -- the '
  'greater of the computed and the stored figure is used. Refuses a '
  'disposal dated before acquisition, and refuses an asset already '
  'disposed of, so it cannot be run twice. Needs posting rights.';

comment on function public.remit_withholding(uuid, date, uuid, text) is
  'Records that a withholding certificate has been paid over to the '
  'Inland Revenue Board, and posts the payment. The certificate must be '
  'POSTED FIRST -- there is nothing to remit until the liability is in '
  'the books -- and one already remitted is refused, naming the date. A '
  'bank account belonging to another company is REFUSED BY NAME rather '
  'than quietly ignored: falling back to the default cash account would '
  'post the entry anyway and leave nobody any the wiser. Naming NO '
  'account is refused for the same reason, which this function did not '
  'do until `0729` -- it fell back to 1120, the heading the real '
  'accounts hang under, which moved no bank balance and showed on no '
  'reconciliation. Needs `can_post`.';
