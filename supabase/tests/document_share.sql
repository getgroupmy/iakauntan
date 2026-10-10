-- =====================================================================
-- iAkauntan :: document share link tests
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/document_share.sql
--
-- `open_shared_document` is the first function in this database that
-- `anon` may call, so it is the first one where getting the payload
-- wrong leaks something to the open internet rather than to another
-- signed-in user. Most of what follows asserts absence: what is *not*
-- in the response, and what `anon` is *not* granted.
--
-- The grant assertions are not decoration. Supabase's default
-- privileges hand `anon` every privilege on any new table in `public`,
-- so a token table is protected by RLS alone unless somebody takes them
-- back — and the first run of this file caught exactly that.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org uuid := pg_temp.test_org('Share Sdn Bhd');
  v_contact uuid; v_doc uuid;
  v_token text; v_second text; v_third text;
  v_result jsonb; v_revoked integer;
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  -- An accommodation operator, so the payload has both registrations
  -- to carry. See the 0642 assertions further down.
  update public.organizations
     set tourism_tax_reg_no = 'TTX-0001234' where id = v_org;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-001', 'Buyer Bhd', 'customer')
  returning id into v_contact;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status, notes, internal_notes)
  values (v_org, 'invoice', 'INV-1', date '2026-03-01', v_contact, 'MYR', 1,
          1000, 1000, 1000, 'draft',
          'Thank you for your business', 'Chase this one hard')
  returning id into v_doc;

  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     line_total, cost_amount)
  values (v_org, v_doc, 1, 'Consulting', 1, 1000, 1000, 400);

  -- A draft carries a number the sender has not committed to.
  begin
    perform public.share_document(v_doc);
    raise exception 'FAIL: shared a draft';
  exception when sqlstate '22023' then
    raise notice 'ok   a draft cannot be shared';
  end;

  perform public.post_sales_document(v_doc);
  v_token := public.share_document(v_doc, 30, 'buyer@example.com');

  perform pg_temp.check_true('a token comes back', length(v_token) = 64);

  -- The token is a credential. It goes out once and what stays behind
  -- is its hash, so a copy of this table is not a set of live links.
  perform pg_temp.check_true('and only its hash is kept',
    (select token_hash <> v_token
        and token_hash = app.corp_token_hash(v_token)
       from public.document_share_links where document_id = v_doc));

  v_result := public.open_shared_document(v_token);
  perform pg_temp.check_true('the link opens', v_result ->> 'state' = 'open');
  perform pg_temp.check_true('on the right document',
    v_result -> 'document' ->> 'doc_no' = 'INV-1');
  perform pg_temp.check_eq('with its lines',
    jsonb_array_length(v_result -> 'lines'), 1);
  perform pg_temp.check_true('and the note written for the customer',
    v_result -> 'document' ->> 'notes' = 'Thank you for your business');

  -- The two that would be a disaster.
  perform pg_temp.check_true('internal notes are not in the payload',
    v_result::text not like '%Chase this one hard%');
  perform pg_temp.check_true('and neither is what the line cost us',
    not (v_result -> 'lines' -> 0 ? 'cost_amount'));

  -- 0642: both of the company's tax registrations, and the reason
  -- this is asserted on the PAYLOAD rather than on the page.
  --
  -- `tourism_tax_reg_no` had existed since `0001` and nothing read it.
  -- The PDF and this page are one document seen two ways -- one is
  -- emailed, the other is opened from the link in that email -- so a
  -- registration printed on the file and missing from the page is a
  -- customer reading a different tax invoice from the one they were
  -- sent, and only a difference of one number in a grey line nobody
  -- looks at twice.
  perform pg_temp.check_true('the SST registration reaches the customer',
    v_result -> 'company' ? 'sst_registration_no');
  perform pg_temp.check_true('and the Tourism Tax one beside it',
    v_result -> 'company' ? 'tourism_tax_reg_no');

  -- Not merely present as a key: the value, from the row. A payload
  -- that carries the key with a null in it passes a `?` test and prints
  -- nothing on the page. The number is set at the top of this block
  -- rather than here, because opening the link again is counted and the
  -- assertion below is about the count.
  perform pg_temp.check_eq('with the number the company was issued',
    v_result -> 'company' ->> 'tourism_tax_reg_no', 'TTX-0001234');

  perform pg_temp.check_true('opening is recorded',
    (select opened_at is not null and open_count = 1
       from public.document_share_links where document_id = v_doc));

  -- A wrong token has to look like a revoked one. Telling somebody
  -- guessing tokens that they have found a real document is the whole
  -- reason this returns a state instead of raising.
  perform pg_temp.check_true('a token that matches nothing says invalid',
    (public.open_shared_document('not-a-real-token')) ->> 'state' = 'invalid');

  -- Reissuing retires the old link, or "revoke" means nothing.
  v_second := public.share_document(v_doc);
  perform pg_temp.check_true('reissuing kills the first token',
    (public.open_shared_document(v_token)) ->> 'state' = 'revoked');
  perform pg_temp.check_true('and the second one works',
    (public.open_shared_document(v_second)) ->> 'state' = 'open');
  perform pg_temp.check_eq('leaving exactly one live link',
    (select count(*) from public.document_share_links
      where document_id = v_doc and revoked_at is null), 1);

  v_revoked := public.revoke_document_share(v_doc);
  perform pg_temp.check_eq('revoking reports what it closed', v_revoked, 1);
  perform pg_temp.check_true('and the link is shut',
    (public.open_shared_document(v_second)) ->> 'state' = 'revoked');

  -- Voiding the document closes any live link without anybody
  -- remembering to revoke it.
  v_third := public.share_document(v_doc);
  update public.sales_documents set status = 'void' where id = v_doc;
  perform pg_temp.check_true('voiding withdraws a live link',
    (public.open_shared_document(v_third)) ->> 'state' = 'withdrawn');
end $$;

-- ---------------------------------------------------------------------
-- What `anon` may and may not do
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('anon may open a link',
    has_function_privilege('anon',
      'public.open_shared_document(text)', 'execute'));

  perform pg_temp.check_true('but may not issue one',
    not has_function_privilege('anon',
      'public.share_document(uuid, integer, text)', 'execute'));
  perform pg_temp.check_true('nor revoke one',
    not has_function_privilege('anon',
      'public.revoke_document_share(uuid)', 'execute'));

  -- RLS would stop anon reading rows here anyway, because the select
  -- policy says `to authenticated`. That is one defence for a table of
  -- credentials, and a policy edit could remove it without anybody
  -- noticing. The privilege is taken away as well.
  perform pg_temp.check_true('and cannot touch the token table at all',
    not has_table_privilege('anon', 'public.document_share_links', 'select'));
  perform pg_temp.check_true('in any direction',
    not has_table_privilege('anon', 'public.document_share_links', 'insert'));

  perform pg_temp.check_true('members may list their own links',
    has_table_privilege('authenticated',
      'public.document_share_links', 'select'));

  -- Inserts go through `share_document`, which is SECURITY DEFINER, so
  -- nothing needs the privilege directly — and without it nobody can
  -- write a row whose token they chose themselves.
  perform pg_temp.check_true('but cannot write a row around the function',
    not has_table_privilege('authenticated',
      'public.document_share_links', 'insert'));
end $$;

-- ---------------------------------------------------------------------
-- Revoking, rule by rule
--
-- The block above revokes one document's links as its owner. Nobody
-- else ever tried, no document that does not exist was named, and no
-- second document held a link for the revoke to leave alone.
-- ---------------------------------------------------------------------
do $$
declare
  v_org     uuid := pg_temp.test_org('Kongsi Satu Satu Sdn Bhd');
  v_contact uuid;
  v_one     uuid;
  v_two     uuid;
  v_keep    text;
  v_n       integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.open_years(v_org, pg_temp.today());
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pembeli', 'customer') returning id into v_contact;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status)
  values (v_org, 'invoice', 'INV-A', pg_temp.today(), v_contact, 'MYR', 1, 'draft'),
         (v_org, 'invoice', 'INV-B', pg_temp.today(), v_contact, 'MYR', 1, 'draft');
  select id into v_one from public.sales_documents where org_id = v_org and doc_no = 'INV-A';
  select id into v_two from public.sales_documents where org_id = v_org and doc_no = 'INV-B';
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_one, 1, 'Work', 1, 100), (v_org, v_two, 1, 'Work', 1, 200);
  perform public.post_sales_document(v_one);
  perform public.post_sales_document(v_two);
  perform public.share_document(v_one);
  v_keep := public.share_document(v_two);

  perform pg_temp.sign_in_as(pg_temp.another_user('orang-luar@kongsi.test'));
  perform pg_temp.check_refused('a stranger does not shut a company''s links',
    format('select public.revoke_document_share(%L)', v_one),
    'Not permitted', '42501');

  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_refused('a document that does not exist is said so',
    format('select public.revoke_document_share(%L)', gen_random_uuid()),
    'Document not found', 'P0002');

  v_n := public.revoke_document_share(v_one);
  perform pg_temp.check_eq('revoking one document shuts its link', v_n, 1);
  perform pg_temp.check_true('and leaves the other document''s open',
    (public.open_shared_document(v_keep)) ->> 'state' = 'open');

  perform pg_temp.sign_out();
end $$;

-- =====================================================================
-- A share link is the database's (0793)
--
-- The update policy was there so members could revoke. It allowed
-- every column, and on 10 October a revoked link that had gone to the
-- wrong address was revived, given fifty years, pointed at another
-- customer's invoice and given a made-up opened record -- under the
-- client role, as a member who may write. Everything below runs as
-- that client.
-- =====================================================================
create temporary table t_share (
  org uuid, clerk uuid, doc_a uuid, doc_b uuid,
  revoked uuid, live uuid, live_tok text, fn_tok text);
grant select, update on t_share to authenticated, anon;

do $$
declare
  v_org uuid := pg_temp.test_org('Kongsi Beku Sdn Bhd');
  v_ca uuid; v_cb uuid; v_a uuid; v_b uuid; v_clerk uuid;
  v_revoked uuid; v_live uuid; v_tok text;
begin
  perform pg_temp.open_years(v_org, pg_temp.today());
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-A', 'Pelanggan A Bhd', 'customer') returning id into v_ca;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-B', 'Pelanggan B Bhd', 'customer') returning id into v_cb;
  insert into public.sales_documents (org_id, doc_type, doc_no, doc_date,
    contact_id, currency, exchange_rate, status)
  values (v_org, 'invoice', 'INV-A', pg_temp.today(), v_ca, 'MYR', 1, 'draft')
  returning id into v_a;
  insert into public.sales_document_lines (org_id, document_id, line_no,
    description, quantity, unit_price)
  values (v_org, v_a, 1, 'Kerja A', 1, 100);
  insert into public.sales_documents (org_id, doc_type, doc_no, doc_date,
    contact_id, currency, exchange_rate, status)
  values (v_org, 'invoice', 'INV-B', pg_temp.today(), v_cb, 'MYR', 1, 'draft')
  returning id into v_b;
  insert into public.sales_document_lines (org_id, document_id, line_no,
    description, quantity, unit_price)
  values (v_org, v_b, 1, 'Kerja B', 1, 900);
  perform public.post_sales_document(v_a);
  perform public.post_sales_document(v_b);

  -- One sent to the wrong address and revoked; one live.
  perform public.share_document(v_a, 7, 'salah@example.test');
  select id into v_revoked from public.document_share_links where document_id = v_a;
  perform public.revoke_document_share(v_a);
  v_tok := public.share_document(v_a, 7, 'betul@example.test');
  select id into v_live from public.document_share_links
   where document_id = v_a and revoked_at is null;
  perform public.open_shared_document(v_tok);

  v_clerk := pg_temp.another_user('kerani-kongsi@example.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_clerk, 'accountant', 'active');
  insert into t_share values (v_org, v_clerk, v_a, v_b, v_revoked, v_live, v_tok, null);
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select clerk from t_share),
                    'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare c record;
begin
  select * into c from t_share;
  perform pg_temp.check_eq('the share links are asked as a client',
    current_user, 'authenticated');
  perform pg_temp.check_true('and the live link really was opened',
    (select opened_at is not null and open_count = 1
       from public.document_share_links where id = c.live));

  perform pg_temp.check_refused('a revoked link is not brought back',
    format('update public.document_share_links set revoked_at = null where id = %L', c.revoked),
    'A revoked share link stays revoked.%', '42501');
  perform pg_temp.check_refused('nor its revocation re-dated',
    format('update public.document_share_links set revoked_at = %L where id = %L',
           '2030-01-01', c.revoked),
    'A revoked share link stays revoked.%', '42501');
  perform pg_temp.check_refused('a link is not pointed at another customer''s invoice',
    format('update public.document_share_links set document_id = %L where id = %L',
           c.doc_b, c.live),
    'The document on a share link%', '42501');
  perform pg_temp.check_refused('nor its life extended',
    format('update public.document_share_links set expires_at = now() + interval %L where id = %L',
           '50 years', c.live),
    'The expiry on a share link%', '42501');
  perform pg_temp.check_refused('nor its token replaced',
    format('update public.document_share_links set token_hash = %L where id = %L',
           'chosen', c.live),
    'The token on a share link%', '42501');
  perform pg_temp.check_refused('nor its first opening re-dated',
    format('update public.document_share_links set opened_at = %L where id = %L',
           '2026-01-02', c.live),
    'The first opening on a share link%', '42501');
  perform pg_temp.check_refused('nor its last',
    format('update public.document_share_links set last_opened_at = %L where id = %L',
           '2026-01-02', c.live),
    'The last opening on a share link%', '42501');
  perform pg_temp.check_refused('nor its count of openings',
    format('update public.document_share_links set open_count = 7 where id = %L', c.live),
    'The count of openings on a share link%', '42501');
  perform pg_temp.check_refused('nor the address it was opened from',
    format('update public.document_share_links set ip_address = %L where id = %L',
           '198.51.100.9', c.live),
    'The opening address on a share link%', '42501');
  perform pg_temp.check_refused('nor the browser',
    format('update public.document_share_links set user_agent = %L where id = %L',
           'forged', c.live),
    'The opening browser on a share link%', '42501');
  perform pg_temp.check_refused('nor who issued it',
    format('update public.document_share_links set created_by = null where id = %L', c.live),
    'The author on a share link%', '42501');
  perform pg_temp.check_refused('nor when',
    format('update public.document_share_links set created_at = %L where id = %L',
           '2024-01-01', c.live),
    'The issue time on a share link%', '42501');
  -- Refused by the guard before any key is asked: it runs first.
  perform pg_temp.check_refused('nor which company it is',
    format('update public.document_share_links set org_id = %L where id = %L',
           gen_random_uuid(), c.live),
    'The company on a share link%', '42501');

  -- What is still the company's.
  update public.document_share_links set sent_to_email = 'betul.sekali@example.test'
   where id = c.live;
  perform pg_temp.check_eq('the address a link went to can be corrected',
    (select sent_to_email from public.document_share_links where id = c.live),
    'betul.sekali@example.test');
  update public.document_share_links set revoked_at = now() where id = c.live;
  perform pg_temp.check_true('and a live link can be revoked by hand',
    (select revoked_at is not null from public.document_share_links where id = c.live));

  -- And the functions, called by this same client.
  update t_share set fn_tok = public.share_document(c.doc_a, 7, 'baru@example.test');
  perform pg_temp.check_true('sharing through the function still works',
    (select fn_tok is not null from t_share));
end $$;

reset role;
select set_config('request.jwt.claims', '', true);
set local role anon;

do $$
begin
  perform pg_temp.check_eq('and a customer with no login still opens it',
    public.open_shared_document((select fn_tok from t_share)) ->> 'state', 'open');
end $$;

reset role;

do $$
begin
  perform pg_temp.check_true('which still records that they did',
    (select open_count = 1 and opened_at is not null
       from public.document_share_links
      where token_hash = app.corp_token_hash((select fn_tok from t_share))));
  perform pg_temp.check_eq('the rule is on the share links',
    (select count(*)::integer from pg_trigger
      where tgname = 'share_link_is_the_databases'
        and tgrelid = 'public.document_share_links'::regclass), 1);
end $$;

rollback;
