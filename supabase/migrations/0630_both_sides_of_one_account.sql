-- =====================================================================
-- iAkauntan :: 0630 both sides of one account
--
-- `0629` opened the door: a credit note can be set against an invoice.
-- Nothing reaches it, because a knock-off screen needs a question
-- nothing in this database answers -- *what does this customer owe, and
-- what have they got in hand to set against it* -- and it needs to
-- apply several of them at once.
--
-- ---------------------------------------------------------------------
-- Two sources, not five
--
-- `payment_allocations` takes seven kinds of source. This deals with
-- two:
--
--   * a **credit note** with value left on it, and
--   * a **receipt** with money still on account.
--
-- Both are settled by matching alone: the credit note credited the
-- receivable when it was raised, the receipt credited it when it was
-- banked, and neither needs a journal to be put against an invoice.
-- That is what makes a batch of them safe to apply in one statement.
--
-- Deposits, post-dated cheques, withholding certificates and contras
-- are deliberately left out. Each of them POSTS something when it is
-- applied -- `apply_deposit`, `record_pdc`, `post_withholding`,
-- `create_contra` -- and each already has a screen that knows what. A
-- knock-off screen that silently posted four different journals
-- depending on which row somebody ticked would be the most dangerous
-- screen in the product. They are still SHOWN, marked as settled
-- elsewhere, because a clerk looking at what a customer has in hand
-- needs to see all of it.
--
-- ---------------------------------------------------------------------
-- One statement, all or nothing
--
-- `knock_off` applies every line or none. A clerk matching six credits
-- against nine invoices at month end is making one decision; a loop in
-- the client that fails on the seventh leaves a set of books in a state
-- nobody chose and no record of what was intended.
-- =====================================================================

create or replace function public.open_items(p_contact_id uuid)
returns table (
  side        text,
  kind        text,
  item_id     uuid,
  doc_no      text,
  item_date   date,
  due_date    date,
  currency    text,
  total       numeric,
  remaining   numeric,
  allocatable boolean)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  with me as (select c.* from public.contacts c where c.id = p_contact_id),
  -- 0477 links a company's records through `party_id`, so a customer
  -- filed twice is one account here. The portal draws the same circle
  -- for the same reason: a clerk knocking off against "the other
  -- record" is the mistake this is meant to prevent.
  family as (
    select c2.id from public.contacts c2, me
     where c2.org_id = me.org_id
       and (c2.id = me.id
            or (me.party_id is not null and c2.party_id = me.party_id))
  )
  select 'owes'::text, d.doc_type::text, d.id, d.doc_no, d.doc_date,
         d.due_date, d.currency::text, d.total_amount, d.balance_amount,
         true
    from public.sales_documents d, me
   where d.org_id = me.org_id
     and app.is_org_member(me.org_id)
     and d.contact_id in (select id from family)
     and d.doc_type in ('invoice', 'debit_note')
     and d.gl_entry_id is not null
     and d.status <> 'void'
     and d.deleted_at is null
     and round(coalesce(d.balance_amount, 0), 2) > 0
  union all
  -- 0629 made this one real. `balance_amount` is what is left on it.
  select 'credit', 'credit_note', d.id, d.doc_no, d.doc_date, null,
         d.currency::text, d.total_amount, d.balance_amount, true
    from public.sales_documents d, me
   where d.org_id = me.org_id
     and app.is_org_member(me.org_id)
     and d.contact_id in (select id from family)
     and d.doc_type = 'credit_note'
     and d.gl_entry_id is not null
     and d.status <> 'void'
     and d.deleted_at is null
     and round(coalesce(d.balance_amount, 0), 2) > 0
  union all
  select 'credit', 'receipt', r.id, r.receipt_no, r.receipt_date, null,
         r.currency::text, r.amount, r.unapplied_amount, true
    from public.receipts r, me
   where r.org_id = me.org_id
     and app.is_org_member(me.org_id)
     and r.contact_id in (select id from family)
     and r.gl_entry_id is not null
     and round(coalesce(r.unapplied_amount, 0), 2) > 0
  union all
  -- Shown and NOT allocatable: applying one posts a journal, and
  -- `deposit_apply_sheet.dart` is where that decision is made. Left off
  -- this list entirely, a clerk would knock off what they could see and
  -- believe the account was clear.
  select 'credit', 'deposit', n.id, n.deposit_no, n.deposit_date, null,
         n.currency::text, n.amount, n.balance_amount, false
    from public.deposit_notes n, me
   where n.org_id = me.org_id
     and app.is_org_member(me.org_id)
     and n.contact_id in (select id from family)
     and n.status not in ('void', 'settled')
     and round(coalesce(n.balance_amount, 0), 2) > 0
   order by 1 desc, 5, 4;
$$;

comment on function public.open_items(uuid) is
  'What one contact owes and what they have in hand to set against it. '
  '`allocatable` is false for the kinds whose application posts a '
  'journal and belongs on their own screen. See 0630.';

revoke all on function public.open_items(uuid) from public, anon;
grant execute on function public.open_items(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Applying a batch of them
-- ---------------------------------------------------------------------
create or replace function public.knock_off(
  p_contact_id uuid,
  p_lines      jsonb)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  me      public.contacts;
  v_line  jsonb;
  v_kind  text;
  v_src   uuid;
  v_inv   uuid;
  v_amt   numeric;
  v_done  integer := 0;
begin
  select * into me from public.contacts where id = p_contact_id;
  if me.id is null then
    raise exception 'No such contact.' using errcode = 'P0002';
  end if;
  if not app.can_post(me.org_id) then
    raise exception 'not permitted to knock off' using errcode = '42501';
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Nothing to set against anything.'
      using errcode = '23514';
  end if;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_kind := v_line ->> 'kind';
    v_src  := (v_line ->> 'source_id')::uuid;
    v_inv  := (v_line ->> 'invoice_id')::uuid;
    v_amt  := round((v_line ->> 'amount')::numeric, 2);

    -- Every line goes through the function that already knows the rules
    -- for its kind, rather than inserting allocations here. A second
    -- writer is a second set of guards to keep in step, and `0629`'s
    -- whole finding was that a column with no writer grows
    -- infrastructure that nobody ever tests.
    case v_kind
      when 'credit_note' then
        perform public.allocate_credit_note(v_src, v_inv, v_amt);
      when 'receipt' then
        perform public.allocate_with_discount(v_src, v_inv, v_amt, 0);
      else
        raise exception
          'A % cannot be knocked off here. Credit notes and money on '
          'account are settled by matching; anything else posts a '
          'journal and is applied from its own screen.',
          coalesce(v_kind, 'nothing') using errcode = '22023';
    end case;
    v_done := v_done + 1;
  end loop;

  return v_done;
end $$;

comment on function public.knock_off(uuid, jsonb) is
  'Sets several credit notes and on-account receipts against several '
  'invoices, all or none. Each line goes through the allocator for its '
  'own kind. See 0630.';

revoke all on function public.knock_off(uuid, jsonb) from public, anon;
grant execute on function public.knock_off(uuid, jsonb)
  to authenticated, service_role;
