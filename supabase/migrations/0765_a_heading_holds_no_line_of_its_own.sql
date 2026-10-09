-- =====================================================================
-- 0765 :: a heading holds no line of its own
--
-- Answered on 8 October: "refuse at the ledger".
--
-- `0003` says it in a comment on `accounts.is_group`: "Group/header
-- accounts aggregate children and cannot be posted to directly." Every
-- report agrees -- `report_trial_balance`, the profit and loss, the
-- cash flow statement and `report_general_ledger` all add up LEAVES,
-- `and not a.is_group`. Nothing in the ledger enforced it. The manual
-- journal refuses a heading (`0089`), and so does `post_expense_claim`;
-- the account pickers in the app hide them, which is Dart. A document
-- line naming a heading posted, and its figure left the trial balance
-- the moment it did. Reproduced: an invoice line on 4000 REVENUE and a
-- bill line on 5000 COST OF SALES left a trial balance of dr 70 / cr
-- 150 over a ledger of 220 / 220, with no error anywhere.
--
-- It had happened in production once, to the demo. Guaman Aziz &
-- Rakan's `INV-2026-00001` credits RM4,500 to 4000 REVENUE: its trial
-- balance is out by RM4,500, and its profit and loss reports RM1,800
-- of fees where there are RM6,300. `app.demo_legal_guaman` took "the
-- first revenue account by code" for the fee line, and the first one
-- is the heading. The demo is rebuilt daily, so it came back every
-- day. No other company had a line on a heading.
--
-- 1. THE LEDGER
--
-- A trigger on `gl_lines` refuses a line on a heading, so every
-- posting path is covered at once rather than one guard at a time. A
-- line is written only by SECURITY DEFINER code (`0399` took the grant
-- away), so the refusal reaches a person as the posting function's
-- error. `update of account_id` is there for completeness: the ledger
-- is append-only and nothing repoints a line. Lines already posted are
-- not touched.
--
-- Not in this migration: a RETIRED account. That question is still
-- open separately, and refusing one here would turn a misposting into
-- a failed payroll in a company that retired a code the ledger finds
-- by number.
--
-- 2. THE DEMO
--
-- `app.demo_legal_guaman` is restated from `pg_get_functiondef`
-- against production, md5-verified first (c54ff937b9419179a10e47f865ed2eaa,
-- the same text `0730` wrote), with the one change: the fee goes to
-- `app.time_income_account`, 4840 Professional Fees, where the firm's
-- billed hours already go. The next rebuild replaces the bad invoice.
-- Without this the trigger would have broken the rebuild instead.
-- =====================================================================

create or replace function app.refuse_line_on_heading()
returns trigger
language plpgsql
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_code text;
  v_name text;
begin
  select a.code, a.name into v_code, v_name
    from public.accounts a
   where a.id = new.account_id
     and a.is_group;
  if found then
    raise exception
      'Account % (%) is a heading. A heading adds up the accounts under '
      'it and holds no balance of its own, so a line on it would drop '
      'out of the trial balance. Post to one of the accounts under it.',
      v_code, v_name
      using errcode = '23514';
  end if;
  return new;
end $$;

revoke all on function app.refuse_line_on_heading()
  from public, anon, authenticated;

comment on function app.refuse_line_on_heading() is
  'Refuses a ledger line on a heading (`is_group`) account (0765). Every '
  'report adds up leaves only, so a line on a heading left the trial '
  'balance and the profit and loss with no error anywhere.';

drop trigger if exists gl_lines_not_on_a_heading on public.gl_lines;
create trigger gl_lines_not_on_a_heading
  before insert or update of account_id on public.gl_lines
  for each row execute function app.refuse_line_on_heading();

-- ---------------------------------------------------------------------
-- app.demo_legal_guaman -- restated, the fee off the heading
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.demo_legal_guaman(p_org uuid, p_owner uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_today  date := app.today();
  v_client uuid;
  v_office uuid;
  v_c1 uuid; v_c2 uuid; v_c3 uuid;
  v_txn uuid;
  v_m1 uuid; v_m2 uuid; v_m3 uuid;
  v_rate numeric(18, 2) := 450.00;
  v_inv1 uuid;
  v_inv2 uuid;
  v_held numeric(18, 2);
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_owner, 'role', 'authenticated')::text, true);

  -- The client account, 1150 and 2300, all from the setup function
  -- rather than by hand: a client account this seed created itself
  -- might not be one `is_client_account` recognises, and then the whole
  -- demo would be office money wearing a label.
  perform public.setup_legal_module(p_org);
  select b.id into v_client from public.bank_accounts b
   where b.org_id = p_org and b.is_client_account;
  if v_client is null then
    perform set_config('request.jwt.claims', '', true);
    return 'Guaman Aziz: skipped, the legal setup made no client account.';
  end if;

  -- The firm's OWN account, on a ledger account of its own. It used to
  -- be the 1120 heading, which made the fee crossing below a movement
  -- between an account and the parent of every account -- the one thing
  -- this demo exists to show, shown wrong.
  v_office := app.demo_bank_account(
    p_org, 'Office Current', 'Maybank', '514022331');

  insert into public.contacts (org_id, code, name, contact_type, email)
  values (p_org, 'CL-001', 'Puan Aminah Yusof', 'customer',
          'aminah@guamanaziz.demo') returning id into v_c1;
  insert into public.contacts (org_id, code, name, contact_type, email)
  values (p_org, 'CL-002', 'Encik Rajan Menon', 'customer',
          'rajan@guamanaziz.demo') returning id into v_c2;
  insert into public.contacts (org_id, code, name, contact_type, email)
  values (p_org, 'CL-003', 'Lim Holdings Sdn Bhd', 'customer',
          'accounts@limholdings.demo') returning id into v_c3;

  v_m1 := public.open_matter(
    p_org, 'M-2026-001', 'Sale of a house at Taman Seri',
    v_c1, 'Chong Wei Seng', 'conveyancing', p_owner, p_owner,
    null, v_rate, null);
  v_m2 := public.open_matter(
    p_org, 'M-2026-002', 'Tenancy dispute — Lot 14 Jalan Ampang',
    v_c2, 'Harta Sewa Sdn Bhd', 'litigation', p_owner, p_owner,
    null, v_rate, null);
  v_m3 := public.open_matter(
    p_org, 'M-2026-003', 'Shareholders'' agreement',
    v_c3, null, 'corporate', p_owner, p_owner,
    6000, v_rate, null);

  -- ------------------------------------------------------------------
  -- The client-money cycle, on the conveyancing matter
  -- ------------------------------------------------------------------
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date,
     transaction_type, bank_account_id, amount, currency, description,
     created_by)
  values (p_org, v_m1, 'CT-2026-001', v_today - 45, 'receipt',
          v_client, 50000, 'MYR',
          'Deposit and completion money on account', p_owner)
  returning id into v_txn;
  perform public.post_client_transaction(v_txn);

  -- Negative, because `post_client_transaction` takes the amount as the
  -- caller signs it: `v_amount := v_txn.amount` and the double entry is
  -- built from `greatest(v_amount, 0)` and `greatest(-v_amount, 0)`.
  -- Money out written as a positive number would debit the client bank
  -- again -- the demo would show RM96,800 held against RM50,000 ever
  -- received, and the books would still balance.
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date,
     transaction_type, bank_account_id, amount, currency, description,
     payee, created_by)
  values (p_org, v_m1, 'CT-2026-002', v_today - 20, 'payment',
          v_client, -42300, 'MYR',
          'Balance purchase price to the vendor''s solicitors',
          'Tetuan Chong & Co', p_owner)
  returning id into v_txn;
  perform public.post_client_transaction(v_txn);

  -- The only lawful way the firm's fee crosses from client to office,
  -- and 0549 is where it became lawful. This block used to write the
  -- transfer on its own: the client ledger went down by 4,500, the
  -- office account was never debited, and there was no bill for it to
  -- settle. The demo showed the movement doing the wrong thing, which
  -- is worse than not showing it.
  --
  -- A fee is billed first, because that is the order the rules impose:
  -- money is not taken out of client account until there is a rendered
  -- bill to take it against.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, matter_id,
     status, currency, exchange_rate, subject, created_by)
  values (p_org, 'invoice',
          app.next_document_number_internal(p_org, 'invoice'),
          v_today - 14, v_today, v_c1, v_m1, 'draft', 'MYR', 1,
          'Fees and disbursements on the completed sale', p_owner)
  returning id into v_inv1;

  -- 4840 Professional Fees, where the firm's billed hours go. This read
  -- "the first revenue account by code", which is 4000 REVENUE -- the
  -- HEADING -- so the fee dropped out of the trial balance and the
  -- profit and loss (0765).
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description,
     quantity, unit_price, account_id)
  values (p_org, v_inv1, 1, 'item',
          'Professional fees, sale of the property', 1, 4500,
          app.time_income_account(p_org));

  perform public.post_sales_document(v_inv1);

  -- And then the crossing, both legs: out of the client account, into
  -- the office one, against that bill.
  perform public.settle_from_client_account(
    v_m1, v_inv1, 4500, v_today - 12, v_office);

  -- ------------------------------------------------------------------
  -- Time, on the two matters that are billed by the hour
  -- ------------------------------------------------------------------
  insert into public.time_entries
    (org_id, matter_id, user_id, entry_date, description, activity_code,
     minutes, hourly_rate, amount, is_billable)
  values
    (p_org, v_m2, p_owner, v_today - 30,
     'Client attendance and review of the tenancy agreement', 'ATTEND',
     90, v_rate, round(90 / 60.0 * v_rate, 2), true),
    (p_org, v_m2, p_owner, v_today - 26,
     'Letter of demand drafted and sent', 'DRAFT',
     120, v_rate, round(120 / 60.0 * v_rate, 2), true),
    (p_org, v_m2, p_owner, v_today - 18,
     'Telephone attendance on the opposing solicitors', 'ATTEND',
     30, v_rate, round(30 / 60.0 * v_rate, 2), true),
    (p_org, v_m2, p_owner, v_today - 15,
     'Internal file note after the without-prejudice call', 'ADMIN',
     20, v_rate, round(20 / 60.0 * v_rate, 2), false),
    -- More hours than the agreed fee covers, which is what
    -- `report_matters_over_agreed_fee` exists to say out loud.
    (p_org, v_m3, p_owner, v_today - 40,
     'First draft of the shareholders'' agreement', 'DRAFT',
     360, v_rate, round(360 / 60.0 * v_rate, 2), true),
    (p_org, v_m3, p_owner, v_today - 33,
     'Two rounds of amendments after the board meeting', 'DRAFT',
     300, v_rate, round(300 / 60.0 * v_rate, 2), true),
    (p_org, v_m3, p_owner, v_today - 22,
     'Completion meeting and execution', 'ATTEND',
     240, v_rate, round(240 / 60.0 * v_rate, 2), true);

  -- The litigation matter is billed; the corporate one is not, so the
  -- over-the-agreed-fee report has an open matter to report on rather
  -- than a closed one nobody can act on.
  v_inv2 := public.bill_matter_time(v_m2, v_today - 40, v_today,
                                    v_today + 14);

  -- Read from the bank account the postings moved, not recomputed from
  -- the transactions with a sign convention of this function's own. A
  -- summary that does its own arithmetic can agree with itself while
  -- disagreeing with the ledger, which is how the sign error above
  -- survived its first run: the sentence said RM3,200 and the client
  -- account held RM96,800.
  select current_balance into v_held
    from public.bank_accounts where id = v_client;

  perform set_config('request.jwt.claims', '', true);

  return format(
    'Guaman Aziz: 3 matters for 3 clients, RM%s still held in the '
    'client account after completion money out and the fee transferred '
    'to office, one matter billed by the hour and one over its agreed '
    'fee.', to_char(v_held, 'FM999,999,990.00'));
end $function$;

