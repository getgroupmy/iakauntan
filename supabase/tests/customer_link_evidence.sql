-- =====================================================================
-- iAkauntan :: a customer link is the database's (0794)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/customer_link_evidence.sql
--
-- Three tables hold links sent to customers -- the account portal, the
-- tax-details form, a shared support ticket -- and each let any member
-- who may write UPDATE every column. On 10 October a revoked portal link
-- was revived, given fifty years and pointed at another customer, and
-- its holder opened that customer's account. `0794` lets a client
-- change only the address a link went to and a live link's revocation.
--
-- Asked of EVERY column but those two, read from the catalogue rather
-- than listed here, because that is how the guard asks: a column added
-- to one of these tables later is refused until somebody decides
-- otherwise, and this file finds it without being edited.
--
-- Everything that matters runs under `set local role authenticated`, as
-- a member with the accountant's role.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_cl (
  org uuid, clerk uuid, other_contact uuid,
  portal_revoked uuid, portal_live uuid, portal_tok text,
  tax_revoked uuid, tax_live uuid, tax_tok text,
  ticket_revoked uuid, ticket_live uuid, ticket_tok text);
grant select, update on t_cl to authenticated, anon;

do $$
declare
  v_org uuid := pg_temp.test_org('Pautan Pelanggan Sdn Bhd');
  v_cust uuid; v_other uuid; v_tkt uuid; v_clerk uuid; v_tok text; v_url text;
  r t_cl;
begin
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'ticketing', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.contacts (org_id, contact_type, code, name, email)
  values (v_org, 'customer', 'C-1', 'Pelanggan Satu Bhd', 'satu@buyer.test')
  returning id into v_cust;
  insert into public.contacts (org_id, contact_type, code, name, email)
  values (v_org, 'customer', 'C-2', 'Pelanggan Dua Bhd', 'dua@buyer.test')
  returning id into v_other;
  r.org := v_org;
  r.other_contact := v_other;

  -- The portal: one issued and revoked, one live and opened.
  perform public.share_customer_portal(v_cust, 60);
  select id into r.portal_revoked from public.customer_portal_links
   where contact_id = v_cust;
  perform public.revoke_customer_portal(v_cust);
  v_url := public.share_customer_portal(v_cust, 60) ->> 'url';
  r.portal_tok := regexp_replace(v_url, '^.*/', '');
  select id into r.portal_live from public.customer_portal_links
   where contact_id = v_cust and revoked_at is null;
  perform public.open_customer_portal(r.portal_tok);

  -- The tax-details form, the same way.
  perform public.request_tax_details(v_cust);
  select id into r.tax_revoked from public.tax_detail_requests
   where contact_id = v_cust;
  perform public.revoke_tax_detail_request(v_cust);
  v_url := public.request_tax_details(v_cust) ->> 'url';
  r.tax_tok := regexp_replace(v_url, '^.*/', '');
  select id into r.tax_live from public.tax_detail_requests
   where contact_id = v_cust and revoked_at is null;
  perform public.open_tax_detail_request(r.tax_tok);

  -- And a ticket.
  v_tkt := public.create_ticket(v_org, 'Pencetak rosak', 'Sejak pagi tadi',
    null, 'p3', null, 'email', null, v_cust);
  perform public.share_ticket(v_tkt, 30, 'satu@buyer.test');
  select id into r.ticket_revoked from public.ticket_share_links
   where ticket_id = v_tkt;
  perform public.revoke_ticket_share(v_tkt);
  r.ticket_tok := public.share_ticket(v_tkt, 30, 'satu@buyer.test');
  select id into r.ticket_live from public.ticket_share_links
   where ticket_id = v_tkt and revoked_at is null;
  perform public.open_shared_ticket(r.ticket_tok);

  v_clerk := pg_temp.another_user('kerani-pautan-pelanggan@example.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_clerk, 'accountant', 'active');
  r.clerk := v_clerk;
  insert into t_cl select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select clerk from t_cl),
                    'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  c      t_cl;
  t      record;
  col    record;
  v_expr text;
  v_n    integer := 0;
begin
  select * into c from t_cl;
  perform pg_temp.check_eq('the customer links are asked as a client',
    current_user, 'authenticated');

  for t in
    select * from (values
      ('customer_portal_links', c.portal_revoked, c.portal_live),
      ('tax_detail_requests',   c.tax_revoked,    c.tax_live),
      ('ticket_share_links',    c.ticket_revoked, c.ticket_live)) v(tbl, revoked, live)
  loop
    perform pg_temp.check_true(t.tbl || ': the live link really was opened',
      (select (x ->> 'opened_at') is not null
         from (select to_jsonb(l) as x from public.customer_portal_links l
                where l.id = t.live
               union all
               select to_jsonb(l) from public.tax_detail_requests l where l.id = t.live
               union all
               select to_jsonb(l) from public.ticket_share_links l where l.id = t.live) s));

    -- Every column but the two the company keeps, each in turn.
    for col in
      select column_name, data_type from information_schema.columns
       where table_schema = 'public' and table_name = t.tbl
         and column_name not in ('sent_to_email', 'revoked_at')
       order by ordinal_position
    loop
      v_expr := case
        when col.column_name = 'contact_id' then quote_literal(c.other_contact)
        when col.data_type = 'uuid' then 'gen_random_uuid()'
        when col.data_type like 'timestamp%' then $q$now() + interval '50 years'$q$
        when col.data_type in ('integer', 'bigint', 'smallint') then col.column_name || ' + 5'
        when col.data_type = 'inet' then $q$'198.51.100.9'$q$
        else $q$'forged'$q$ end;
      perform pg_temp.check_refused(
        t.tbl || ': a client cannot write ' || col.column_name,
        format('update public.%I set %I = %s where id = %L',
               t.tbl, col.column_name, v_expr, t.live),
        'The ' || replace(col.column_name, '_', ' ')
          || ' of a link sent to a customer is the database''s to write%',
        '42501');
      v_n := v_n + 1;
    end loop;

    perform pg_temp.check_refused(t.tbl || ': a revoked link is not brought back',
      format('update public.%I set revoked_at = null where id = %L', t.tbl, t.revoked),
      'A revoked link stays revoked.%', '42501');
    perform pg_temp.check_refused(t.tbl || ': nor its revocation re-dated',
      format('update public.%I set revoked_at = %L where id = %L',
             t.tbl, '2030-01-01', t.revoked),
      'A revoked link stays revoked.%', '42501');

    -- What is still the company's.
    execute format('update public.%I set sent_to_email = %L where id = %L',
                   t.tbl, 'betul@buyer.test', t.live);
    execute format('update public.%I set revoked_at = now() where id = %L',
                   t.tbl, t.live);
    perform pg_temp.check_true(t.tbl || ': the address can be corrected and a live link revoked',
      (select count(*) = 1 from (
         select sent_to_email, revoked_at from public.customer_portal_links where id = t.live
         union all
         select sent_to_email, revoked_at from public.tax_detail_requests where id = t.live
         union all
         select sent_to_email, revoked_at from public.ticket_share_links where id = t.live) s
        where s.sent_to_email = 'betul@buyer.test' and s.revoked_at is not null));
  end loop;

  -- The control on the loop itself: a loop over no columns reports no
  -- failures just as quietly as one that passes.
  perform pg_temp.check_true('every guarded column of all three tables was asked',
    v_n >= 30);

  -- And the functions, called by this same client, still issue links.
  update t_cl set
    portal_tok = regexp_replace(public.share_customer_portal(
      (select contact_id from public.customer_portal_links where id = c.portal_live), 60)
      ->> 'url', '^.*/', ''),
    tax_tok = regexp_replace(public.request_tax_details(
      (select contact_id from public.tax_detail_requests where id = c.tax_live))
      ->> 'url', '^.*/', ''),
    ticket_tok = public.share_ticket(
      (select ticket_id from public.ticket_share_links where id = c.ticket_live),
      30, 'satu@buyer.test');
end $$;

reset role;
select set_config('request.jwt.claims', '', true);
set local role anon;

do $$
declare c t_cl;
begin
  select * into c from t_cl;
  perform pg_temp.check_eq('a customer with no login opens the portal it issued',
    public.open_customer_portal(c.portal_tok) ->> 'state', 'open');
  perform pg_temp.check_eq('and the tax-details form',
    public.open_tax_detail_request(c.tax_tok) ->> 'state', 'open');
  perform pg_temp.check_eq('and the ticket',
    public.open_shared_ticket(c.ticket_tok) ->> 'state', 'open');
end $$;

reset role;

do $$
begin
  perform pg_temp.check_eq('the rule is on all three tables',
    (select count(*)::integer from pg_trigger
      where tgname = 'customer_link_is_the_databases'
        and tgrelid in ('public.customer_portal_links'::regclass,
                        'public.tax_detail_requests'::regclass,
                        'public.ticket_share_links'::regclass)), 3);
end $$;

rollback;
