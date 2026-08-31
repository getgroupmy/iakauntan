-- =====================================================================
-- iAkauntan :: 0376 a supplier credit attached to the bill
--
-- `purchase_documents.original_bill_id` has been a column since `0006`,
-- declared beside `parent_id` with the same intent as
-- `sales_documents.original_invoice_id` — "for credit/debit notes: the
-- document being adjusted". Nothing has ever written it.
--
-- `0269` found and closed exactly this hole on the sales side, and said
-- why it was worse than a missing feature: a credit note that names no
-- invoice cannot be capped at what was invoiced and cannot be reported
-- against the sale it reverses. Everything in that paragraph is true one
-- table over, with the signs reversed and the money going the other way.
--
-- It became live rather than theoretical when `0160` gave
-- `purchase_credit_note` and `purchase_debit_note` rows in `docTypes`.
-- Before that a supplier credit could not be raised at all; now it can,
-- and it lands as a document typed by hand that names no bill.
--
-- ---------------------------------------------------------------------
-- What the link is worth on this side
--
-- Three things, and the third is statutory.
--
-- A cap. Crediting more than was billed is not a return, it is a claim
-- against a supplier for goods they never sent. Refused, in the same
-- words `0269` uses, because it is the same mistake.
--
-- A pair. `0096` ages a purchase credit note alongside the bills; with
-- no link, matching one to the bill it belongs to is somebody reading
-- two lists side by side. With it, what is left owing on a bill is
-- arithmetic.
--
-- And the input tax. `report_sst_summary` counts a purchase credit
-- note's tax as a reduction of input tax claimed. Which bill's input
-- tax is not a detail: a return of goods bought under one tax code
-- adjusts that claim and not another, and an assessment asks the
-- question bill by bill.
--
-- ---------------------------------------------------------------------
-- What it deliberately does not do
--
-- It does not put stock back. On the sales side `0269` had to return
-- ingredients, because selling took them out. Here the goods are going
-- *out* of our store back to the supplier, and `0097`'s posting path
-- already moves stock for a purchase credit note the same way it does
-- for any purchase document — the quantity is what it moves, and the
-- quantity is what this function writes. Adding a second movement here
-- would take the goods out twice.
--
-- And it does not touch a debit note. A supplier's debit note is the
-- supplier's document — an undercharge they are now billing for — and
-- the party who decides what it says is not us. It gets the column when
-- somebody records one against a bill by hand; this builds the half
-- that is ours to build.
-- =====================================================================

-- ---------------------------------------------------------------------
-- What is left uncredited on a bill
--
-- Matched on item and description together, exactly as
-- `invoice_credit_remaining` does. Two lines for the same item at
-- different descriptions — "cement, 50 bags" and "cement, damaged" — are
-- two different things to credit, and collapsing them would let a credit
-- against one exhaust the other.
-- ---------------------------------------------------------------------
create or replace function public.bill_credit_remaining(p_bill uuid)
returns table (
  line_id     uuid,
  line_no     integer,
  item_id     uuid,
  description text,
  uom_code    text,
  unit_price  numeric,
  billed      numeric,
  credited    numeric,
  remaining   numeric)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  select d.org_id into v_org from public.purchase_documents d
   where d.id = p_bill and d.doc_type = 'bill';
  if v_org is null then
    raise exception 'No such bill.' using errcode = 'P0002';
  end if;
  if not app.is_org_member(v_org) then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;

  return query
  with credited as (
    select cl.item_id, cl.description, sum(cl.quantity) as qty
      from public.purchase_documents c
      join public.purchase_document_lines cl on cl.document_id = c.id
     where c.original_bill_id = p_bill
       and c.doc_type = 'purchase_credit_note'
       and c.status = 'posted'
       and cl.line_type = 'item'
     group by cl.item_id, cl.description
  )
  select l.id, l.line_no, l.item_id, l.description, l.uom_code, l.unit_price,
         l.quantity,
         coalesce(c.qty, 0),
         greatest(l.quantity - coalesce(c.qty, 0), 0)
    from public.purchase_document_lines l
    left join credited c
      on c.item_id is not distinct from l.item_id
     and c.description = l.description
   where l.document_id = p_bill
     and l.line_type = 'item'
   order by l.line_no;
end;
$$;

revoke all on function public.bill_credit_remaining(uuid) from public, anon;
grant execute on function public.bill_credit_remaining(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Raising the credit against the bill
-- ---------------------------------------------------------------------
create or replace function public.credit_purchase_bill(
  p_bill  uuid,
  p_lines jsonb default null,
  p_reason text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_doc  public.purchase_documents;
  v_note uuid;
  v_no   text;
  v_row  record;
  v_want numeric;
  v_n    integer := 0;
begin
  select * into v_doc from public.purchase_documents d
   where d.id = p_bill and d.doc_type = 'bill';
  if v_doc.id is null then
    raise exception 'No such bill.' using errcode = 'P0002';
  end if;
  if not app.can_post(v_doc.org_id) then
    raise exception
      'Crediting a bill posts a document, which needs permission this '
      'account has not been given.'
      using errcode = '42501';
  end if;
  if v_doc.status not in ('posted', 'partial', 'completed') then
    raise exception
      'That bill is %, so there is nothing to credit yet.', v_doc.status
      using errcode = '23514';
  end if;

  v_no := app.next_document_number_internal(
            v_doc.org_id, 'purchase_credit_note');

  insert into public.purchase_documents (
    org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
    exchange_rate, status, original_bill_id, parent_id, notes, created_by)
  values (
    v_doc.org_id, 'purchase_credit_note', v_no, current_date, current_date,
    v_doc.contact_id, v_doc.currency,
    -- The bill's rate, not today's. The credit reverses money recorded
    -- at that rate; re-resolving it would book an FX gain on a return.
    v_doc.exchange_rate, 'draft',
    p_bill, p_bill,
    coalesce(nullif(btrim(coalesce(p_reason, '')), ''),
             'Credit against ' || v_doc.doc_no),
    auth.uid())
  returning id into v_note;

  for v_row in
    select r.*,
           (select (e ->> 'quantity')::numeric
              from jsonb_array_elements(p_lines) e
             where (e ->> 'line')::uuid = r.line_id) as asked
      from public.bill_credit_remaining(p_bill) r
  loop
    v_want := case when p_lines is null then v_row.remaining
                   else coalesce(v_row.asked, 0) end;
    if v_want <= 0 then
      continue;
    end if;
    if v_want > v_row.remaining then
      raise exception
        'Only % of "%" is left uncredited on %, and this asks for %. A '
        'credit note is a document about money, not a claim for goods '
        'the supplier never sent.',
        v_row.remaining, v_row.description, v_doc.doc_no, v_want
        using errcode = '23514';
    end if;

    v_n := v_n + 1;
    insert into public.purchase_document_lines (
      org_id, document_id, line_no, line_type, item_id, description,
      quantity, uom_code, unit_price, tax_code_id, tax_rate,
      is_tax_inclusive, warehouse_id, account_id)
    select v_doc.org_id, v_note, v_n, 'item', l.item_id, l.description,
           v_want, l.uom_code, l.unit_price, l.tax_code_id, l.tax_rate,
           l.is_tax_inclusive, l.warehouse_id, l.account_id
      from public.purchase_document_lines l where l.id = v_row.line_id;
  end loop;

  if v_n = 0 then
    -- Nothing to credit. The half-built note needs no deleting: this
    -- raise unwinds the whole call, and the insert above goes with it.
    --
    -- `0269` deletes the row first, and the mutation run showed that
    -- line is dead there too — removing it changed no assertion, because
    -- there is no path out of here that does not raise. Said out loud so
    -- the next reader does not copy it back in thinking it was load
    -- bearing.
    raise exception
      'There is nothing left to credit on %.', v_doc.doc_no
      using errcode = '23514';
  end if;

  perform app.post_purchase_document_internal(v_note);
  return v_note;
end;
$$;

revoke all on function public.credit_purchase_bill(uuid, jsonb, text)
  from public, anon;
grant execute on function public.credit_purchase_bill(uuid, jsonb, text)
  to authenticated;

comment on function public.bill_credit_remaining(uuid) is
  'What is left uncredited on each line of a bill, matched on item and '
  'description together so that two lines for the same item are two '
  'different things to credit.';
comment on function public.credit_purchase_bill(uuid, jsonb, text) is
  'Raises and posts a credit note against a supplier bill, capped at '
  'what is left uncredited on each line, and records which bill it '
  'credits — which nothing has ever done. 0269 is the same function one '
  'table over, and its header says why the link matters.';
