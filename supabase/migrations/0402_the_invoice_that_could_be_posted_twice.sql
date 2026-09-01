-- =====================================================================
-- iAkauntan :: 0402 the invoice that could be posted twice
--
-- `0238` made the ledger append-only. `0399` shut the door beside the
-- door, so the ledger is written only by SECURITY DEFINER functions.
-- `0400` did the same for the payslip. All three rest on one sentence
-- from `0238`: a figure that has been reported is not a figure anybody
-- may quietly change afterwards.
--
-- The sales invoice is the biggest of the three and nobody had applied
-- it there.
--
-- ---------------------------------------------------------------------
-- Measured, as an `accountant`, under `set local role authenticated`
--
-- One invoice of RM1,000, posted, `gl_entry_id` set:
--
--   update sales_document_lines set unit_price = 1
--       accepted -- and `recalc_totals` rewrote the header from
--       1,000.00 to 10.00 while the ledger kept saying 1,000.00
--   update sales_documents set total_amount = 5, doc_no = 'INV-CHANGED'
--       accepted -- a different number on a different amount
--   delete from sales_document_lines
--       accepted -- the invoice now has no lines at all
--   delete from sales_documents
--       accepted -- the invoice is gone and its journal is still
--       in the ledger with nothing to explain it
--
-- and the one that is not merely a disagreement:
--
--   update sales_documents set gl_entry_id = null, status = 'draft'
--   select post_sales_document(<the same invoice>)
--       -> a second entry. Two journals, RM2,000 of revenue and
--          receivable, for one RM1,000 sale.
--
-- `post_sales_document_internal`'s only guard against posting the same
-- document twice is
--
--     if v_doc.gl_entry_id is not null then
--       raise exception 'Document % is already posted', v_doc.doc_no;
--
-- which is a fact stored in a column the client may write. `0399` found
-- the same shape in the ledger: every guard in the function, and the
-- table sitting open beside it.
--
-- ---------------------------------------------------------------------
-- What the audit log does and does not hold
--
-- The first measurement of this said "and no audit row was written by
-- any of it", which was wrong, and wrong in a way this project has
-- caught before: the count was run while the session was still
-- `set local role authenticated`, and RLS on `audit_logs` does not show
-- an accountant the whole company's history. Counted again as the owner:
--
--     update {"subtotal": 10.00, "total_amount": 10.00, ...}
--     update {"status": "draft", "gl_entry_id": null}
--
-- `sales_documents` carries `audit_changes` and both writes are in it.
-- What is *not* there is the line: `sales_document_lines` has no audit
-- trigger at all, so a price rewritten from 100.00 to 1.00 appears only
-- as the header total it recomputed.
--
-- So the argument for this migration is not that nothing records the
-- change. It is that nothing refuses it, and the ledger it disagrees
-- with cannot be corrected to match — `0238` saw to that. A trail that
-- says an invoice was quietly halved is worth having and is not a
-- control.
--
-- ---------------------------------------------------------------------
-- `gl_entry_id is not null`, not `status = 'posted'`
--
-- The status moves on: `posted` becomes `partial` when a payment lands
-- and `completed` when the last one does, and `void` when the document
-- is undone. A rule written on the status would stop biting the moment
-- somebody paid the invoice. `gl_entry_id` is the fact itself — this
-- document has reached the ledger — and it does not move.
--
-- ---------------------------------------------------------------------
-- Named columns, because most of the row must go on moving
--
-- This is the half that would break the application if it were done
-- with a blunt freeze. A posted invoice is written to constantly and
-- legitimately: `apply_allocation` moves `paid_amount` and
-- `balance_amount` and `status` on every payment; the MyInvois
-- submission writes `einvoice_id` and `einvoice_status` after the
-- posting, not before; `void_sales_document` writes `status` and
-- `internal_notes`; and `refresh_sales_progress` writes
-- `fulfilment_status` on the header and `quantity_invoiced` /
-- `quantity_fulfilled` on the *lines* of a posted invoice whenever
-- something is transferred from it.
--
-- So the header freezes a named list — the figures and identifiers the
-- journal was built from — and everything else goes on working. The
-- lines are the other way round, an allow-list of the two progress
-- counters, because there is no other reason to touch the lines of a
-- document that has been posted.
--
-- A deny-list is only as good as its list, so
-- `posted_document_is_frozen.sql` enumerates every column on both
-- tables and requires each one to be in the frozen set or in an
-- explicitly named "still writable" set. A column added later belongs
-- to neither and fails, which is the point: somebody has to say which
-- side of the line it is on.
--
-- ---------------------------------------------------------------------
-- The rule already existed, in Dart
--
-- `document_editor.dart` has, and has had all along:
--
--     bool get _isPosted => _glEntryId != null;
--     final editable = !_isPosted && canWrite && !transferred;
--
-- The same predicate this migration uses, reached by the same
-- reasoning, one layer up. `CLAUDE.md` says what that is worth: "A rule
-- enforced only in Dart is not enforced." PostgREST publishes both
-- tables to any caller holding a session, so the form declining to
-- offer the edit was never the same thing as the edit being refused —
-- and the measurements above were all made through the same API the
-- form uses.
--
-- Nothing in the client changes. It was already right; it was only
-- alone.
--
-- ---------------------------------------------------------------------
-- What the line rule adds over the header rule
--
-- Worth writing down because the first set of assertions for this did
-- not know, and passed anyway. Every write to a line runs
-- `recalc_totals`, which rewrites the header's subtotal, tax and total
-- — so a line change that moves money is refused by the *header* rule
-- whether the line rule exists or not. Mutation testing said so:
-- switching the line rule off entirely left "a posted invoice's line
-- cannot be repriced" passing.
--
-- What only the line rule reaches is the part of a line the totals do
-- not depend on — `description`, `item_id`, `account_id`,
-- `warehouse_id`, `cost_amount`, the `service_start`/`service_end` pair
-- that `0309` defers revenue on, and the `project_code` /
-- `department_code` dimensions that go onto the journal line — and a
-- line worth nothing, whose arrival or departure moves no total at all.
-- `posted_document_is_frozen.sql` asks it those questions, and keeps a
-- nil-value line in the fixture for exactly that purpose.
--
-- The money columns stay on the line list regardless. They are the
-- second half of a pair of statements that should not disagree, and the
-- refusal names the line rather than the header the line moved.
--
-- ---------------------------------------------------------------------
-- The one figure that had to come back off the list
--
-- `contact_id` was frozen in the first draft, on the reasoning that
-- `post_sales_document_internal` writes it onto the receivable line —
-- `'contact_id', v_doc.contact_id` — so moving it leaves the document
-- and the sub-ledger naming different people.
--
-- Running the suite refused a real path for it, which is why the suite
-- is run rather than the reasoning trusted. A counter sale completes
-- against the outlet's walk-in contact and posts immediately; the
-- customer then says "boss, I need it under the company name", and
-- `request_einvoice_for_sale` puts their name on the invoice so LHDN
-- gets an e-Invoice with a TIN on it. That is not somebody editing a
-- posted invoice. It is the shape MyInvois expects, and `0210` wrote it
-- deliberately, with LHDN's own rules attached — it refuses once the
-- sale has gone into a consolidated e-Invoice, and refuses a customer
-- with no TIN.
--
-- So `contact_id` is writable, and the disagreement it used to cause is
-- closed instead: `request_einvoice_for_sale` is recreated below to
-- move the receivable line's `contact_id` with the document's, in the
-- same transaction. It runs as the owner and is the only path that
-- renames a posted document's buyer, which is exactly the arrangement
-- `0399` settled on for the ledger — written by a SECURITY DEFINER
-- function, and by nothing else.
--
-- Nothing else about the journal moves: the amount, the account, the
-- date and the entry are all untouched. What changes is which contact
-- the receivable is filed under, which is the thing the document just
-- changed its mind about.
--
-- ---------------------------------------------------------------------
-- The way out is the one that already exists
--
-- `void_sales_document` reverses the journal through `reverse_gl_entry`
-- — `0102` made that leave the original standing — and marks the
-- document void. `credit_sales_invoice` raises a credit note against
-- it. Both make the correction visible, which is the whole difference
-- between an amendment and an edit.
--
-- A cascade is not an edit: when the organization row has already gone,
-- these rows are being deleted behind it and the trigger stands aside.
-- `app.write_audit_log` uses exactly this test and says why.
-- =====================================================================

create or replace function app.refuse_posted_document_change()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  -- The figures and identifiers the journal was built from. Same list
  -- for both tables; a column absent from one is skipped rather than
  -- assumed.
  c_frozen constant text[] := array[
    'id', 'org_id', 'doc_type', 'doc_no', 'doc_date',
    'currency', 'exchange_rate', 'subtotal', 'discount_amount',
    'discount_percent', 'tax_amount', 'shipping_amount',
    'rounding_amount', 'total_amount', 'base_total_amount',
    'branch_id', 'matter_id', 'posted_at', 'posted_by', 'gl_entry_id'];
  -- The same question asked of the line: which of its columns did the
  -- journal read? Everything else on a line goes on moving, and some of
  -- it has to -- `app.refresh_sales_progress` and
  -- `app.refresh_purchase_progress` write the four progress counters on
  -- the lines of a posted document every time something is transferred
  -- from or received against it, and `source_line_id` is the link they
  -- follow.
  c_line_frozen constant text[] := array[
    'id', 'org_id', 'document_id', 'line_no', 'line_type', 'item_id',
    'description', 'quantity', 'base_quantity', 'uom_code', 'unit_price',
    'discount_amount', 'discount_percent', 'tax_code_id', 'tax_rate',
    'is_tax_inclusive', 'line_subtotal', 'tax_amount', 'line_total',
    'account_id', 'warehouse_id', 'cost_amount',
    'service_start', 'service_end', 'project_code', 'department_code'];
  v_is_line boolean := tg_table_name like '%_lines';
  v_entry   uuid;
  v_no      text;
  v_org     uuid;
  v_old     jsonb := case when tg_op = 'INSERT' then null else to_jsonb(old) end;
  v_new     jsonb := case when tg_op = 'DELETE' then null else to_jsonb(new) end;
  v_col     text;
begin
  if v_is_line then
    select d.gl_entry_id, d.doc_no, d.org_id into v_entry, v_no, v_org
      from public.sales_documents d
     where tg_table_name = 'sales_document_lines'
       and d.id = coalesce((v_new ->> 'document_id')::uuid,
                           (v_old ->> 'document_id')::uuid);
    if v_no is null then
      select d.gl_entry_id, d.doc_no, d.org_id into v_entry, v_no, v_org
        from public.purchase_documents d
       where tg_table_name = 'purchase_document_lines'
         and d.id = coalesce((v_new ->> 'document_id')::uuid,
                             (v_old ->> 'document_id')::uuid);
    end if;
  else
    v_entry := (coalesce(v_old, v_new) ->> 'gl_entry_id')::uuid;
    v_no    := coalesce(v_old, v_new) ->> 'doc_no';
    v_org   := nullif(coalesce(v_old, v_new) ->> 'org_id', '')::uuid;
  end if;

  -- Not posted: this is an ordinary document and none of this applies.
  -- A line whose document has already gone is in the same position.
  if v_entry is null then
    return coalesce(new, old);
  end if;

  -- The company is already gone and these rows are cascading away
  -- behind it. `app.write_audit_log` makes the same check for the same
  -- reason, and only on a delete: an insert or an update cannot name an
  -- organization that does not exist, because the row's own foreign key
  -- has already said so.
  if tg_op = 'DELETE'
     and v_org is not null
     and not exists (select 1 from public.organizations o where o.id = v_org)
  then
    return old;
  end if;

  if tg_op = 'DELETE' then
    raise exception
      '% is posted: its journal is in the ledger, which `0238` made '
      'append-only, and deleting it would leave that journal with '
      'nothing to explain it. Void the document instead, which reverses '
      'the journal, or raise a credit note against it.', v_no
      using errcode = '42501';
  end if;

  if tg_op = 'INSERT' then
    raise exception
      'A line cannot be added to %, which is posted. Its journal was '
      'built from the lines it had. Raise a credit note or a further '
      'document instead.', v_no
      using errcode = '42501';
  end if;

  if v_is_line then
    foreach v_col in array c_line_frozen loop
      if (v_new ? v_col)
         and (v_new -> v_col) is distinct from (v_old -> v_col) then
        raise exception
          'Line % of % cannot be changed: % is posted and its journal '
          'was built from this line''s % (% -> %). Void the document or '
          'raise a credit note.',
          coalesce(v_new ->> 'line_no', '?'), v_no, v_no, v_col,
          coalesce(v_old ->> v_col, 'null'), coalesce(v_new ->> v_col, 'null')
          using errcode = '42501';
      end if;
    end loop;
    return new;
  end if;

  foreach v_col in array c_frozen loop
    if (v_new ? v_col)
       and (v_new -> v_col) is distinct from (v_old -> v_col) then
      -- `gl_entry_id` is worth its own sentence: clearing it is not a
      -- disagreement with the ledger, it is a second posting waiting to
      -- happen. `post_sales_document_internal` refuses to post twice by
      -- reading this column and nothing else.
      if v_col = 'gl_entry_id' then
        raise exception
          '% is already posted as journal %. Clearing the link would '
          'let it be posted a second time, and the company would carry '
          'the sale twice. Void the document, which reverses the '
          'journal through `reverse_gl_entry`.',
          v_no, (v_old ->> 'gl_entry_id')
          using errcode = '42501';
      end if;
      raise exception
        '% is posted and % is one of the figures its journal was built '
        'from (% -> %). The ledger is append-only, so this would leave '
        'the document and the accounts disagreeing with no way to '
        'reconcile them. Void the document or raise a credit note.',
        v_no, v_col,
        coalesce(v_old ->> v_col, 'null'), coalesce(v_new ->> v_col, 'null')
        using errcode = '42501';
    end if;
  end loop;

  return new;
end $$;

comment on function app.refuse_posted_document_change() is
  '`0238` for the sales and purchase document. Measured before `0402`: '
  'an accountant could rewrite a posted RM1,000 invoice''s line to '
  'RM1.00, change its number, delete its lines, delete the document, '
  'and — by setting gl_entry_id back to null — post the same invoice a '
  'second time for a second journal.';

create trigger refuse_posted_change
  before update or delete on public.sales_documents
  for each row execute function app.refuse_posted_document_change();

create trigger refuse_posted_change
  before update or delete on public.purchase_documents
  for each row execute function app.refuse_posted_document_change();

-- INSERT as well on the lines: a line added to a posted document is the
-- same disagreement as one changed, and `assert_gl_balanced` fires on
-- the entry rather than on every line, so nothing downstream would
-- notice. `0399` learned this about `gl_lines`.
create trigger refuse_posted_change
  before insert or update or delete on public.sales_document_lines
  for each row execute function app.refuse_posted_document_change();

create trigger refuse_posted_change
  before insert or update or delete on public.purchase_document_lines
  for each row execute function app.refuse_posted_document_change();

revoke all on function app.refuse_posted_document_change()
  from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- And the one path that renames a buyer keeps the sub-ledger with it
-- ---------------------------------------------------------------------
-- `0210`'s function, unchanged except for the four lines that move the
-- receivable line's contact along with the document's. Before this, the
-- invoice said the customer's name and the general ledger still filed
-- the receivable under the outlet's walk-in contact, so an aged
-- receivables report built from `gl_lines` and one built from
-- `sales_documents` named different people for the same money.
create or replace function public.request_einvoice_for_sale(
  p_sale    uuid,
  p_contact uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale public.pos_sales;
  v_tin  text;
  v_ei   uuid;
  v_old  uuid;
  v_gl   uuid;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_sale.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if v_sale.status <> 'completed' or v_sale.invoice_id is null then
    raise exception
      'That sale has not been completed, so there is no invoice to name.'
      using errcode = '23514';
  end if;

  -- Already told LHDN this sale had no identified buyer.
  if exists (select 1 from public.einvoice_consolidation_items ci
              where ci.sales_document_id = v_sale.invoice_id) then
    raise exception
      'This sale has already gone into a consolidated e-Invoice. Raise a '
      'credit note and re-issue it if the buyer needs their own.'
      using errcode = '23514';
  end if;

  select nullif(btrim(c.tin), '') into v_tin
    from public.contacts c
   where c.id = p_contact and c.org_id = v_sale.org_id;
  if v_tin is null then
    raise exception
      'That customer has no TIN on file. LHDN needs one before an '
      'e-Invoice can be raised in their name.'
      using errcode = '23514';
  end if;

  select d.contact_id, d.gl_entry_id into v_old, v_gl
    from public.sales_documents d where d.id = v_sale.invoice_id;

  update public.sales_documents
     set contact_id = p_contact
   where id = v_sale.invoice_id;

  -- The receivable was filed under whoever the invoice named when it
  -- posted, and the invoice has just changed its mind. Only the lines
  -- that carried the old contact are touched, and only the dimension:
  -- no amount, no account, no date, no entry. `0238` is about what the
  -- ledger says the company earned, and this does not move it.
  if v_gl is not null and v_old is distinct from p_contact then
    update public.gl_lines l
       set contact_id = p_contact
     where l.entry_id = v_gl
       and l.contact_id is not distinct from v_old;
  end if;

  update public.pos_sales
     set contact_id = p_contact
   where id = p_sale;

  v_ei := public.prepare_einvoice(v_sale.invoice_id);
  return v_ei;
end;
$$;

revoke all on function public.request_einvoice_for_sale(uuid, uuid) from public, anon;
grant execute on function public.request_einvoice_for_sale(uuid, uuid) to authenticated;
