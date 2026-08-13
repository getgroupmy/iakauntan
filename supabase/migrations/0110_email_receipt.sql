-- =====================================================================
-- iAkauntan :: 0110 send the customer their receipt
--
-- The outbox has always been able to carry a document. It could not
-- carry a receipt, because `email_document` resolves `sales_documents`
-- and a receipt is not one — so the acknowledgement that money arrived,
-- which is the message a customer most reliably wants, was the one
-- thing that could not be sent.
--
-- ---------------------------------------------------------------------
-- Attached, not linked
--
-- Every other message here carries a share link, and the link is the
-- better thing to send: it is always the current document and it reports
-- back when somebody opens it.
--
-- A receipt is the exception, and the reason is what a receipt is for.
-- It is evidence of a completed fact, filed by the person who receives
-- it and produced years later. There is nothing to keep current — a
-- receipt that changed after it was issued would be a problem, not a
-- feature — and no shared receipt page exists for a link to point at.
--
-- So this attaches by default and issues no token. The attachment is
-- still optional, because a message saying "we have your money" is worth
-- sending even when the PDF cannot be produced.
-- =====================================================================

alter table public.email_outbox
  add column if not exists receipt_id uuid
    references public.receipts (id) on delete set null;

create index if not exists email_outbox_receipt
  on public.email_outbox (receipt_id) where receipt_id is not null;

-- ---------------------------------------------------------------------
-- What a receipt template can say
--
-- `applied_to` is a joined list rather than a loop, because the template
-- language has no loops and should not get any: one somebody has to
-- debug at three in the afternoon with a customer waiting is worse than
-- a sentence that occasionally reads oddly.
--
-- `unapplied_amount` is here because it is the one figure a customer
-- might dispute. Money on account is money they have paid and cannot yet
-- see against anything, and a receipt that stays silent about it invites
-- the phone call.
-- ---------------------------------------------------------------------
create or replace function app.receipt_email_vars(p_receipt_id uuid)
returns jsonb
language sql stable
set search_path = public, app, pg_temp as $$
  select jsonb_build_object(
    'company_name', coalesce(o.legal_name, o.name),
    'contact_name', coalesce(c.name, 'Sir or Madam'),
    'receipt_no', r.receipt_no,
    'receipt_date', to_char(r.receipt_date, 'DD Mon YYYY'),
    'currency', r.currency,
    'amount', to_char(r.amount, 'FM999,999,999,990.00'),
    'unapplied_amount', to_char(r.unapplied_amount, 'FM999,999,999,990.00'),
    'payment_mode', coalesce(r.payment_mode_code, ''),
    'reference', coalesce(r.reference, ''),
    'applied_to', coalesce((
      select string_agg(sd.doc_no, ', ' order by sd.doc_no)
        from public.payment_allocations pa
        join public.sales_documents sd on sd.id = pa.invoice_id
       where pa.receipt_id = r.id), ''))
    from public.receipts r
    join public.organizations o on o.id = r.org_id
    left join public.contacts c on c.id = r.contact_id
   where r.id = p_receipt_id;
$$;

-- ---------------------------------------------------------------------
-- The default wording
--
-- `payment_received` already existed and is document-shaped — it names
-- an invoice and the amount paid against it, which is the right message
-- when one invoice is settled and the wrong one for a payment covering
-- four. This is the receipt's own.
-- ---------------------------------------------------------------------
create or replace function app.default_email_template(p_code text)
returns table (subject text, body text)
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
     E'Dear {{contact_name}},\n\nThank you. We have received {{currency}} {{amount}} on {{receipt_date}}, and your receipt {{receipt_no}} is attached.\n\nThis has been set against {{applied_to}}.\n\nRegards,\n{{company_name}}')
  ) as t (code, subject, body)
  where t.code = p_code;
$$;

-- ---------------------------------------------------------------------
-- Queueing it
--
-- Same shape as `email_document`, and the same guards: an administrator
-- or writer of this organization, an address that looks like one, and an
-- attachment path pinned to this organization and this receipt.
--
-- No share token. See the header — there is nothing for a link to point
-- at, and issuing one would revoke the invoice's live link as a side
-- effect, which is the sort of thing that is discovered by a customer.
-- ---------------------------------------------------------------------
create or replace function public.email_receipt(
  p_receipt_id uuid,
  p_to text default null,
  p_template_code text default 'receipt_issued',
  p_dispatch text default 'queued',
  p_attachment_path text default null,
  p_attachment_name text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  r public.receipts;
  o public.organizations;
  c public.contacts;
  s public.email_settings;
  t record;
  v_to text;
  v_vars jsonb;
  v_id uuid;
  v_path text := nullif(btrim(coalesce(p_attachment_path, '')), '');
begin
  if p_dispatch not in ('queued', 'immediate') then
    raise exception 'Dispatch must be queued or immediate, not %', p_dispatch
      using errcode = '23514';
  end if;

  select * into r from public.receipts where id = p_receipt_id;
  if r.id is null or r.deleted_at is not null then
    raise exception 'Receipt not found' using errcode = 'P0002';
  end if;
  if not app.can_write(r.org_id) then
    raise exception 'Not permitted to send this receipt'
      using errcode = '42501';
  end if;

  if v_path is not null then
    if split_part(v_path, '/', 1) <> r.org_id::text
       or split_part(v_path, '/', 2) <> 'receipts'
       or split_part(v_path, '/', 3) <> p_receipt_id::text
       or split_part(v_path, '/', 4) = '' then
      raise exception 'An attachment must live under %/receipts/%/',
        r.org_id, p_receipt_id using errcode = '42501';
    end if;
  end if;

  select * into o from public.organizations where id = r.org_id;
  select * into c from public.contacts where id = r.contact_id;
  select * into s from public.email_settings where org_id = r.org_id;

  if not coalesce(s.is_enabled, false) then
    raise exception 'Email is switched off for this organization'
      using errcode = '22023';
  end if;

  v_to := coalesce(
    nullif(btrim(p_to), ''),
    (select cp.email::text from public.contact_persons cp
      where cp.contact_id = r.contact_id and cp.is_primary limit 1),
    c.email::text);

  if v_to is null then
    raise exception 'No address to send to; add one to the customer'
      using errcode = '23514';
  end if;

  if v_to !~ '^[^@[:space:],]+@[^@[:space:],]+\.[^@[:space:],]{2,}$' then
    raise exception '% does not look like an email address', v_to
      using errcode = '23514';
  end if;

  select * into t from app.email_template(r.org_id, p_template_code);
  if t.subject is null then
    raise exception 'No template called %', p_template_code using errcode = 'P0002';
  end if;

  v_vars := app.receipt_email_vars(r.id);

  insert into public.email_outbox
    (org_id, to_email, subject, body, reply_to, from_name,
     template_code, receipt_id, dispatch,
     attachment_path, attachment_name, created_by)
  values (
    r.org_id, v_to,
    app.render_email(t.subject, v_vars),
    app.render_email(t.body, v_vars),
    s.reply_to, coalesce(s.from_name, o.name),
    p_template_code, r.id, p_dispatch,
    v_path,
    case when v_path is null then null
         else coalesce(nullif(btrim(p_attachment_name), ''),
                       split_part(v_path, '/', 4))
    end,
    auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function app.receipt_email_vars(uuid) from public, anon;

revoke all on function public.email_receipt(
  uuid, text, text, text, text, text) from public, anon;
grant execute on function public.email_receipt(
  uuid, text, text, text, text, text) to authenticated;
