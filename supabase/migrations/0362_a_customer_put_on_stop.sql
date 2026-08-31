-- =====================================================================
-- iAkauntan :: 0362 a customer put on stop
--
-- `contacts.credit_hold` has been a column since `0003` and no SQL has
-- ever read it and no screen has ever set it. `0086` built credit
-- control properly — a per-customer limit, an organization-level choice
-- between warning and blocking, and a guard that fires on the
-- transition into posted and only for the document types that increase
-- what somebody owes — and the hold sat next to all of it doing
-- nothing.
--
-- A hold is not a small limit. A limit is a rule of thumb about how much
-- exposure is acceptable; a hold is somebody deciding that this customer
-- gets nothing further until a specific thing happens. They fail
-- differently too: exceeding a limit is arithmetic nobody chose, and a
-- hold is a person's instruction.
--
-- ---------------------------------------------------------------------
-- Which is why it blocks in `warn` mode as well
--
-- `credit_control = 'warn'` is a company saying it does not want the
-- arithmetic to refuse postings on its behalf. It is not a company
-- saying it does not mean the thing it ticked. A hold that only applied
-- in `block` mode would be a checkbox whose effect depends on a setting
-- three screens away, and the person who ticked it would have no way to
-- know which they had.
--
-- The asymmetry is deliberate and worth the sentence: the limit obeys
-- the mode, the hold overrides it, because one is a threshold and the
-- other is an instruction.
--
-- ---------------------------------------------------------------------
-- And credits still go through
--
-- `0086`'s reasoning, unchanged: "refusing to credit somebody because
-- they are over their limit is exactly backwards". A customer on stop is
-- exactly the customer most likely to need a credit note, and blocking
-- one would leave the balance that caused the hold uncorrectable.
-- =====================================================================

create or replace function app.enforce_credit_limit()
returns trigger
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_control     text;
  v_limit       numeric(18, 2);
  v_hold        boolean;
  v_outstanding numeric(18, 2);
  v_name        text;
begin
  if new.gl_entry_id is null or old.gl_entry_id is not null then
    return new;
  end if;
  if new.doc_type not in ('invoice', 'debit_note') then
    return new;
  end if;

  select coalesce(c.credit_limit, 0), coalesce(c.credit_hold, false), c.name
    into v_limit, v_hold, v_name
    from public.contacts c where c.id = new.contact_id;

  -- The hold, first and regardless of the mode. Somebody ticked this
  -- against this customer; the mode is about whether arithmetic may
  -- refuse on the company's behalf, not about whether the company means
  -- what it said.
  if v_hold then
    raise exception
      '% is on credit hold, so % cannot be posted. Take the hold off, '
      'or raise this as a cash sale.',
      v_name, new.doc_no
      using errcode = '23514';
  end if;

  select credit_control into v_control
    from public.organizations where id = new.org_id;
  if coalesce(v_control, 'warn') <> 'block' then
    return new;
  end if;

  if coalesce(v_limit, 0) <= 0 then
    return new;
  end if;

  select coalesce(sum(d.balance_amount * coalesce(d.exchange_rate, 1)), 0)
    into v_outstanding
    from public.sales_documents d
   where d.org_id = new.org_id and d.contact_id = new.contact_id
     and d.gl_entry_id is not null and d.status <> 'void'
     and d.deleted_at is null and d.id <> new.id;

  v_outstanding := v_outstanding
                 + new.balance_amount * coalesce(new.exchange_rate, 1);

  if v_outstanding > v_limit then
    raise exception
      'Posting % would take % to % against a credit limit of %. '
      'Raise the limit, take a payment, or set credit control to warn.',
      new.doc_no, v_name, round(v_outstanding, 2), round(v_limit, 2)
      using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke all on function app.enforce_credit_limit() from public, anon, authenticated;

comment on column public.contacts.credit_hold is
  'No further credit until somebody takes it off. Refuses an invoice or '
  'a debit note whatever the organization''s credit_control mode says, '
  'because it is an instruction rather than a threshold; credit notes '
  'and refunds still post, since the customer on stop is the one most '
  'likely to need one.';
