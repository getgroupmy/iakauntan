-- =====================================================================
-- iAkauntan :: an approval covers what was approved (0908)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/an_approval_covers_what_was_approved.sql
--
-- Before `0908` an approved request let its document post whatever the
-- document had become since: an invoice approved at RM6,000 by the one
-- approver its amount called for was raised to RM600,000 and posted,
-- and the director a RM100,000 rule names was never asked. And every
-- reader compared a rule's ringgit amount with the document's total in
-- its own currency, so USD 2,000 at 4.4 posted under a RM5,000 rule.
--
-- Rules here: any sales or purchase document of RM5,000 or more needs
-- the manager; RM100,000 or more, the director after the manager. The
-- owner raises and posts; the two approve. Client statements run with
-- the role `authenticated`, as the app's do.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_ac (org uuid, owner uuid, boss uuid, dir uuid,
                             cust_a uuid, cust_b uuid, ac uuid);
grant select on t_ac to authenticated;

do $$
declare r t_ac;
begin
  r.owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(r.owner);
  r.org := pg_temp.test_org('Kelulusan Tepat Sdn Bhd');
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (r.org, 'approvals', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  r.boss := pg_temp.another_user('pengurus@kelulusan.test');
  r.dir := pg_temp.another_user('pengarah@kelulusan.test');
  insert into public.org_members (org_id, user_id, role)
  values (r.org, r.boss, 'admin'), (r.org, r.dir, 'admin') on conflict do nothing;
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 30);
  select id into r.ac from public.accounts where org_id = r.org and code = '4100';
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'CA', 'Pelanggan Asal', 'customer') returning id into r.cust_a;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'CB', 'Pelanggan Lain', 'customer') returning id into r.cust_b;
  insert into public.approval_rules (org_id, entity_kind, min_amount, step_no, approver_user_id)
  values (r.org, 'sales_document', 5000, 1, r.boss),
         (r.org, 'sales_document', 100000, 2, r.dir);
  insert into t_ac select r.*;
end $$;

set local role authenticated;

-- A draft invoice or quotation of one line.
create or replace function pg_temp.ac_doc(p_type text, p_no text, p_cust uuid,
                                          p_cur text, p_rate numeric, p_amount numeric)
returns uuid language plpgsql as $$
declare d t_ac; v uuid;
begin
  select * into d from t_ac;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, p_type::app.sales_doc_type, p_no, pg_temp.today(), pg_temp.today(),
          p_cust, p_cur, p_rate, 'draft')
  returning id into v;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price, account_id, tax_rate)
  values (d.org, v, 1, 'item', 'Khidmat', 1, p_amount, d.ac, 0);
  return v;
end $$;

-- Sent by the owner, approved by whoever each step names.
create or replace function pg_temp.ac_approve(p_doc uuid) returns uuid language plpgsql as $$
declare d t_ac; v_req uuid; s record;
begin
  select * into d from t_ac;
  perform pg_temp.sign_in_as(d.owner);
  v_req := public.submit_for_approval('sales_document', p_doc);
  for s in select approver_user_id from public.approval_steps
            where request_id = v_req order by step_no loop
    perform pg_temp.sign_in_as(s.approver_user_id);
    perform public.decide_approval(v_req, true, 'Lulus');
  end loop;
  perform pg_temp.sign_in_as(d.owner);
  return v_req;
end $$;

create or replace function pg_temp.ac_state(p_doc uuid) returns text language sql as $$
  select concat_ws(' / ', 'required ' || s.is_required, 'approved ' || s.is_approved,
                   'request ' || coalesce(s.request_status::text, 'none'))
    from public.approval_state('sales_document', p_doc) s;
$$;

do $$
declare d t_ac; v_inv uuid; v_req uuid;
begin
  select * into d from t_ac;
  perform pg_temp.sign_in_as(d.owner);

  -- -------------------------------------------------------------------
  -- Approved at RM6,000, raised to RM600,000
  -- -------------------------------------------------------------------
  v_inv := pg_temp.ac_doc('invoice', 'INV-NAIK', d.cust_a, 'MYR', 1, 6000);
  v_req := pg_temp.ac_approve(v_inv);
  perform pg_temp.check_eq('sent at RM6,000 for one customer, with the one step its amount calls for',
    (select q.amount::text || ' / ' || c.name || ' / ' ||
            (select count(*) from public.approval_steps s where s.request_id = q.id)
       from public.approval_requests q join public.contacts c on c.id = q.contact_id
      where q.id = v_req), '6000.00 / Pelanggan Asal / 1');
  perform pg_temp.check_eq('and approved, the editor says so',
    pg_temp.ac_state(v_inv), 'required true / approved true / request none');

  update public.sales_document_lines set quantity = 100 where document_id = v_inv;
  perform pg_temp.check_eq('raised to RM600,000, it is no longer approved, and nothing is waiting',
    pg_temp.ac_state(v_inv), 'required true / approved false / request none');
  perform pg_temp.check_refused('so it does not post, and is told why',
    format('select public.post_sales_document(%L)', v_inv),
    'INV-NAIK was approved at 6000.00 for Pelanggan Asal, and is now 600000.00 for Pelanggan Asal. An approval covers what was approved: send it for approval again.',
    '42501');

  v_req := public.submit_for_approval('sales_document', v_inv);
  perform pg_temp.check_eq('sent again, it goes to the director as well',
    (select q.amount::text || ' / ' ||
            (select string_agg(s.step_no::text, ',' order by s.step_no)
               from public.approval_steps s where s.request_id = q.id)
       from public.approval_requests q where q.id = v_req), '600000.00 / 1,2');
  perform pg_temp.sign_in_as(d.boss);
  perform public.decide_approval(v_req, true, 'Setuju');
  perform pg_temp.sign_in_as(d.owner);
  perform pg_temp.check_refused('the manager alone does not cover it',
    format('select public.post_sales_document(%L)', v_inv),
    'INV-NAIK was approved at 6000.00%', '42501');
  perform pg_temp.sign_in_as(d.dir);
  perform public.decide_approval(v_req, true, 'Setuju');
  perform pg_temp.sign_in_as(d.owner);
  perform public.post_sales_document(v_inv);
  perform pg_temp.check_eq('with both, it posts what was approved',
    (select s.status::text || ' / ' ||
            (select sum(l.debit - l.credit) from public.gl_lines l
               join public.accounts a on a.id = l.account_id
              where l.entry_id = s.gl_entry_id and a.code = '1210')::text
       from public.sales_documents s where s.id = v_inv), 'posted / 600000.00');

  -- -------------------------------------------------------------------
  -- Down is still covered; another customer is not
  -- -------------------------------------------------------------------
  v_inv := pg_temp.ac_doc('invoice', 'INV-TURUN', d.cust_a, 'MYR', 1, 8000);
  perform pg_temp.ac_approve(v_inv);
  update public.sales_document_lines set unit_price = 7000 where document_id = v_inv;
  perform public.post_sales_document(v_inv);
  perform pg_temp.check_eq('approved at RM8,000 and brought down to RM7,000, it posts',
    (select status::text from public.sales_documents where id = v_inv), 'posted');

  v_inv := pg_temp.ac_doc('invoice', 'INV-TUKAR', d.cust_a, 'MYR', 1, 7000);
  perform pg_temp.ac_approve(v_inv);
  update public.sales_documents set contact_id = d.cust_b where id = v_inv;
  perform pg_temp.check_refused('approved for one customer and made out to another, it does not',
    format('select public.post_sales_document(%L)', v_inv),
    'INV-TUKAR was approved at 7000.00 for Pelanggan Asal, and is now 7000.00 for Pelanggan Lain.%',
    '42501');
end $$;

do $$
declare d t_ac; v_inv uuid; v_q uuid; v_req uuid;
begin
  select * into d from t_ac;
  perform pg_temp.sign_in_as(d.owner);

  -- -------------------------------------------------------------------
  -- In ringgit: USD 2,000 at 4.4 is RM8,800
  -- -------------------------------------------------------------------
  v_inv := pg_temp.ac_doc('invoice', 'INV-USD', d.cust_a, 'USD', 4.4, 2000);
  perform pg_temp.check_eq('USD 2,000 at 4.4 is over a RM5,000 rule',
    pg_temp.ac_state(v_inv), 'required true / approved false / request none');
  perform pg_temp.check_refused('and does not post unsent',
    format('select public.post_sales_document(%L)', v_inv),
    'This needs approving before it can be posted.%', '42501');
  v_req := pg_temp.ac_approve(v_inv);
  perform pg_temp.check_eq('sent, it is asked for in ringgit',
    (select amount from public.approval_requests where id = v_req), 8800.00::numeric);

  update public.sales_documents set exchange_rate = 4.6 where id = v_inv;
  perform pg_temp.check_refused('at another rate it is another amount',
    format('select public.post_sales_document(%L)', v_inv),
    'INV-USD was approved at 8800.00 for Pelanggan Asal, and is now 9200.00 for Pelanggan Asal.%',
    '42501');

  -- -------------------------------------------------------------------
  -- The transfer reads it the same way
  -- -------------------------------------------------------------------
  v_q := pg_temp.ac_doc('quotation', 'QT-USD', d.cust_a, 'USD', 4.4, 2000);
  perform pg_temp.check_refused('a USD 2,000 quotation is not turned into an invoice unapproved',
    format('select public.transfer_document(%L, %L)', v_q, 'invoice'),
    'QT-USD needs approving before it can be turned into a invoice.%', '42501');
  perform pg_temp.ac_approve(v_q);
  update public.sales_document_lines set quantity = 2 where document_id = v_q;
  perform pg_temp.check_refused('nor once it has doubled since it was approved',
    format('select public.transfer_document(%L, %L)', v_q, 'invoice'),
    'QT-USD needs approving%', '42501');
end $$;

rollback;
