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

rollback;
