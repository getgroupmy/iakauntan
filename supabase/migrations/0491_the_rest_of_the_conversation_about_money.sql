-- ---------------------------------------------------------------------
-- 0491  The rest of the conversation about money
-- ---------------------------------------------------------------------
-- 0489 raises the subscription invoice, 0490 sends it. Two things that
-- happen to every other invoice in this product still do not happen to
-- the platform's own:
--
--   * **Nobody chases it.** `queue_overdue_reminders` has chased a
--     tenant's own customers since 0068, on the days that tenant chose.
--     An unpaid platform invoice sits there. One mail on the first of
--     the month is not a billing system; it is a billing system's
--     opening sentence.
--
--   * **Nobody is thanked for paying it.** `settle_gateway_payment`
--     marks the invoice paid and says nothing, and
--     `platform_mark_invoice_paid` -- an administrator settling one by
--     hand, after a transfer -- says nothing either. A tenant's own
--     customer gets `payment_received`. The company that just paid
--     iAkauntan gets silence, and no way to tell "they have it" from
--     "it did not go through".
--
-- ### What changes
--
--   * `app.platform_billing_email(org)` is the recipient rule, lifted
--     out of 0490 where it was written inline: the company's own
--     address, and failing that the earliest active owner's login.
--     Three callers need it now, and a rule about who gets told what
--     they owe should exist once.
--
--   * `app.chase_platform_invoices(on)` queues a reminder for every
--     invoice still `issued` whose age in days is one of the chase
--     days. Read from `platform_settings`, `platform_issuer ->
--     'reminder_days'`, defaulting to 7, 14 and 30. Days since issue
--     rather than days overdue, because `platform_invoices` has an
--     `issue_date` and no due date -- inventing one here would be a
--     column this migration cannot add to a table other things already
--     write.
--
--   * `app.run_daily_jobs` calls it, wrapped, beside the rest.
--
--   * `app.queue_platform_payment_received(invoice)` is the thank-you,
--     called from both places an invoice can become paid.
--
-- ### What it still does not do
--
-- Nothing happens to a company that never pays. No dunning past the
-- last reminder, no suspension, no module switched off. That is a
-- product decision rather than an oversight, and it is not one to make
-- inside a migration about email -- but it is worth writing down that
-- the answer today is "we ask three times and then stop asking".
--
-- ### Mutants
--
-- Run against `supabase/tests/module_subscription.sql`, each named with
-- the assertion that kills it:
--   * nothing chased -- "an invoice still unpaid after a week is
--     chased";
--   * chased on every day rather than the chase days -- "and not on
--     the days in between";
--   * a paid invoice chased -- "an invoice already paid is left alone";
--   * a void invoice chased -- killed by "an invoice already paid is
--     left alone", not by "and so is one that was cancelled" as it
--     first looked: widening the status test lets a *paid* invoice
--     through too, and that block runs first;
--   * the same day chased twice -- "chasing the same day twice sends
--     one mail";
--   * two different days sharing a dedupe key -- "but the second
--     reminder is its own mail";
--   * the daily pass not calling it -- "the daily pass chases them";
--   * nothing sent when a payment lands -- "a company that pays
--     through the gateway is told the money arrived". The assertion
--     had to go through `settle_gateway_payment` to bite: a first
--     version reached the queue directly, and the mutant that took the
--     call out of the callback survived it untouched;
--   * nothing sent when an administrator settles one by hand -- "and
--     so is one settled by hand";
--   * a failed or underpaid callback thanked anyway -- "an underpaid
--     bill is not a paid one".
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- Who gets told
-- ---------------------------------------------------------------------
create or replace function app.platform_billing_email(p_org_id uuid)
returns text
language sql stable
set search_path = public, app, pg_temp as $$
  -- The company's own address first, then whoever made the company.
  -- Ordered rather than "any owner": a company with three owners must
  -- reach the same one every time, or a dedupe key is the only thing
  -- standing between it and three copies.
  select coalesce(
    (select nullif(btrim(o.email), '')
       from public.organizations o where o.id = p_org_id),
    (select u.email::text
       from public.org_members m
       join auth.users u on u.id = m.user_id
      where m.org_id = p_org_id
        and m.role = 'owner' and m.status = 'active'
      order by m.joined_at nulls last, u.email
      limit 1));
$$;

comment on function app.platform_billing_email(uuid) is
  'Where to write to a company about what it owes the platform: its '
  'own address, else the earliest active owner''s login. See 0491.';

revoke all on function app.platform_billing_email(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The wording
-- ---------------------------------------------------------------------
-- Restated from the built definition. The five above are 0068's,
-- 0083's and 0490's, unchanged.
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
    ('platform_invoice',
     '{{invoice_no}} — {{period}} for {{company_name}}',
     E'Dear {{company_name}},\n\nYour iAkauntan invoice {{invoice_no}} is ready, for {{currency}} {{total_amount}}.\n\n{{description}}\n\nYou can see it and pay it under Settings, on the Your subscription card.\n\nRegards,\n{{issuer_name}}'),
    -- 0491. The chase. It says how long it has been rather than "this
    -- is overdue", because there is no due date on a platform invoice
    -- to be past -- and the last line is the one that matters, since
    -- most of these will be crossovers rather than debts.
    ('platform_invoice_reminder',
     'Still outstanding: {{invoice_no}}',
     E'Dear {{company_name}},\n\nOur records show {{currency}} {{total_amount}} still outstanding on invoice {{invoice_no}}, issued {{days}} days ago on {{issue_date}}.\n\n{{description}}\n\nYou can settle it under Settings, on the Your subscription card.\n\nIf you have already paid, please ignore this message and accept our apologies for the crossover.\n\nRegards,\n{{issuer_name}}'),
    -- And the thank-you. Short on purpose: what somebody needs from it
    -- is confirmation that the money landed against the right bill.
    ('platform_payment_received',
     'Payment received — thank you',
     E'Dear {{company_name}},\n\nThank you. We have received {{currency}} {{total_amount}} against invoice {{invoice_no}}.\n\nRegards,\n{{issuer_name}}')
  ) as t (code, subject, body)
  where t.code = p_code;
$$;

-- ---------------------------------------------------------------------
-- What every one of these messages says
-- ---------------------------------------------------------------------
create or replace function app.platform_invoice_vars(
  p_inv public.platform_invoices, p_days integer default null)
returns jsonb
language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select jsonb_build_object(
    'company_name', p_inv.bill_to_name,
    'issuer_name',  p_inv.issuer_name,
    'invoice_no',   p_inv.invoice_no,
    'currency',     p_inv.currency,
    'total_amount', to_char(p_inv.total_amount, 'FM999G999G990D00'),
    'description',  p_inv.description,
    'issue_date',   to_char(p_inv.issue_date, 'FMDD Month YYYY'),
    'days',         coalesce(p_days::text, ''),
    -- The first line of the description is "Modules for January 2026";
    -- the rest is 0489's per-module breakdown after a newline.
    'period',       split_part(p_inv.description, chr(10), 1));
$$;

revoke all on function app.platform_invoice_vars(public.platform_invoices, integer)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- One message about one invoice
-- ---------------------------------------------------------------------
-- The single insert the three senders below share. `p_key` is what
-- makes each of them send once: the invoice number for the bill, the
-- invoice number and the day for a chase, the invoice number again for
-- the thank-you.
create or replace function app.queue_platform_mail(
  p_invoice_id uuid, p_code text, p_key text, p_days integer default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_inv  public.platform_invoices;
  v_to   text;
  t      record;
  v_vars jsonb;
  v_id   uuid;
begin
  select * into v_inv from public.platform_invoices where id = p_invoice_id;
  if not found then
    return null;
  end if;

  v_to := app.platform_billing_email(v_inv.org_id);
  if v_to is null then
    return null;
  end if;

  -- `default_email_template` and not `app.email_template`, which
  -- layers the tenant's own overrides on top. What a company is told it
  -- owes is not its own wording to edit; the tenant templates are for
  -- the mail it sends its customers.
  select * into t from app.default_email_template(p_code);
  if t.subject is null then
    return null;
  end if;
  v_vars := app.platform_invoice_vars(v_inv, p_days);

  begin
    insert into public.email_outbox
      (org_id, to_email, subject, body, from_name, template_code, dedupe_key)
    values (
      v_inv.org_id, v_to,
      app.render_email(t.subject, v_vars),
      app.render_email(t.body, v_vars),
      v_inv.issuer_name, p_code, p_key)
    returning id into v_id;
  exception when unique_violation then
    -- Already queued under this key. Nothing to do and nothing wrong.
    return null;
  end;

  return v_id;
end $$;

revoke all on function app.queue_platform_mail(uuid, text, text, integer)
  from public, anon, authenticated;

-- Restated on top of the shared pieces above. Same key, same wording,
-- same recipient rule -- 0490 wrote all three of them inline, and this
-- is the same function with the duplication taken out.
create or replace function app.queue_platform_invoice_email(p_invoice_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_no text;
begin
  select invoice_no into v_no
    from public.platform_invoices where id = p_invoice_id;
  if v_no is null then
    return null;
  end if;
  return app.queue_platform_mail(
    p_invoice_id, 'platform_invoice', 'platform-invoice:' || v_no);
end $$;

revoke all on function app.queue_platform_invoice_email(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The thank-you
-- ---------------------------------------------------------------------
create or replace function app.queue_platform_payment_received(
  p_invoice_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_no text;
begin
  select invoice_no into v_no
    from public.platform_invoices
   where id = p_invoice_id and status = 'paid';
  if v_no is null then
    return null;
  end if;
  return app.queue_platform_mail(
    p_invoice_id, 'platform_payment_received', 'platform-paid:' || v_no);
end $$;

comment on function app.queue_platform_payment_received(uuid) is
  'Tells a company its subscription payment arrived. Once per invoice, '
  'and only for one actually marked paid. See 0491.';

revoke all on function app.queue_platform_payment_received(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The chase
-- ---------------------------------------------------------------------
create or replace function app.chase_platform_invoices(
  p_on date default current_date)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_days  integer[];
  v_issuer jsonb;
  r       record;
  v_n     integer := 0;
begin
  select value into v_issuer from public.platform_settings
   where key = 'platform_issuer';
  select coalesce(
    array(select jsonb_array_elements_text(
                   coalesce(v_issuer, '{}'::jsonb) -> 'reminder_days')::integer),
    array[]::integer[])
    into v_days;
  if array_length(v_days, 1) is null then
    v_days := array[7, 14, 30];
  end if;

  for r in
    select i.id, (p_on - i.issue_date) as age
      from public.platform_invoices i
      join public.organizations o on o.id = i.org_id
     where i.status = 'issued'
       and not o.is_demo
       and coalesce(o.status, 'active') = 'active'
       and (p_on - i.issue_date) = any (v_days)
  loop
    -- The day is in the key, so the 7th and the 14th are two mails and
    -- a scheduler that runs twice on the 7th is one.
    if app.queue_platform_mail(
         r.id, 'platform_invoice_reminder',
         'platform-reminder:' || r.id::text || ':' || r.age::text,
         r.age) is not null then
      v_n := v_n + 1;
    end if;
  end loop;

  return v_n;
end $$;

comment on function app.chase_platform_invoices(date) is
  'Reminds a company about a platform invoice still unpaid, on the '
  'days named by platform_issuer -> reminder_days (7, 14 and 30 if it '
  'names none). See 0491.';

revoke all on function app.chase_platform_invoices(date)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The three callers
-- ---------------------------------------------------------------------
-- All three restated from the built definitions rather than from the
-- migrations that last wrote them. `run_daily_jobs` alone has been
-- rewritten by 0252, 0308, 0360, 0365, 0375, 0392 and 0489, and
-- rebuilding it from any one of those would silently drop the rest --
-- which 0485 did, and cost a CI run to find.

create or replace function app.run_daily_jobs(p_on date default current_date)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$

declare o record;
begin
  perform app.run_recurring_journals(p_on);
  perform app.run_recurring_documents(p_on);
  perform app.queue_overdue_reminders(p_on);

  begin
    perform public.chat_expire_calls();
  exception when others then
    raise warning 'chat_expire_calls failed: %', sqlerrm;
  end;

  begin
    perform public.prune_device_tokens();
  exception when others then
    raise warning 'prune_device_tokens failed: %', sqlerrm;
  end;

  begin
    perform app.queue_sales_digest(p_on - 1);
  exception when others then
    raise warning 'queue_sales_digest failed: %', sqlerrm;
  end;

  begin
    perform app.sweep_idempotency_keys(now() - interval '24 hours');
  exception when others then
    raise warning 'sweep_idempotency_keys failed: %', sqlerrm;
  end;

  for o in select id from public.organizations
            where coalesce(status, 'active') = 'active'
  loop
    begin
      if app.has_module(o.id, 'hr') then
        perform app.close_attendance_day(o.id, p_on - 1);
        perform app.expire_carried_leave(o.id, p_on);
      end if;
    exception when others then
      raise warning 'HR daily pass failed for %: %', o.id, sqlerrm;
    end;

    -- 0375. Wrapped like the rest: a shop whose till sweep fails must
    -- not stop the leave year and the consolidation for everybody else.
    begin
      if app.has_module(o.id, 'pos') then
        perform app.expire_parked_sales(o.id);
      end if;
    exception when others then
      raise warning 'expire_parked_sales failed for %: %', o.id, sqlerrm;
    end;

    -- The two that run on the first of the month, wrapped at last.
    -- `0375`'s comment above the till sweep names exactly these two as
    -- the things a failure elsewhere must not stop, and they were the
    -- two left bare — so the isolation went to the branches that run
    -- daily and not to the branches that run once a month, which is the
    -- wrong way round. A fault in a daily branch is found the next
    -- morning; a fault in a January branch is found in a year.
    begin
      if extract(month from p_on) = 1 and extract(day from p_on) = 1 then
        perform app.roll_leave_year(o.id, extract(year from p_on)::integer);
      end if;
    exception when others then
      raise warning 'roll_leave_year failed for %: %', o.id, sqlerrm;
    end;

    begin
      if extract(day from p_on) = 1 and app.has_module(o.id, 'einvoice') then
        perform app.roll_einvoice_consolidation(
          o.id, (p_on - interval '1 month')::date);
      end if;
    exception when others then
      raise warning 'roll_einvoice_consolidation failed for %: %',
        o.id, sqlerrm;
    end;
  end loop;

  -- 0489. On the first, the month that just ended is billed. Outside
  -- the loop above because `bill_the_month` walks the companies itself,
  -- and wrapped like everything else here: a company whose invoice
  -- cannot be written must not stop the ones after it, and must not
  -- take the daily pass down with it either.
  begin
    if extract(day from p_on) = 1 then
      perform app.bill_the_month(p_on);
    end if;
  exception when others then
    raise warning 'bill_the_month failed: %', sqlerrm;
  end;

  -- 0491. Every day, not just the first: a bill raised on the 1st is
  -- chased on the 8th, the 15th and the 31st, and none of those is a
  -- first of the month.
  begin
    perform app.chase_platform_invoices(p_on);
  exception when others then
    raise warning 'chase_platform_invoices failed: %', sqlerrm;
  end;
end; $$;

revoke all on function app.run_daily_jobs(date) from public, anon, authenticated;

create or replace function public.settle_gateway_payment(
  p_gateway text, p_provider_ref text, p_paid boolean,
  p_paid_amount numeric, p_payload jsonb default null)
returns text
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_pay public.platform_payments;
  v_inv public.platform_invoices;
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb) - 'x_signature';
begin
  select * into v_pay from public.platform_payments
   where gateway_code = lower(btrim(coalesce(p_gateway, '')))
     and provider_ref = btrim(coalesce(p_provider_ref, ''));

  -- A confirmation for a bill this platform never created. Nothing to
  -- do, and nothing to raise about: saying "unknown" out loud to a
  -- caller who guessed a reference tells them whether their guess was
  -- right.
  if v_pay.id is null then
    return 'unknown';
  end if;

  -- Already settled. Billplz retries, and a retry is not a payment.
  if v_pay.state = 'paid' then
    return 'already_paid';
  end if;

  if not coalesce(p_paid, false) then
    update public.platform_payments
       set state = 'failed', provider_payload = v_payload
     where id = v_pay.id;
    return 'not_paid';
  end if;

  -- The assertion this function exists for. What was handed over has to
  -- cover what was owed; a confirmation for less is recorded and
  -- refused rather than rounded up into a paid invoice.
  if coalesce(p_paid_amount, 0) < v_pay.amount then
    update public.platform_payments
       set state = 'underpaid', paid_amount = coalesce(p_paid_amount, 0),
           provider_payload = v_payload
     where id = v_pay.id;
    return 'underpaid';
  end if;

  update public.platform_payments
     set state = 'paid', paid_amount = p_paid_amount, paid_at = now(),
         provider_payload = v_payload
   where id = v_pay.id;

  -- From `issued` and from nowhere else: a void invoice does not come
  -- back to life because a stale callback arrived.
  update public.platform_invoices i
     set status = 'paid', paid_at = now(),
         paid_note = 'Paid through ' || v_pay.gateway_code
                     || ' (' || v_pay.provider_ref || ')'
   where i.id = v_pay.invoice_id and i.status = 'issued'
  returning * into v_inv;

  if v_inv.id is null then
    -- The money arrived against an invoice that is no longer
    -- outstanding. The payment is real and is recorded as such; the
    -- invoice is somebody's problem to refund, and saying so here is
    -- how they find out.
    return 'paid_but_invoice_not_issued';
  end if;

  -- 0491. The money landed; say so. Wrapped, like every other mail
  -- this codebase queues from inside something that matters: a
  -- confirmation Billplz has already accepted must not be rolled back
  -- because the outbox refused, and a callback that raises is a
  -- callback Billplz retries.
  begin
    perform app.queue_platform_payment_received(v_inv.id);
  exception when others then
    raise warning 'queue_platform_payment_received failed for %: %',
      v_inv.id, sqlerrm;
  end;

  return 'paid';
end;
$$;

revoke all on function public.settle_gateway_payment(
  text, text, boolean, numeric, jsonb) from public, anon, authenticated;

create or replace function public.platform_mark_invoice_paid(
  p_invoice_id uuid, p_note text default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrator access required'
      using errcode = '42501';
  end if;
  update public.platform_invoices
     set status = 'paid', paid_at = now(), paid_note = p_note
   where id = p_invoice_id and status = 'issued';

  -- 0491. A transfer somebody reconciled by hand is still a payment,
  -- and the company that made it has no other way of learning it
  -- landed. `queue_platform_payment_received` sends nothing for an
  -- invoice that was not actually moved to paid, so the guard on the
  -- update above is the guard on the mail.
  begin
    perform app.queue_platform_payment_received(p_invoice_id);
  exception when others then
    raise warning 'queue_platform_payment_received failed for %: %',
      p_invoice_id, sqlerrm;
  end;
end;
$$;

revoke all on function public.platform_mark_invoice_paid(uuid, text)
  from public, anon;
grant execute on function public.platform_mark_invoice_paid(uuid, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
declare v_def text;
begin
  -- The wording. Seven now, and the five that were already there must
  -- all have survived the restatement.
  if (select count(*) from (
        select app.default_email_template(c) from (values
          ('document_new'), ('invoice_reminder'), ('payment_received'),
          ('receipt_issued'), ('platform_invoice'),
          ('platform_invoice_reminder'),
          ('platform_payment_received')) v(c)) s) <> 7 then
    raise exception '0491: a template is missing';
  end if;

  v_def := pg_get_functiondef('app.run_daily_jobs(date)'::regprocedure);
  if position('chase_platform_invoices' in v_def) = 0 then
    raise exception '0491: nothing chases an unpaid invoice';
  end if;
  -- One step from each migration that has ever written this function.
  -- The restatement is the whole of it, so anything dropped is silent.
  if position('bill_the_month' in v_def) = 0
     or position('roll_einvoice_consolidation' in v_def) = 0
     or position('sweep_idempotency_keys' in v_def) = 0
     or position('expire_parked_sales' in v_def) = 0
     or position('close_attendance_day' in v_def) = 0
     or position('queue_sales_digest' in v_def) = 0 then
    raise exception '0491: the daily pass lost a step it already had';
  end if;

  v_def := pg_get_functiondef(
    'public.settle_gateway_payment(text, text, boolean, numeric, jsonb)'
      ::regprocedure);
  if position('queue_platform_payment_received' in v_def) = 0 then
    raise exception '0491: a payment still arrives in silence';
  end if;
  -- 0297's rules, which this restatement must not have lost.
  if position('underpaid' in v_def) = 0
     or position('already_paid' in v_def) = 0 then
    raise exception '0491: the settlement rules 0297 set were dropped';
  end if;

  if position('queue_platform_payment_received' in pg_get_functiondef(
       'public.platform_mark_invoice_paid(uuid, text)'::regprocedure)) = 0 then
    raise exception '0491: settling one by hand still says nothing';
  end if;

  if has_function_privilege('authenticated',
       'app.chase_platform_invoices(date)', 'execute')
     or has_function_privilege('authenticated',
       'app.queue_platform_mail(uuid, text, text, integer)', 'execute') then
    raise exception '0491: a tenant can send platform mail';
  end if;
end $do$;
