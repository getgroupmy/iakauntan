-- =====================================================================
-- iAkauntan :: 0797 a ringgit and a dollar are not two of anything
--
-- `open_customer_portal` (`0493`) is what a customer sees from their
-- account link, with no login: every invoice still open, and at the top
-- what they owe. The invoices came back each in its own currency, and
-- the figure at the top was every balance added together and labelled
-- with the company's base currency. Measured on 10 October 2026,
-- locally: a customer with an invoice of RM100 and one of USD 100 was
-- told "MYR 200.00" -- and the page said "RM 200.00" in its headline,
-- and showed the dollar invoice's row as "RM 100.00" too, because it
-- formatted every amount in the account's currency. A customer billed
-- only in dollars was told their dollars were ringgit.
--
-- Answered "a total per currency". The portal now returns `totals`, one
-- per currency, the base currency first; `total_outstanding` and
-- `currency` stay as they were wherever there is one currency (now that
-- currency, not the company's), and `total_outstanding` is null where
-- there are several. The page shows each total, and each invoice in its
-- own currency. Otherwise restated from `0493` (production's body hashes
-- identically, d982fe29...).
--
-- Production held 109 open invoices, every one in its company's base
-- currency, and no portal link, on 10 October.
-- =====================================================================

create or replace function public.open_customer_portal(p_token text)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  l       public.customer_portal_links;
  c       public.contacts;
  o       public.organizations;
  v_state text;
  v_rows  jsonb;
  v_owed  numeric;
  v_sums  jsonb;
  v_ccys  integer;
begin
  select * into l from public.customer_portal_links
   where token_hash = app.corp_token_hash(p_token);
  if l.id is null then
    return jsonb_build_object('state', 'invalid');
  end if;

  select * into c from public.contacts where id = l.contact_id;
  select * into o from public.organizations where id = l.org_id;

  v_state := case
    when l.revoked_at is not null then 'revoked'
    when l.expires_at < now() then 'expired'
    when c.id is null or c.deleted_at is not null then 'withdrawn'
    else 'open'
  end;

  -- Recorded even when the answer is 'expired', as 0067 has it: that
  -- somebody tried is worth as much as that somebody read it.
  update public.customer_portal_links
     set opened_at = coalesce(opened_at, now()),
         last_opened_at = now(),
         open_count = open_count + 1,
         ip_address = coalesce(ip_address, nullif(split_part(coalesce(
           app.request_header('x-forwarded-for'), ''), ',', 1), '')::inet),
         user_agent = coalesce(user_agent, app.request_header('user-agent'))
   where id = l.id;

  if v_state <> 'open' then
    return jsonb_build_object('state', v_state);
  end if;

  -- What this customer still owes. Posted and partial only: a draft is
  -- not a demand, and a void or rejected one is withdrawn. Every
  -- record of the same company counts -- 0477 links a contact's
  -- records through `party_id`, so a customer filed twice is one
  -- account here rather than two portals.
  --
  -- `0797`. The same invoices as before, and their balances added up
  -- currency by currency: a ringgit and a dollar are not two of
  -- anything, and the one figure this used to give, under the company's
  -- own currency, told a customer owing RM100 and USD 100 that they
  -- owed RM200.
  with open_docs as (
    select d.*
      from public.sales_documents d
     where d.org_id = l.org_id
       and d.contact_id in (
         select c2.id from public.contacts c2
          where c2.org_id = l.org_id
            and (c2.id = c.id
                 or (c.party_id is not null and c2.party_id = c.party_id)))
       and d.deleted_at is null
       and d.doc_type = 'invoice'
       and d.status in ('posted', 'partial')
       and coalesce(d.balance_amount, 0) > 0
  )
  select
    (select coalesce(jsonb_agg(jsonb_build_object(
              'id', d.id,
              'doc_no', d.doc_no,
              'doc_type', d.doc_type,
              'doc_date', d.doc_date,
              'due_date', d.due_date,
              'currency', d.currency,
              'total_amount', d.total_amount,
              'paid_amount', d.paid_amount,
              'balance_amount', d.balance_amount,
              'overdue', d.due_date is not null and d.due_date < app.today())
              order by d.due_date nulls last, d.doc_no), '[]'::jsonb)
       from open_docs d),
    (select coalesce(jsonb_agg(jsonb_build_object(
              'currency', s.currency, 'amount', s.amount)
              order by s.currency is distinct from coalesce(o.base_currency, 'MYR'),
                       s.currency), '[]'::jsonb)
       from (select d.currency, sum(d.balance_amount) as amount
               from open_docs d group by d.currency) s),
    (select count(distinct d.currency)::integer from open_docs d),
    (select coalesce(sum(d.balance_amount), 0) from open_docs d)
    into v_rows, v_sums, v_ccys, v_owed;

  return jsonb_build_object(
    'state', 'open',
    'company', jsonb_build_object(
      'name', coalesce(o.legal_name, o.name),
      'email', o.email,
      'phone', o.phone,
      'logo_url', o.logo_url),
    'contact', jsonb_build_object('name', c.name, 'code', c.code),
    -- One currency owed, or none: the one figure, in that currency
    -- (a customer billed only in dollars is owed in dollars, not in
    -- the company's ringgit). Several: no one figure, and `totals`
    -- says each.
    'currency', case when v_ccys = 1 then v_sums -> 0 ->> 'currency'
                     else coalesce(o.base_currency, 'MYR') end,
    'total_outstanding', case when v_ccys <= 1 then v_owed end,
    'totals', v_sums,
    'invoices', v_rows);
end $$;

-- `0165`'s event trigger takes EXECUTE from `anon` on every create or
-- replace, and a customer opening this link has no login.
grant execute on function public.open_customer_portal(text) to anon, authenticated;

comment on function public.open_customer_portal(text) is
  'What one customer owes, for somebody holding their portal token and '
  'no account. See 0493. Owed currency by currency in `totals`; one '
  'figure only where there is one currency. 0797.';
