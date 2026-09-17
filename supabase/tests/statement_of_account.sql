-- =====================================================================
-- iAkauntan :: the statement a customer asks for
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/statement_of_account.sql
--
-- One assertion carries this file and the rest support it:
--
--   **the statement's closing balance is the ageing report's total.**
--
-- They are computed from opposite directions. `report_ar_aging` nets
-- every allocation off the document it settled and lists what is LEFT
-- on each; `report_statement_of_account` ignores allocations entirely
-- and lists what MOVED, running a balance down the page. Two answers
-- from two methods, and the day they disagree the customer's ledger
-- disagrees with ours by exactly that amount.
--
-- Written against a company with the awkward cases in it rather than
-- one invoice and one receipt: a part payment, a credit note, an
-- unapplied receipt, a void document and a draft. Each of those is a
-- way for the two to come apart.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.soa_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

-- The same three fixtures `aged_balances.sql` uses, and deliberately
-- the same ones: this file exists to check that two functions agree,
-- and building their data two different ways would be a third thing
-- that could be wrong.
create or replace function pg_temp.customer(
  p_org uuid, p_code text, p_name text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (p_org, p_code, p_name, 'customer') returning id into v_id;
  return v_id;
end;
$$;

create or replace function pg_temp.sales_doc(
  p_org uuid, p_contact uuid, p_type app.sales_doc_type, p_no text,
  p_amount numeric, p_date date, p_due date default null,
  p_post boolean default true)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (p_org, p_type, p_no, p_date, p_due, p_contact, 'MYR', 1,
          p_amount, p_amount, p_amount, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     line_total)
  values (p_org, v_doc, 1, 'Consulting', 1, p_amount, p_amount);
  if p_post then perform public.post_sales_document(v_doc); end if;
  return v_doc;
end;
$$;

create or replace function pg_temp.receipt(
  p_org uuid, p_contact uuid, p_no text, p_amount numeric, p_date date,
  p_invoice uuid default null, p_alloc numeric default null)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount,
     unapplied_amount, currency, exchange_rate)
  values (p_org, p_no, p_date, p_contact, p_amount, p_amount, 'MYR', 1)
  returning id into v_id;
  if p_invoice is not null then
    insert into public.payment_allocations
      (org_id, receipt_id, invoice_id, amount)
    values (p_org, v_id, p_invoice, coalesce(p_alloc, p_amount));
  end if;
  perform public.post_receipt(v_id);
  return v_id;
end;
$$;

do $$
declare
  v_org     uuid := pg_temp.soa_org('Penyata Sdn Bhd');
  v_cust    uuid;
  v_other   uuid;
  v_edge    uuid;
  v_inv1    uuid;
  v_inv2    uuid;
  v_cn      uuid;
  v_rcpt    uuid;
  v_deposit uuid;
  v_draft   uuid;
  v_void    uuid;
  v_closing numeric;
  v_aged    numeric;
  v_rows    integer;
begin
  v_cust  := pg_temp.customer(v_org, 'C-SOA1', 'Pelanggan Tetap');
  v_other := pg_temp.customer(v_org, 'C-SOA2', 'Somebody Else');

  -- Two invoices, one part-paid; a credit note; a receipt that has not
  -- been applied to anything; a draft and a void that must not appear.
  -- Dated the first day of the period, deliberately. A boundary
  -- written `<=` instead of `<` puts this invoice in the opening
  -- balance AND on the page, and the customer is asked for it twice.
  -- Nothing else in this fixture can tell the two apart.
  v_edge := pg_temp.sales_doc(v_org, v_cust, 'invoice', 'INV-S0', 1200,
                              date '2026-03-01', date '2026-03-31');
  v_inv1 := pg_temp.sales_doc(v_org, v_cust, 'invoice', 'INV-S1', 10000,
                              date '2026-03-05', date '2026-04-04');
  v_inv2 := pg_temp.sales_doc(v_org, v_cust, 'invoice', 'INV-S2', 4000,
                              date '2026-03-20', date '2026-04-19');
  v_cn   := pg_temp.sales_doc(v_org, v_cust, 'credit_note', 'CN-S1', 1000,
                              date '2026-03-25');

  -- A part payment against the first invoice, and money on account
  -- matched to nothing.
  v_rcpt    := pg_temp.receipt(v_org, v_cust, 'RC-S1', 6000,
                               date '2026-03-18', v_inv1, 6000);
  v_deposit := pg_temp.receipt(v_org, v_cust, 'RC-S2', 500,
                               date '2026-03-28');

  v_draft := pg_temp.sales_doc(v_org, v_cust, 'invoice', 'INV-S3', 99999,
                               date '2026-03-10', null, false);

  v_void := pg_temp.sales_doc(v_org, v_cust, 'invoice', 'INV-S4', 7777,
                              date '2026-03-12');
  perform public.void_sales_document(v_void, 'Raised in error');

  -- ------------------------------------------------------------------
  -- The statement
  -- ------------------------------------------------------------------
  select count(*)::integer into v_rows
    from public.report_statement_of_account(
           v_cust, date '2026-03-01', date '2026-03-31');
  -- Opening, three invoices, a credit note, two receipts. Not the
  -- draft and not the void.
  perform pg_temp.check_eq('it lists what moved and nothing else',
    v_rows, 7);

  perform pg_temp.check_eq('the first row is the brought-forward figure',
    (select s.kind from public.report_statement_of_account(
       v_cust, date '2026-03-01', date '2026-03-31') s
      where s.line_no = 0), 'opening');
  perform pg_temp.check_eq('and it is nil for a customer with no history',
    (select s.balance from public.report_statement_of_account(
       v_cust, date '2026-03-01', date '2026-03-31') s
      where s.line_no = 0), 0);

  -- 1,200 + 10,000 + 4,000 - 1,000 - 6,000 - 500
  select s.balance into v_closing
    from public.report_statement_of_account(
           v_cust, date '2026-03-01', date '2026-03-31') s
   order by s.line_no desc limit 1;
  perform pg_temp.check_eq('the closing balance is the arithmetic',
    v_closing, 7700);

  perform pg_temp.check_eq('and `statement_balance` agrees with it',
    public.statement_balance(v_cust, date '2026-03-31'), 7700);

  -- The boundary, asserted from both sides. The opening balance is nil
  -- and the first day's invoice is a line, which is the only shape that
  -- is not a double count.
  perform pg_temp.check_eq('a document dated on day one is a line, not a '
    'brought-forward figure',
    (select count(*) from public.report_statement_of_account(
       v_cust, date '2026-03-01', date '2026-03-31') s
      where s.doc_no = 'INV-S0'), 1);

  -- ------------------------------------------------------------------
  -- The assertion this file is for
  -- ------------------------------------------------------------------
  select coalesce(sum(a.base_outstanding), 0) into v_aged
    from public.report_ar_aging(v_org, date '2026-03-31') a
   where a.contact_id = v_cust;

  perform pg_temp.check_eq(
    'the statement and the ageing report agree to the sen',
    v_closing, v_aged);

  -- ------------------------------------------------------------------
  -- Neither the draft nor the void is on it, by name
  --
  -- The count above would pass if one were dropped and the other
  -- appeared, which is exactly the mistake a `status <> 'void'` written
  -- without `gl_entry_id is not null` makes.
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('an unposted invoice is on nobody''s statement',
    (select count(*) from public.report_statement_of_account(
       v_cust, date '2026-03-01', date '2026-03-31') s
      where s.doc_no = (select doc_no from public.sales_documents
                         where id = v_draft)), 0);
  perform pg_temp.check_eq('nor a voided one',
    (select count(*) from public.report_statement_of_account(
       v_cust, date '2026-03-01', date '2026-03-31') s
      where s.doc_no = (select doc_no from public.sales_documents
                         where id = v_void)), 0);

  -- Money on account is a line, not a silence. The customer paid it and
  -- their own books say so; a statement that left it off would be
  -- asking for 500 they have already sent.
  perform pg_temp.check_eq('an unapplied receipt is on it',
    (select count(*) from public.report_statement_of_account(
       v_cust, date '2026-03-01', date '2026-03-31') s
      where s.kind = 'receipt'), 2);

  -- And it is one customer's statement, not the company's.
  perform pg_temp.check_eq('somebody else''s documents are not on it',
    (select count(*) from public.report_statement_of_account(
       v_other, date '2026-03-01', date '2026-03-31') s
      where s.line_no > 0), 0);
end $$;

-- ---------------------------------------------------------------------
-- The period is a period
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.soa_org('Bawa Ke Hadapan Sdn Bhd');
  v_cust uuid;
  v_inv  uuid;
  v_msg  text;
begin
  v_cust := pg_temp.customer(v_org, 'C-BF1', 'Last Month');
  v_inv := pg_temp.sales_doc(v_org, v_cust, 'invoice', 'INV-BF1', 2500,
                             date '2026-02-10', date '2026-03-12');

  -- February's invoice is not a March line; it is March's opening
  -- balance. Getting this wrong is how a customer is billed twice on
  -- two statements.
  perform pg_temp.check_eq('last month is brought forward, not repeated',
    (select s.balance from public.report_statement_of_account(
       v_cust, date '2026-03-01', date '2026-03-31') s
      where s.line_no = 0), 2500);
  perform pg_temp.check_eq('and does not appear again as a line',
    (select count(*) from public.report_statement_of_account(
       v_cust, date '2026-03-01', date '2026-03-31') s
      where s.line_no > 0), 0);

  -- A statement that ends before it begins is a mistake worth a
  -- sentence rather than an empty page.
  begin
    perform * from public.report_statement_of_account(
      v_cust, date '2026-03-31', date '2026-03-01');
    v_msg := null;
  exception when sqlstate '22023' then v_msg := 'refused';
  end;
  perform pg_temp.check_eq('a backwards period is refused', v_msg,
    'refused');
end $$;

-- ---------------------------------------------------------------------
-- Whose ledger it is
-- ---------------------------------------------------------------------
do $$
declare
  v_org      uuid := pg_temp.soa_org('Sulit Sdn Bhd');
  v_cust     uuid;
  v_stranger uuid := pg_temp.another_user('nosy@statement.test');
  v_msg      text;
begin
  v_cust := pg_temp.customer(v_org, 'C-SEC1', 'Private Client');

  -- The function is SECURITY DEFINER and reads two tables directly, so
  -- the guard is the only thing between a contact uuid and a customer's
  -- whole ledger.
  perform pg_temp.sign_in_as(v_stranger);
  begin
    perform * from public.report_statement_of_account(v_cust);
    v_msg := null;
  exception when sqlstate '42501' then v_msg := 'refused';
  end;
  perform pg_temp.sign_in_as(v_stranger);
  perform pg_temp.check_eq('a stranger holding the uuid is refused', v_msg,
    'refused');

  begin
    perform public.statement_balance(v_cust);
    v_msg := null;
  exception when sqlstate '42501' then v_msg := 'refused';
  end;
  perform pg_temp.sign_in_as(v_stranger);
  perform pg_temp.check_eq('and so is the balance on its own', v_msg,
    'refused');
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('the statement is a signed-in user''s',
    has_function_privilege('authenticated',
      'public.report_statement_of_account(uuid, date, date)', 'execute'));
  perform pg_temp.check_true('and not a stranger''s',
    not has_function_privilege('anon',
      'public.report_statement_of_account(uuid, date, date)', 'execute'));
  perform pg_temp.check_true('the balance likewise',
    has_function_privilege('authenticated',
      'public.statement_balance(uuid, date)', 'execute'));
  perform pg_temp.check_true('and likewise not',
    not has_function_privilege('anon',
      'public.statement_balance(uuid, date)', 'execute'));
end $$;

rollback;
