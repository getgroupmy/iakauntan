-- Tie every reference to a bank account, a GL account and a leave type
-- back to the company that owns it.
--
-- The hole
-- --------
-- Row level security scopes a row by its own `org_id`. It says nothing
-- about the *other* companies' ids that row may be carrying in its
-- foreign key columns, and `receipts.bank_account_id` was one of those:
--
--   insert into receipts (org_id, bank_account_id, …)
--   values ('<my company>', '<somebody else's bank account>', …);
--
-- was accepted by this database. Verified rather than reasoned about —
-- the insert above ran against production inside a transaction that was
-- then rolled back, and it succeeded. Nothing refused it: the foreign
-- key pointed at `bank_accounts(id)` alone, and there was no trigger.
--
-- What it bought an attacker, with nothing but ordinary write access to
-- their own company:
--
--   * `post_receipt` and `post_purchase_payment` do
--     `update bank_accounts set current_balance = … where id =
--     v_rcp.bank_account_id`, so the victim's balance moves.
--   * `create_gl_entry_internal` writes `gl_lines` with the caller's
--     `org_id` and whatever `account_id` it was handed, and the
--     `apply_balance` trigger then moves that account's balance. A line
--     could sit in one company's journal and debit another company's
--     chart of accounts.
--   * `remit_withholding` took the worst shape of all — see below.
--
-- The fix is declarative, because a check that has to be remembered is a
-- check that will be forgotten. Every one of these tables now carries a
-- composite foreign key, so the pair has to agree no matter which code
-- path writes it, including code paths not yet written. `MATCH SIMPLE`
-- is what we want: a null bank account is not constrained.
--
-- This pattern is not new to the schema — `app.check_salesperson_org`
-- and `app.branch_belongs_to_org` already do it for two other columns.
-- It simply had not been applied to the ones that move money.
--
-- No existing row violates any of these. Counted before writing them.

-- The parent keys the composite references need.
alter table public.bank_accounts add constraint bank_accounts_org_id_id_key
  unique (org_id, id);
alter table public.accounts add constraint accounts_org_id_id_key
  unique (org_id, id);
alter table public.leave_types add constraint leave_types_org_id_id_key
  unique (org_id, id);

-- Money in and out.
alter table public.receipts
  add constraint receipts_bank_account_same_org
  foreign key (org_id, bank_account_id)
  references public.bank_accounts (org_id, id);

alter table public.purchase_payments
  add constraint purchase_payments_bank_account_same_org
  foreign key (org_id, bank_account_id)
  references public.bank_accounts (org_id, id);

alter table public.expenses
  add constraint expenses_bank_account_same_org
  foreign key (org_id, bank_account_id)
  references public.bank_accounts (org_id, id);

alter table public.client_account_transactions
  add constraint client_account_transactions_bank_account_same_org
  foreign key (org_id, bank_account_id)
  references public.bank_accounts (org_id, id);

-- Statements and reconciliation.
alter table public.bank_transactions
  add constraint bank_transactions_bank_account_same_org
  foreign key (org_id, bank_account_id)
  references public.bank_accounts (org_id, id) on delete cascade;

alter table public.bank_reconciliations
  add constraint bank_reconciliations_bank_account_same_org
  foreign key (org_id, bank_account_id)
  references public.bank_accounts (org_id, id) on delete cascade;

-- Transfers already refuse two companies at creation time; this is the
-- same rule where it cannot be skipped by a later `update`.
alter table public.bank_transfers
  add constraint bank_transfers_from_same_org
  foreign key (org_id, from_account_id)
  references public.bank_accounts (org_id, id);

alter table public.bank_transfers
  add constraint bank_transfers_to_same_org
  foreign key (org_id, to_account_id)
  references public.bank_accounts (org_id, id);

-- The ledger itself. This is the one that closes every posting path at
-- once, including the ones that build their lines as jsonb and hand them
-- to `create_gl_entry`, where no amount of reading the callers would
-- have caught the next one.
alter table public.gl_lines
  add constraint gl_lines_account_same_org
  foreign key (org_id, account_id)
  references public.accounts (org_id, id);

-- Leave. `submit_leave_request` looks its type up by id with no org
-- predicate, so a request in one company could be filed against another
-- company's leave type, and the balance row written under it.
alter table public.leave_requests
  add constraint leave_requests_leave_type_same_org
  foreign key (org_id, leave_type_id)
  references public.leave_types (org_id, id);

alter table public.leave_balances
  add constraint leave_balances_leave_type_same_org
  foreign key (org_id, leave_type_id)
  references public.leave_types (org_id, id);

-- ---------------------------------------------------------------------
-- Two functions deliberately left alone
--
-- `post_expense_claim` and `dispose_fixed_asset` both look a bank
-- account up by `p_bank_account_id` with no org predicate, and both then
-- put that account's GL account into a journal line. `gl_lines_account_
-- same_org` above refuses those lines, so the boundary is closed; what
-- the caller sees is a foreign key violation rather than a sentence.
--
-- They are not rewritten here. Re-declaring two long posting routines to
-- improve an error message means retyping every line of them, and a
-- typo in a journal is worth more than a tidy message. The constraint is
-- the fix; the wording can be improved by someone editing those
-- functions for a reason of their own.

-- ---------------------------------------------------------------------
-- `remit_withholding`, which no foreign key can reach
--
-- Every other case above ends in a row whose two columns must now agree.
-- This one ends in a bare `update` against a table the caller was never
-- checked against:
--
--   if p_bank_account_id is not null then
--     update public.bank_accounts
--        set current_balance = current_balance - v_base
--      where id = p_bank_account_id;      -- any account, anywhere
--   end if;
--
-- The permission check earlier in the function is `can_post(c.org_id)` —
-- the certificate's company, not the bank account's. So somebody who may
-- post in their own books could raise a withholding certificate for an
-- amount of their choosing, remit it naming any bank account id on the
-- platform, and reduce that company's recorded balance by the amount.
-- The account lookup for the journal line had the same gap.
--
-- Both are now scoped to the certificate's own company.
create or replace function public.remit_withholding(
  p_id uuid,
  p_paid_on date default current_date,
  p_bank_account_id uuid default null::uuid,
  p_reference text default null::text)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'app', 'pg_temp'
as $function$
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

  -- Named, and refused rather than quietly ignored. Falling back to the
  -- default cash account on a bank account that is not this company's
  -- would post the entry anyway and leave nobody any the wiser.
  if p_bank_account_id is not null
     and not exists (select 1 from public.bank_accounts b
                      where b.id = p_bank_account_id and b.org_id = c.org_id)
  then
    raise exception 'That bank account belongs to another organization'
      using errcode = '42501';
  end if;

  select a.id into v_bank from public.bank_accounts b
    join public.accounts a on a.id = b.account_id
   where b.id = p_bank_account_id and b.org_id = c.org_id;
  if v_bank is null then
    select id into v_bank from public.accounts
     where org_id = c.org_id and code = '1120';
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

  if p_bank_account_id is not null then
    update public.bank_accounts
       set current_balance = current_balance - v_base
     where id = p_bank_account_id
       and org_id = c.org_id;
  end if;

  update public.withholding_certificates
     set remitted_on = p_paid_on, remittance_ref = p_reference,
         remittance_gl_entry_id = v_entry, status = 'completed'
   where id = p_id;

  return v_entry;
end; $function$;
