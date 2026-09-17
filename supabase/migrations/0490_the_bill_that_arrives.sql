-- ---------------------------------------------------------------------
-- 0490  The bill that arrives
-- ---------------------------------------------------------------------
-- 0489 raises one invoice per company per month for the add-ons it
-- held, and tells nobody. The company finds out by opening Settings and
-- looking -- which is not how anybody learns they owe money, and is why
-- the whole of 0489 could run every month to no effect at all.
--
-- Every other document this product raises has a way of reaching the
-- person who owes it. `queue_document_email` has sent a customer their
-- invoice since 0068 and `queue_overdue_reminders` chases it. The
-- platform's own invoice, alone, had no such path.
--
-- ### What changes
--
--   * `app.queue_platform_invoice_email(invoice)` puts one message in
--     `email_outbox`: what the month cost, what it is for, and where to
--     settle it. The dedupe key is the invoice number, which is what
--     makes a scheduler that runs twice send once.
--
--   * `app.bill_org_modules` calls it, wrapped. A mail that cannot be
--     queued must not take the invoice with it: the invoice is the
--     record, the mail is the courtesy, and losing the record to save
--     the courtesy is the wrong way round. The daily pass would also
--     roll the whole month back for every company after it.
--
--   * `platform_invoice` joins `app.default_email_template`. Read from
--     there and not through `app.email_template`, which layers the
--     tenant's own overrides on top: a company editing the wording of
--     the bill *it* is sent is not a feature, and the tenant templates
--     are for the mail it sends its own customers.
--
-- ### Who it goes to
--
-- `organizations.email` if there is one, and otherwise the earliest
-- active owner's login, which is the address that made the company. A
-- company with neither gets no mail and keeps its invoice -- there is
-- nothing to be done about an address that does not exist, and it is
-- not a reason to refuse the bill.
--
-- The tenant's own `email_settings` are deliberately not consulted.
-- Those govern the mail a company sends its customers, through its own
-- reply-to and its own from-name; this is the platform writing to the
-- company, and a tenant that has never switched its own outbound mail
-- on is still a tenant that owes for its modules. `send-email` reads
-- only `to_email, subject, body, reply_to, from_name` from the row and
-- sends through the platform's own `MAIL_FROM`, so nothing else is
-- needed for it to go.
--
-- ### Mutants
--
-- Run against `supabase/tests/module_subscription.sql`, each named with
-- the assertion that kills it:
--   * nothing queued -- "the company is told its bill exists";
--   * the amount left out of the body -- "and the mail says what is
--     owed";
--   * the dedupe key not the invoice number -- "and queueing it again
--     finds the first". Not "running the month again does not send a
--     second copy", which is what it looked like it would be: a second
--     run of `bill_org_modules` returns 0489's existing invoice without
--     reaching the outbox at all, so the count stays at one either way.
--     What actually catches a key that is not the invoice number is
--     calling the queue directly, twice;
--   * the owner's login not used as a fallback -- "the company is told
--     its bill exists", which fires before the assertion about *which*
--     address, because with no fallback there is no mail to look at;
--   * the mail queued for a company with no address at all -- "with no
--     address anywhere, nothing is queued";
--   * the queue call left unwrapped. The test reaches this by replacing
--     the queue with one that raises, and unwrapped the raise escapes
--     `bill_org_modules` entirely -- so the file dies on "the outbox is
--     down" rather than on an assertion. That is the finding, not a
--     gap in the test: the invoice went with the mail;
--   * the tenant's own templates consulted -- "the wording of the
--     platform's own bill is not the tenant's to edit".
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- The wording
-- ---------------------------------------------------------------------
-- Restated from the built definition. The four templates below are
-- 0068's and 0083's, unchanged; `platform_invoice` is the new one.
create or replace function app.default_email_template(p_code text)
returns table(subject text, body text)
language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select t.subject, t.body from (values
    ('document_new',
     '{{doc_type}} {{doc_no}} from {{company_name}}',
     E'Dear {{contact_name}},\n\n{{doc_type}} {{doc_no}} dated {{doc_date}} is ready, for {{currency}} {{total_amount}}.\n\nYou can view it here: {{link}}\n\nRegards,\n{{company_name}}'),
    ('invoice_reminder',
     'Reminder: {{doc_no}} from {{company_name}}',
     E'Dear {{contact_name}},\n\nOur records show {{currency}} {{balance_amount}} outstanding on {{doc_no}}, which was due on {{due_date}}.\n\nYou can view it here: {{link}}\n\nIf you have already paid, please ignore this message and accept our apologies for the crossover.\n\nRegards,\n{{company_name}}'),
    ('payment_received',
     'Payment received — thank you',
     E'Dear {{contact_name}},\n\nThank you. We have received {{currency}} {{paid_amount}} against {{doc_no}}.\n\nRegards,\n{{company_name}}'),
    ('receipt_issued',
     'Receipt {{receipt_no}} from {{company_name}}',
     E'Dear {{contact_name}},\n\nThank you. We have received {{currency}} {{amount}} on {{receipt_date}}, and your receipt {{receipt_no}} is attached.\n\nThis has been set against {{applied_to}}.\n\nRegards,\n{{company_name}}'),
    -- 0490. The platform writing to a company about its own
    -- subscription. It names the month, the amount and the modules,
    -- because an invoice that says only a number is one somebody has to
    -- write in and ask about.
    ('platform_invoice',
     '{{invoice_no}} — {{period}} for {{company_name}}',
     E'Dear {{company_name}},\n\nYour iAkauntan invoice {{invoice_no}} is ready, for {{currency}} {{total_amount}}.\n\n{{description}}\n\nYou can see it and pay it under Settings, on the Your subscription card.\n\nRegards,\n{{issuer_name}}')
  ) as t (code, subject, body)
  where t.code = p_code;
$$;

-- ---------------------------------------------------------------------
-- The message
-- ---------------------------------------------------------------------
create or replace function app.queue_platform_invoice_email(p_invoice_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_inv  public.platform_invoices;
  v_to   text;
  v_vars jsonb;
  t      record;
  v_id   uuid;
begin
  select * into v_inv from public.platform_invoices where id = p_invoice_id;
  if not found then
    return null;
  end if;

  -- The company's own address first, then whoever made the company.
  -- `min(created_at)` and not "any owner": a company with three owners
  -- must send to the same one every month, or the dedupe key is the
  -- only thing standing between it and three copies.
  select coalesce(
           (select nullif(btrim(o.email), '')
              from public.organizations o where o.id = v_inv.org_id),
           (select u.email::text
              from public.org_members m
              join auth.users u on u.id = m.user_id
             where m.org_id = v_inv.org_id
               and m.role = 'owner' and m.status = 'active'
             order by m.joined_at nulls last, u.email
             limit 1))
    into v_to;
  if v_to is null then
    return null;
  end if;

  select * into t from app.default_email_template('platform_invoice');

  v_vars := jsonb_build_object(
    'company_name',  v_inv.bill_to_name,
    'issuer_name',   v_inv.issuer_name,
    'invoice_no',    v_inv.invoice_no,
    'currency',      v_inv.currency,
    'total_amount',  to_char(v_inv.total_amount, 'FM999G999G990D00'),
    'description',   v_inv.description,
    -- The first line of the description is "Modules for January 2026";
    -- the rest is the per-module breakdown 0489 puts after a newline.
    'period',        split_part(v_inv.description, chr(10), 1));

  begin
    insert into public.email_outbox
      (org_id, to_email, subject, body, from_name, template_code, dedupe_key)
    values (
      v_inv.org_id, v_to,
      app.render_email(t.subject, v_vars),
      app.render_email(t.body, v_vars),
      v_inv.issuer_name, 'platform_invoice',
      'platform-invoice:' || v_inv.invoice_no)
    returning id into v_id;
  exception when unique_violation then
    -- Already queued under this key. Nothing to do and nothing wrong.
    return null;
  end;

  return v_id;
end $$;

comment on function app.queue_platform_invoice_email(uuid) is
  'Puts one message in the outbox telling a company what its month of '
  'add-ons cost and where to settle it. Once per invoice number. '
  'See 0490.';

revoke all on function app.queue_platform_invoice_email(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The invoice sends itself
-- ---------------------------------------------------------------------
-- Restated from the built definition, which is 0489's. One block added
-- at the end; nothing else in it is touched.
create or replace function app.bill_org_modules(
  p_org_id uuid, p_month date)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_org      public.organizations;
  v_issuer   jsonb;
  v_prefix   text;
  v_seq      integer;
  v_no       text;
  v_rate     numeric(6, 3) := 0;
  v_sub      numeric;
  v_tax      numeric(18, 2) := 0;
  v_lines    text;
  v_id       uuid;
  v_first    date := date_trunc('month', p_month)::date;
  v_note     text;
begin
  select * into v_org from public.organizations where id = p_org_id;
  if v_org.id is null then
    return null;
  end if;
  -- A demo tenant exists to be looked at, not to be billed.
  if v_org.is_demo then
    return null;
  end if;

  -- Once per company per month. The note carries the period, which is
  -- what makes a second run find the first one rather than write
  -- another.
  v_note := 'modules:' || to_char(v_first, 'YYYY-MM');
  select id into v_id from public.platform_invoices
   where org_id = p_org_id and notes = v_note;
  if v_id is not null then
    return v_id;
  end if;

  select sum(d.amount),
         string_agg(d.name || ' -- ' || d.days || '/' || d.days_in_month
                    || ' days', chr(10) order by d.name)
    into v_sub, v_lines
    from app.module_days_in_month(p_org_id, v_first) d;

  -- Nothing held is not a bill for nothing; it is no bill.
  if coalesce(v_sub, 0) <= 0 then
    return null;
  end if;

  -- Read the same way 0421 reads it, from the same row. There is no
  -- accessor function for this setting; the one this first reached for
  -- does not exist, and a plpgsql body does not resolve its calls until
  -- it runs, so the migration applied and the first invoice would have
  -- been the one to find out.
  select value into v_issuer from public.platform_settings
   where key = 'platform_issuer';
  v_issuer := coalesce(v_issuer, '{}'::jsonb);

  -- SST is charged when the issuer is registered for it, and not
  -- otherwise. A rate left in the settings by a company that has since
  -- deregistered is not a licence to keep charging it, and 0421 already
  -- reads it this way -- two platform invoices for the same month that
  -- disagreed on tax would be the platform's own problem to explain.
  if coalesce((v_issuer ->> 'sst_registered')::boolean, false) then
    v_rate := coalesce((v_issuer ->> 'sst_rate')::numeric, 0);
  end if;
  v_tax := round(v_sub * v_rate / 100, 2);

  -- One number at a time, as 0421 has it: the monthly run and an
  -- administrator's top-up can land in the same second.
  perform pg_advisory_xact_lock(hashtext('platform_invoice_no'));
  v_prefix := coalesce(nullif(v_issuer ->> 'invoice_prefix', ''), 'KH');
  select coalesce(max(substring(i.invoice_no from '[0-9]+$')::integer), 0) + 1
    into v_seq
    from public.platform_invoices i
   where i.invoice_no like v_prefix || '-' || to_char(v_first, 'YYYY') || '-%';
  v_no := format('%s-%s-%s', v_prefix, to_char(v_first, 'YYYY'),
                 lpad(v_seq::text, 4, '0'));

  insert into public.platform_invoices (
    invoice_no, org_id, issue_date, currency,
    issuer_name, issuer_registration_no, issuer_old_registration_no,
    issuer_sst_no, issuer_address,
    bill_to_name, bill_to_registration_no, bill_to_tin, bill_to_address,
    description, subtotal, tax_rate, tax_amount, total_amount, notes)
  values (
    v_no, p_org_id, (v_first + interval '1 month')::date, 'MYR',
    coalesce(v_issuer ->> 'name', 'Kabeer Holdings Sdn Bhd'),
    v_issuer ->> 'registration_no',
    v_issuer ->> 'old_registration_no',
    nullif(v_issuer ->> 'sst_no', ''),
    nullif(v_issuer ->> 'address', ''),
    v_org.name, v_org.registration_no, v_org.tin, v_org.address_line1,
    -- FM, because `to_char(..., 'Month')` blank-pads the name to nine
    -- characters and the invoice would read "Modules for January
    -- 2026" with three spaces in the middle of it.
    'Modules for ' || to_char(v_first, 'FMMonth YYYY') || chr(10) || v_lines,
    v_sub, v_rate, v_tax, v_sub + v_tax, v_note)
  returning id into v_id;

  -- 0490. The company is told. Wrapped, because the invoice is the
  -- record and the mail is the courtesy: an outbox that refuses must
  -- not roll back the bill, and inside `bill_the_month` it would take
  -- every company after this one with it.
  begin
    perform app.queue_platform_invoice_email(v_id);
  exception when others then
    raise warning 'queue_platform_invoice_email failed for %: %',
      v_id, sqlerrm;
  end;

  return v_id;
end $$;

comment on function app.bill_org_modules(uuid, date) is
  'One invoice per company per month for the add-ons it held, '
  'pro-rated by days, and the mail that tells them so. Idempotent: a '
  'second run for the same month returns the invoice the first one '
  'wrote and queues nothing. See 0489, 0490.';

revoke all on function app.bill_org_modules(uuid, date)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
begin
  if has_function_privilege('authenticated',
       'app.queue_platform_invoice_email(uuid)', 'execute') then
    raise exception '0490: a tenant can send itself a bill';
  end if;
  if (select count(*) from app.default_email_template('platform_invoice')) <> 1
  then
    raise exception '0490: there is no wording for the platform invoice';
  end if;
  -- The four that were already there. The restatement above is the
  -- whole function, so one dropped on the floor would be silent.
  if (select count(*) from (
        select app.default_email_template(c) from (values
          ('document_new'), ('invoice_reminder'),
          ('payment_received'), ('receipt_issued')) v(c)) s) <> 4 then
    raise exception '0490: the templates that were already there are gone';
  end if;
  if position('queue_platform_invoice_email' in pg_get_functiondef(
       'app.bill_org_modules(uuid, date)'::regprocedure)) = 0 then
    raise exception '0490: the invoice still tells nobody';
  end if;
  -- 0489's own rules, which this restatement must not have lost.
  if position('is_demo' in pg_get_functiondef(
       'app.bill_org_modules(uuid, date)'::regprocedure)) = 0
     or position('modules:' in pg_get_functiondef(
       'app.bill_org_modules(uuid, date)'::regprocedure)) = 0 then
    raise exception '0490: the billing rules 0489 set were dropped';
  end if;
end $do$;
