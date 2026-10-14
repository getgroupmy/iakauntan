-- =====================================================================
-- iAkauntan :: the tax is paid over after it was withheld (0893)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/tax_paid_over_after_withheld.sql
--
-- `remit_withholding` took any date, so withholding tax could be paid
-- over before the payment it was withheld from. Asked as an accountant,
-- with the role `authenticated`, as the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_tw (org uuid, accountant uuid, bank uuid, past uuid, ahead uuid);
grant select on t_tw to authenticated;

-- A certificate's remittance, and the days its two journals are dated,
-- counted from today: withheld, then paid over.
create or replace function pg_temp.tw_state(p_cert uuid)
returns text language sql as $$
  select coalesce((c.remitted_on - pg_temp.today())::text, 'not remitted') || ' / '
         || coalesce((select (e.entry_date - pg_temp.today())::text
                        from public.gl_entries e where e.id = c.gl_entry_id), 'none')
         || ' then ' ||
         coalesce((select (e.entry_date - pg_temp.today())::text
                     from public.gl_entries e where e.id = c.remittance_gl_entry_id), 'none')
    from public.withholding_certificates c where c.id = p_cert;
$$;

create or replace function pg_temp.tw_certificate(p_org uuid, p_supplier uuid,
  p_no text, p_on date)
returns uuid language plpgsql as $$
declare v_bill uuid; v_cert uuid;
begin
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (p_org, 'bill', p_no, p_on, p_on + 30, p_supplier, 'MYR', 1, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_bill, 1, 'Royalty', 1, 10000);
  perform public.post_purchase_document(v_bill);
  v_cert := public.create_withholding(v_bill, 'S109B_SPECIAL');
  perform public.post_withholding(v_cert);
  return v_cert;
end $$;

do $$
declare r t_tw; v_supplier uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Pegangan Cukai Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 60, pg_temp.today() + 90);
  r.accountant := pg_temp.another_user('akauntan@pegangancukai.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.accountant, 'accountant', 'active');
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'S1', 'Overseas Ltd', 'supplier') returning id into v_supplier;
  r.bank := pg_temp.test_bank_account(r.org, 'Semasa', 'current', 'MYR', 0, 0, '512345678909');
  -- Each certificate takes its bill's date: ten days ago, and twenty on.
  r.past  := pg_temp.tw_certificate(r.org, v_supplier, 'BILL-PAST', pg_temp.today() - 10);
  r.ahead := pg_temp.tw_certificate(r.org, v_supplier, 'BILL-AHEAD', pg_temp.today() + 20);
  insert into t_tw select r.*;
end $$;

select pg_temp.sign_in_as((select accountant from t_tw));
set local role authenticated;

do $$
declare d t_tw;
begin
  select * into d from t_tw;

  -- -------------------------------------------------------------------
  -- Not before the certificate's date
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('withholding tax is not paid over before it was withheld',
    format('select public.remit_withholding(%L, %L, %L)', d.past, pg_temp.today() - 30, d.bank),
    format('Certificate %% is dated %s, and the tax it withheld cannot be paid over before then.',
           to_char(pg_temp.today() - 10, 'DD Mon YYYY')),
    '23514');
  perform pg_temp.check_refused('not even the day before',
    format('select public.remit_withholding(%L, %L, %L)', d.past, pg_temp.today() - 11, d.bank),
    format('Certificate %% is dated %s, and the tax it withheld cannot be paid over before then.',
           to_char(pg_temp.today() - 10, 'DD Mon YYYY')),
    '23514');
  perform pg_temp.check_eq('so it is not remitted',
    pg_temp.tw_state(d.past), 'not remitted / -10 then none');
  perform public.remit_withholding(d.past, pg_temp.today() - 10, d.bank);
  perform pg_temp.check_eq('it is paid over on the day it was withheld',
    pg_temp.tw_state(d.past), '-10 / -10 then -10');

  -- -------------------------------------------------------------------
  -- Dated ahead: Remit's today is refused until the day comes
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('one dated ahead is not paid over today',
    format('select public.remit_withholding(%L, %L, %L)', d.ahead, pg_temp.today(), d.bank),
    format('Certificate %% is dated %s, and the tax it withheld cannot be paid over before then.',
           to_char(pg_temp.today() + 20, 'DD Mon YYYY')),
    '23514');
  perform pg_temp.check_eq('so it waits',
    pg_temp.tw_state(d.ahead), 'not remitted / 20 then none');
  perform public.remit_withholding(d.ahead, pg_temp.today() + 25, d.bank);
  perform pg_temp.check_eq('and is paid over after its day',
    pg_temp.tw_state(d.ahead), '25 / 20 then 25');
end $$;

reset role;

rollback;
