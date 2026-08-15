-- =====================================================================
-- iAkauntan :: billing another company in the group
--
-- 0142 added `contacts.linked_org_id` and said it was "needed by the
-- report below, and by inter-company billing when that is built". This
-- builds it.
--
-- ---------------------------------------------------------------------
-- First, a correction to 0145
--
-- 0145 put a trigger on `purchase_documents` refusing tax on a document
-- dated before the company's SST registration took effect. On sales
-- documents that is the rule. On purchases it is wrong, and building
-- this migration is what showed it: a purchase document records tax a
-- *supplier* charged us, and a supplier charges what their own
-- registration says, not what ours does. An unregistered company can be
-- charged service tax every day of the week and has to be able to record
-- the bill.
--
-- Under GST there would be an argument, because input tax recovery
-- depends on the buyer's registration. SST is not a credit system:
-- service tax paid is a cost. So the buyer's registration date has
-- nothing to say about it, and the trigger goes.
--
-- ---------------------------------------------------------------------
-- What consent looks like here
--
-- The obvious rule — "companies in the same group can see each other's
-- invoices" — is wrong, and wrong in the direction that matters. A
-- group is a name, not a key to the books: 0132 said so, 0135 said so
-- again for chat, and 0142's `app.group_orgs` enforces it by requiring
-- membership of *both* companies.
--
-- But inter-company billing cannot require that. The whole point is that
-- a clerk in the subsidiary handles a bill from the holding company
-- without having access to the holding company's ledger.
--
-- So the consent is the contact link. When A raises an invoice on a
-- customer whose `linked_org_id` is B, A has addressed that document to
-- B by name. B may see that one document — their own invoice, which
-- they are entitled to — and nothing else of A's. Same group is
-- necessary and not sufficient; the addressing is what opens it.
--
-- ---------------------------------------------------------------------
-- Why accepting is a deliberate act
--
-- The tempting design is a trigger: A posts, a bill appears in B. That
-- puts entries in a company's ledger that nobody in that company
-- entered, dated and numbered by somebody else's system, and the first
-- B hears of it is a figure that will not reconcile.
--
-- So A's posting makes the invoice *visible* to B, and somebody in B
-- turns it into a bill. What they get is a draft, because two things
-- cannot be carried across and must be decided in B: which expense
-- account each line belongs to, and which of B's items it is. A's
-- account ids and item ids mean nothing in B's chart.
-- =====================================================================

drop trigger if exists purchase_documents_tax_before_registration
  on public.purchase_documents;

-- ---------------------------------------------------------------------
-- The link back to the invoice a bill mirrors
--
-- Unique, which is the whole of the double-entry protection: accepting
-- the same invoice twice cannot produce two bills, however many times
-- somebody taps a slow button.
-- ---------------------------------------------------------------------
alter table public.purchase_documents
  add column source_sales_document_id uuid
    references public.sales_documents (id) on delete set null;

create unique index purchase_documents_source_sales_idx
  on public.purchase_documents (source_sales_document_id)
  where source_sales_document_id is not null;

comment on column public.purchase_documents.source_sales_document_id is
  'The invoice in another group company that this bill was raised from. '
  'Set by accept_intercompany_bill(); unique, so one invoice can become '
  'at most one bill.';

-- ---------------------------------------------------------------------
-- Invoices from group companies addressed to this one
--
-- `already_billed` rather than filtering them out: an accountant looking
-- for last month's invoice from the holding company should find it and
-- see that it was dealt with, not find nothing and wonder.
-- ---------------------------------------------------------------------
create or replace function public.intercompany_inbox(p_org_id uuid)
returns table (
  sales_document_id   uuid,
  from_org_id         uuid,
  from_org            text,
  doc_no              text,
  doc_date            date,
  currency            text,
  subtotal            numeric,
  tax_amount          numeric,
  total_amount        numeric,
  supplier_contact_id uuid,
  bill_id             uuid,
  already_billed      boolean)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select d.id, issuer.id, issuer.name, d.doc_no, d.doc_date,
         d.currency::text, d.subtotal, d.tax_amount, d.total_amount,
         -- The supplier in *this* company that stands for the issuer.
         -- Null means somebody has to create one before a bill can be
         -- raised, and the screen says so.
         (select s.id from public.contacts s
           where s.org_id = p_org_id
             and s.linked_org_id = issuer.id
             and s.contact_type in ('supplier', 'both')
           order by s.created_at limit 1),
         bill.id,
         bill.id is not null
    from public.sales_documents d
    join public.contacts c on c.id = d.contact_id
    join public.organizations issuer on issuer.id = d.org_id
    join public.organizations mine on mine.id = p_org_id
    left join public.purchase_documents bill
           on bill.source_sales_document_id = d.id
   where app.is_org_member(p_org_id)
     -- Addressed to me by name. This, not group membership, is what
     -- makes one of another company's documents readable here.
     and c.linked_org_id = p_org_id
     and issuer.group_id is not null
     and issuer.group_id = mine.group_id
     and issuer.id <> p_org_id
     and d.doc_type = 'invoice'
     and d.status = 'posted'
   order by d.doc_date desc, d.doc_no desc;
$$;

revoke all on function public.intercompany_inbox(uuid) from public, anon;
grant execute on function public.intercompany_inbox(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Turning one into a draft bill
-- ---------------------------------------------------------------------
create or replace function public.accept_intercompany_bill(
  p_sales_document_id uuid, p_org_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_row record;
  v_bill uuid;
  v_supplier uuid;
begin
  if not app.can_write(p_org_id) then
    raise exception 'You cannot raise bills in this company'
      using errcode = '42501';
  end if;

  -- Read it back through the inbox rather than from the table, so the
  -- addressing rule is written once and cannot drift between what a
  -- person may see and what they may act on.
  select * into v_row from public.intercompany_inbox(p_org_id) i
   where i.sales_document_id = p_sales_document_id;

  -- FOUND rather than `v_row is null`: a record is null only when every
  -- column is, which is true here but by accident rather than by rule.
  if not found then
    raise exception
      'That invoice is not addressed to this company, or has not been '
      'posted yet' using errcode = '42501';
  end if;

  if v_row.already_billed then
    raise exception 'That invoice has already been billed here';
  end if;

  if v_row.supplier_contact_id is null then
    raise exception
      'Add a supplier in this company linked to %, then try again. A bill '
      'has to be owed to somebody on this company''s own books.',
      v_row.from_org;
  end if;
  v_supplier := v_row.supplier_contact_id;

  insert into public.purchase_documents (
    org_id, doc_type, doc_no, doc_date, contact_id,
    supplier_doc_no, supplier_doc_date,
    currency, exchange_rate,
    subtotal, discount_amount, tax_amount, total_amount, base_total_amount,
    balance_amount, status, source_sales_document_id)
  select p_org_id, 'bill',
         app.next_document_number_internal(p_org_id, 'bill'),
         d.doc_date, v_supplier,
         -- Their number on our bill, which is what an SST audit and a
         -- self-billed e-Invoice both ask for.
         d.doc_no, d.doc_date,
         d.currency, d.exchange_rate,
         d.subtotal, d.discount_amount, d.tax_amount, d.total_amount,
         d.base_total_amount, d.total_amount, 'draft', d.id
    from public.sales_documents d
   where d.id = p_sales_document_id
  returning id into v_bill;

  insert into public.purchase_document_lines (
    org_id, document_id, line_no, line_type, description,
    quantity, uom_code, unit_price,
    discount_percent, discount_amount,
    tax_code_id, tax_rate, tax_amount, is_tax_inclusive,
    line_subtotal, line_total)
  select p_org_id, v_bill, l.line_no, l.line_type, l.description,
         l.quantity, l.uom_code, l.unit_price,
         l.discount_percent, l.discount_amount,
         -- Matched by code, not by id: the two companies have their own
         -- tax_codes rows, and an id from theirs would point at nothing
         -- here — or, worse, at one of ours by coincidence.
         (select t.id from public.tax_codes t
           where t.org_id = p_org_id
             and t.code = (select s.code from public.tax_codes s
                            where s.id = l.tax_code_id)),
         l.tax_rate, l.tax_amount, l.is_tax_inclusive,
         l.line_subtotal, l.line_total
    from public.sales_document_lines l
   where l.document_id = p_sales_document_id
   order by l.line_no;

  -- Deliberately not copied: `item_id` and `account_id`. Both are ids in
  -- the issuer's own masters. Which of our items this is, and which
  -- expense account it belongs in, are decisions for this company —
  -- which is why the bill arrives as a draft rather than posted.
  return v_bill;
end; $$;

revoke all on function public.accept_intercompany_bill(uuid, uuid)
  from public, anon;
grant execute on function public.accept_intercompany_bill(uuid, uuid)
  to authenticated;
