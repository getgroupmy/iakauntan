-- =====================================================================
-- iAkauntan :: attribution and the commission it implies
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/salespeople.sql
--
-- `sales_documents.salesperson_id` sat in the schema from 0005 with no
-- foreign key and no caller. The point of 0105 is not that it now has a
-- dropdown; it is that a value in that column now means something a
-- report can be built on. So what is asserted here is the meaning:
--
--   * a credit note reduces the sale it reverses, because paying
--     commission on a sale that was credited back out is paying twice
--     for one mistake;
--   * a draft is not a sale;
--   * one organization cannot be credited to another's salesperson;
--   * the sales nobody was credited with are on the report, since that
--     is the figure an argument will be about.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.sales_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

create or replace function pg_temp.person(
  p_org uuid, p_code text, p_rate numeric default null)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.salespeople (org_id, code, name, commission_rate)
  values (p_org, p_code, initcap(p_code), p_rate)
  returning id into v_id;
  return v_id;
end;
$$;

-- A posted sales document of any type, attributed or not.
create or replace function pg_temp.sale(
  p_org uuid, p_type text, p_amount numeric, p_person uuid,
  p_on date default date '2026-03-10', p_post boolean default true)
returns uuid language plpgsql as $$
declare v_cust uuid; v_doc uuid;
begin
  select id into v_cust from public.contacts
   where org_id = p_org and contact_type = 'customer' limit 1;
  if v_cust is null then
    insert into public.contacts (org_id, code, name, contact_type)
    values (p_org, 'C-001', 'Buyer', 'customer') returning id into v_cust;
  end if;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status, salesperson_id)
  values (p_org, p_type::app.sales_doc_type,
          upper(left(p_type, 3)) || '-' || substr(gen_random_uuid()::text, 1, 8),
          p_on, v_cust, 'MYR', 1,
          p_amount, p_amount, p_amount, 'draft', p_person)
  returning id into v_doc;

  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_doc, 1, 'Goods', 1, p_amount);

  if p_post then perform public.post_sales_document(v_doc); end if;
  return v_doc;
end;
$$;

-- ---------------------------------------------------------------------
-- The column now means something
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.sales_org('Attribution Sdn Bhd');
  v_ali uuid; v_siti uuid;
  r record;
begin
  v_ali  := pg_temp.person(v_org, 'ali',  2.5);
  v_siti := pg_temp.person(v_org, 'siti');   -- no rate agreed

  perform pg_temp.sale(v_org, 'invoice',     10000, v_ali);
  perform pg_temp.sale(v_org, 'invoice',      4000, v_ali);
  perform pg_temp.sale(v_org, 'credit_note',  2000, v_ali);
  perform pg_temp.sale(v_org, 'invoice',      7000, v_siti);

  select * into r from public.report_sales_by_person(
    v_org, date '2026-01-01', date '2026-12-31') where code = 'ali';

  perform pg_temp.check_eq('what was invoiced', r.invoiced, 14000);
  perform pg_temp.check_eq('what was credited back', r.credited, 2000);

  -- The figure the rate is applied to. Commission on 14,000 when 2,000
  -- has been credited is a business paying twice for one mistake.
  perform pg_temp.check_eq('and the sale is the net of the two',
    r.net_sales, 12000);
  perform pg_temp.check_eq('with commission taken on the net',
    r.commission, 300);     -- 12,000 at 2.5%

  select * into r from public.report_sales_by_person(
    v_org, date '2026-01-01', date '2026-12-31') where code = 'siti';
  perform pg_temp.check_eq('somebody else''s sales are their own',
    r.net_sales, 7000);
  perform pg_temp.check_true('and no rate means no commission figure, not zero',
    r.commission is null);
end $$;

-- ---------------------------------------------------------------------
-- What is not a sale
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.sales_org('Not A Sale Sdn Bhd');
  v_p uuid;
  r record;
begin
  v_p := pg_temp.person(v_org, 'lee', 10);

  perform pg_temp.sale(v_org, 'invoice', 5000, v_p);
  -- Raised, not posted. An invoice somebody is still editing has not
  -- earned anybody anything.
  perform pg_temp.sale(v_org, 'invoice', 90000, v_p, date '2026-03-10', false);
  -- Posted, but outside the period asked for.
  perform pg_temp.sale(v_org, 'invoice', 60000, v_p, date '2026-07-01');

  select * into r from public.report_sales_by_person(
    v_org, date '2026-01-01', date '2026-03-31') where code = 'lee';

  perform pg_temp.check_eq('a draft is not a sale and a later month is not this one',
    r.net_sales, 5000);
  perform pg_temp.check_eq('and the document count agrees', r.documents, 1);
end $$;

-- ---------------------------------------------------------------------
-- The sales nobody was credited with
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.sales_org('Unattributed Sdn Bhd');
  v_p uuid;
  r record;
begin
  v_p := pg_temp.person(v_org, 'raj', 5);
  perform pg_temp.sale(v_org, 'invoice', 1000, v_p);
  perform pg_temp.sale(v_org, 'invoice', 9000, null);

  select * into r from public.report_sales_by_person(
    v_org, date '2026-01-01', date '2026-12-31') where name = 'Not attributed';

  perform pg_temp.check_eq('what nobody was credited with is on the report',
    r.net_sales, 9000);
  perform pg_temp.check_true('and it carries no rate to imply a commission',
    r.commission is null and r.commission_rate is null);

  -- The two lines together are the whole book, which is what makes the
  -- report checkable against the profit and loss rather than a list of
  -- figures that might be missing something.
  perform pg_temp.check_eq('and the lines foot to everything sold',
    (select sum(net_sales) from public.report_sales_by_person(
       v_org, date '2026-01-01', date '2026-12-31')), 10000);
end $$;

-- ---------------------------------------------------------------------
-- One organization cannot be credited to another's salesperson
--
-- The foreign key alone would allow this. RLS would then hide the row on
-- read, so the document would show no salesperson at all — which looks
-- like nothing was set rather than like a document pointing across a
-- tenant boundary.
-- ---------------------------------------------------------------------
do $$
declare
  v_a uuid := pg_temp.sales_org('Theirs Sdn Bhd');
  v_b uuid := pg_temp.sales_org('Ours Sdn Bhd');
  v_theirs uuid;
begin
  v_theirs := pg_temp.person(v_a, 'their-rep', 1);

  begin
    perform pg_temp.sale(v_b, 'invoice', 100, v_theirs);
    raise exception 'FAIL: credited a sale to another organization''s salesperson';
  exception when sqlstate '23503' then
    raise notice 'ok   a salesperson cannot be borrowed across organizations';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Losing the person, keeping the history
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.sales_org('Leaver Sdn Bhd');
  v_p uuid; v_doc uuid;
begin
  v_p := pg_temp.person(v_org, 'gone', 3);
  v_doc := pg_temp.sale(v_org, 'invoice', 5000, v_p);

  delete from public.salespeople where id = v_p;

  -- The invoice keeps its figures and loses its attribution. Blocking
  -- the delete would make leavers permanent; cascading it would delete
  -- an invoice because somebody resigned.
  perform pg_temp.check_true('the document survives the person',
    (select status = 'posted' and salesperson_id is null
       from public.sales_documents where id = v_doc));
  perform pg_temp.check_eq('and it is still in the books',
    (select total_amount from public.sales_documents where id = v_doc), 5000);
end $$;

-- ---------------------------------------------------------------------
-- report_sales_by_person, rule by rule
--
-- A sweep of 0739's definition left ten of seventeen mutants alive.
-- Every fixture above is in ringgit at rate one, has no refund note,
-- nothing before the period, one salesperson per company and nobody's
-- name in the wrong alphabetical place -- so the currency, the refund,
-- the start of the period, the company boundary, the ordering and the
-- stranger were each a rule no row could tell from its absence.
-- ---------------------------------------------------------------------
create or replace function pg_temp.sale_in(
  p_org uuid, p_type text, p_amount numeric, p_person uuid,
  p_currency char(3), p_rate numeric, p_on date)
returns uuid language plpgsql as $$
declare v_cust uuid; v_doc uuid;
begin
  select id into v_cust from public.contacts
   where org_id = p_org and contact_type = 'customer' limit 1;
  if v_cust is null then
    insert into public.contacts (org_id, code, name, contact_type)
    values (p_org, 'C-001', 'Buyer', 'customer') returning id into v_cust;
  end if;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status, salesperson_id)
  values (p_org, p_type::app.sales_doc_type,
          upper(left(p_type, 3)) || '-' || substr(gen_random_uuid()::text, 1, 8),
          p_on, v_cust, p_currency, p_rate,
          p_amount, p_amount, p_amount, 'draft', p_person)
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_doc, 1, 'Goods', 1, p_amount);
  perform public.post_sales_document(v_doc);
  return v_doc;
end;
$$;

do $$
declare
  v_org uuid := pg_temp.sales_org('Rule By Rule Sales Sdn Bhd');
  v_owner uuid := auth.uid();
  v_other uuid;
  -- Named so the alphabet and the figures disagree: Aminah sells least.
  v_aminah uuid; v_zul uuid; v_gone uuid;
  r record;
  v_first text;
  v_stranger uuid := pg_temp.another_user('sales-stranger@example.test');
begin
  v_aminah := pg_temp.person(v_org, 'aminah', 10);
  v_zul    := pg_temp.person(v_org, 'zul', 10);

  -- Zul: 1,000 dollars at 4.00, and a 100-dollar credit at 4.00, so in
  -- ringgit 4,000 and 400 -- figures no reading in dollars produces.
  perform pg_temp.sale_in(v_org, 'invoice', 1000, v_zul, 'USD', 4, date '2026-03-10');
  perform pg_temp.sale_in(v_org, 'credit_note', 100, v_zul, 'USD', 4, date '2026-03-11');
  -- A refund note is money handed back: it comes off like a credit.
  perform pg_temp.sale_in(v_org, 'refund_note', 300, v_zul, 'MYR', 1, date '2026-03-12');
  -- Before the period asked for (which starts 1 February).
  perform pg_temp.sale_in(v_org, 'invoice', 50000, v_zul, 'MYR', 1, date '2026-01-15');

  perform pg_temp.sale_in(v_org, 'invoice', 2000, v_aminah, 'MYR', 1, date '2026-03-10');
  -- Posted, then soft-deleted: not a sale this report pays on.
  perform pg_temp.sale_in(v_org, 'invoice', 7000, v_aminah, 'MYR', 1, date '2026-03-10');
  update public.sales_documents set deleted_at = now()
   where org_id = v_org and salesperson_id = v_aminah and total_amount = 7000;

  -- Unattributed: an invoice and a credit against it.
  perform pg_temp.sale_in(v_org, 'invoice', 900, null, 'MYR', 1, date '2026-03-10');
  perform pg_temp.sale_in(v_org, 'credit_note', 200, null, 'MYR', 1, date '2026-03-10');

  select * into r from public.report_sales_by_person(
    v_org, date '2026-02-01', date '2026-12-31') where code = 'zul';
  perform pg_temp.check_eq('a foreign invoice is counted in ringgit', r.invoiced, 4000);
  perform pg_temp.check_eq('a foreign credit and a refund come off in ringgit',
    r.credited, 400 + 300);
  perform pg_temp.check_eq('so the net is in ringgit too', r.net_sales, 3300);
  perform pg_temp.check_eq('and three documents in the period, not four',
    r.documents, 3);

  select * into r from public.report_sales_by_person(
    v_org, date '2026-02-01', date '2026-12-31') where code = 'aminah';
  perform pg_temp.check_eq('a deleted invoice earns nobody anything',
    r.net_sales, 2000);
  perform pg_temp.check_eq('nor counts as a document', r.documents, 1);

  select * into r from public.report_sales_by_person(
    v_org, date '2026-02-01', date '2026-12-31') where name = 'Not attributed';
  perform pg_temp.check_eq('the unattributed line is net of its credits too',
    r.net_sales, 700);

  select code into v_first from public.report_sales_by_person(
    v_org, date '2026-02-01', date '2026-12-31') limit 1;
  perform pg_temp.check_eq('the biggest seller is first, whatever the alphabet says',
    v_first, 'zul');

  -- Another company, with a salesperson of its own.
  v_other := pg_temp.sales_org('Rule By Rule Other Sdn Bhd');
  v_gone := pg_temp.person(v_other, 'outsider', 5);
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_eq('another company''s salespeople are not listed',
    (select count(*)::integer from public.report_sales_by_person(
       v_org, date '2026-02-01', date '2026-12-31') where code = 'outsider'), 0);

  perform pg_temp.sign_in_as(v_stranger);
  perform pg_temp.check_refused('a stranger cannot read the commission',
    format('select * from public.report_sales_by_person(%L, %L, %L)',
           v_org, date '2026-02-01', date '2026-12-31'),
    '%Not allowed to read the ledger%', '42501');
  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- A debit note is a sale (0750)
--
-- It is the extra charge on a sale and posts revenue like one, so it is
-- invoiced, the person who made the sale is credited with it, and the
-- report foots to the profit and loss with one in the period -- which
-- is the property the "lines foot to everything sold" assertion above
-- is about, and which a debit note quietly broke.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.sales_org('Debit Note Sales Sdn Bhd');
  v_p uuid;
  r record;
begin
  v_p := pg_temp.person(v_org, 'dina', 10);
  perform pg_temp.sale_in(v_org, 'invoice',     1000, v_p, 'MYR', 1, date '2026-03-10');
  perform pg_temp.sale_in(v_org, 'debit_note',   200, v_p, 'MYR', 1, date '2026-03-12');
  perform pg_temp.sale_in(v_org, 'credit_note',  100, v_p, 'MYR', 1, date '2026-03-14');

  select * into r from public.report_sales_by_person(
    v_org, date '2026-01-01', date '2026-12-31') where code = 'dina';
  perform pg_temp.check_eq('a debit note is invoiced', r.invoiced, 1200);
  perform pg_temp.check_eq('and counted as a document', r.documents, 3);
  perform pg_temp.check_eq('so commission is on the charge too', r.commission, 110);

  perform pg_temp.check_eq('and the report foots to the revenue in the ledger',
    (select sum(net_sales) from public.report_sales_by_person(
       v_org, date '2026-01-01', date '2026-12-31')),
    (select sum(amount) from public.report_profit_loss(
       v_org, date '2026-01-01', date '2026-12-31')
      where account_type = 'revenue'));
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('the report is closed to anon',
    not has_function_privilege('anon',
      'public.report_sales_by_person(uuid, date, date)', 'execute'));
  perform pg_temp.check_true('and open to a signed-in user',
    has_function_privilege('authenticated',
      'public.report_sales_by_person(uuid, date, date)', 'execute'));
  perform pg_temp.check_true('the org check is not callable by hand',
    not has_function_privilege('authenticated',
      'app.check_salesperson_org()', 'execute'));
  perform pg_temp.check_true('the column points at salespeople',
    exists (select 1 from pg_constraint
             where conname = 'sales_documents_salesperson_fk'));

  -- The original key, which is what made this more than a tidy-up. It
  -- pointed at `auth.users`: a salesperson had to have a login, and
  -- `auth.users` is global, so it permitted one organization's invoice
  -- to name another organization's user with no policy to catch it.
  -- Leaving it alongside the new one would have made the column
  -- unsatisfiable rather than merely unused.
  perform pg_temp.check_true('and no longer at auth.users',
    not exists (select 1 from pg_constraint
                 where conname = 'sales_documents_salesperson_id_fkey'));
end $$;

rollback;
