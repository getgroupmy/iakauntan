-- =====================================================================
-- iAkauntan :: 0631 the year before this one
--
-- Seven importers exist -- contacts, items, the chart, open invoices,
-- open bills, opening balances, opening stock -- and `0150` does the
-- hard one: AR and AP opening balances arrive AS OPEN ITEMS rather than
-- as a lump on a control account, which is the thing most changeover
-- tools get wrong.
--
-- What has never existed is importing TRANSACTIONS. A company moving
-- from another package in March has two months of invoices it would
-- like to keep, and the only answer this product has is to type them
-- in. That is the last thing standing between a prospect and a
-- changeover.
--
-- ---------------------------------------------------------------------
-- One row per LINE, grouped by document number
--
-- Which is how every package exports and the only shape a spreadsheet
-- can hold. It makes the interesting problem a GROUPING problem rather
-- than a parsing one, and the grouping is where this would go wrong:
--
--   * a bad row poisons its whole document, not just itself. Importing
--     four of an invoice's five lines produces an invoice for the wrong
--     money that looks perfectly well formed.
--   * the header fields have to AGREE across a group. A file where row
--     3 and row 7 give `INV-1` two different dates is a file somebody
--     edited by hand, and picking one silently is picking wrong half
--     the time. It is reported against the row that disagrees, naming
--     the row it disagrees WITH, because "INV-1 has two dates" is not
--     something anybody can find in a thousand-line spreadsheet.
--
-- ---------------------------------------------------------------------
-- It imports DRAFTS. It posts nothing.
--
-- The line `0625` and `0628` drew, and here it is at its sharpest: this
-- is the one importer that could create five hundred documents in a
-- single statement, and posting them would put five hundred journals in
-- the ledger before anybody had read one. They arrive as drafts, the
-- list screen shows them, and posting is the action it already has.
--
-- A changeover is also exactly when the file is wrong. A draft can be
-- corrected or deleted; a posted document needs a reversal.
--
-- ---------------------------------------------------------------------
-- Run it twice and nothing happens twice
--
-- `import_source` and `import_ref` are `0610`'s provenance columns, and
-- `sales_documents_import_key` is a UNIQUE index over
-- `(org_id, import_source, import_ref)`. Setting `import_ref` to the
-- document's own number makes re-running the same file a database
-- refusal rather than a second set of invoices -- which is the failure
-- an import tool has to survive, because the second run is somebody who
-- was not sure the first one worked.
--
-- ---------------------------------------------------------------------
-- The totals are the triggers', not this function's
--
-- `app.calc_document_line` computes a line and `app.recalc_sales_totals`
-- computes the document. This inserts quantity, price and tax code and
-- lets them run, so an imported invoice adds up the same way one typed
-- into the editor does. A function that did its own arithmetic would be
-- a second opinion about what an invoice comes to.
-- =====================================================================

-- ---------------------------------------------------------------------
-- What is wrong with the file, row by row
-- ---------------------------------------------------------------------
create or replace function app.validate_sales_transactions(
  p_org_id uuid, p_rows jsonb)
returns jsonb
language plpgsql
stable
set search_path = public, app, pg_temp as $$
declare
  r          jsonb;
  i          integer := 0;
  v_out      jsonb := '[]'::jsonb;
  v_base     text;
  v_no       text;
  v_key      text;
  v_type     text;
  v_contact  text;
  v_date     date;
  v_currency text;
  v_qty      numeric;
  v_price    numeric;
  v_tax      text;
  v_item     text;
  v_problem  text;
  -- The first row of each group, so a later row can be told which row
  -- it disagrees with rather than merely that it disagrees.
  v_heads    jsonb := '{}'::jsonb;
  v_head     jsonb;
begin
  select base_currency into v_base
    from public.organizations where id = p_org_id;

  for r in select * from jsonb_array_elements(p_rows)
  loop
    i := i + 1;
    v_problem := null;

    v_no       := app.import_text(r, 'doc_no');
    v_type     := lower(coalesce(app.import_text(r, 'doc_type'), 'invoice'));
    v_contact  := app.import_text(r, 'contact_code');
    v_date     := app.import_date(app.import_text(r, 'doc_date'));
    v_currency := upper(coalesce(app.import_text(r, 'currency'), v_base));
    v_qty      := app.import_number(app.import_text(r, 'quantity'), 1);
    v_price    := app.import_number(app.import_text(r, 'unit_price'), null);
    v_tax      := app.import_text(r, 'tax_code');
    v_item     := app.import_text(r, 'item_code');
    v_key      := lower(coalesce(v_no, ''));

    if v_no is null then
      v_problem := 'No document number. It is what groups the lines of '
                || 'one document together, so a row without one cannot '
                || 'belong to anything.';
    elsif v_type not in ('invoice', 'credit_note', 'debit_note') then
      v_problem := format(
        '%s is not a kind of document this imports. Use invoice, '
        'credit_note or debit_note.', app.import_text(r, 'doc_type'));
    elsif v_contact is null then
      v_problem := 'No customer code.';
    elsif not exists (
      select 1 from public.contacts c
       where c.org_id = p_org_id and lower(c.code) = lower(v_contact)
         and c.deleted_at is null)
    then
      v_problem := format(
        'There is no customer with the code %s. Import the contacts '
        'first.', v_contact);
    elsif v_date is null then
      v_problem := format('%s has no date, or one that could not be '
                       || 'read.', v_no);
    elsif v_price is null then
      v_problem := 'No unit price on this line.';
    -- `app.import_number` returns the DEFAULT for a blank cell and NULL
    -- for one it cannot read, so a quantity of "2.5 hrs" is null here
    -- and 1 would be wrong. Without this the commit dies on
    -- `sales_document_lines.quantity` being NOT NULL, which is a
    -- constraint name where a sentence belongs.
    elsif v_qty is null then
      v_problem := format(
        '%s is not a quantity this can read. Numbers only -- no units, '
        'no words.', app.import_text(r, 'quantity'));
    elsif v_tax is not null and not exists (
      select 1 from public.tax_codes t
       where t.org_id = p_org_id and lower(t.code) = lower(v_tax))
    then
      v_problem := format('There is no tax code %s here.', v_tax);
    elsif v_item is not null and not exists (
      select 1 from public.items it
       where it.org_id = p_org_id and lower(it.code) = lower(v_item)
         and it.deleted_at is null)
    then
      v_problem := format('There is no item with the code %s.', v_item);
    end if;

    -- The document-level checks, which only make sense once the row
    -- itself is sound.
    if v_problem is null then
      v_head := v_heads -> v_key;

      if v_head is null then
        -- First sight of this document: it must not already be here,
        -- and it must not have been imported before.
        if exists (
          select 1 from public.sales_documents d
           where d.org_id = p_org_id
             and lower(d.doc_no) = v_key
             and d.deleted_at is null)
        then
          v_problem := format(
            'There is already a %s numbered %s here.', v_type, v_no);
        elsif exists (
          select 1 from public.sales_documents d
           where d.org_id = p_org_id
             and d.import_source = 'transactions'
             and lower(d.import_ref) = v_key)
        then
          v_problem := format(
            '%s was imported before. Running the same file twice does '
            'not import it twice.', v_no);
        else
          v_heads := v_heads || jsonb_build_object(v_key,
            jsonb_build_object(
              'row', i, 'type', v_type, 'contact', lower(v_contact),
              'date', v_date, 'currency', v_currency));
        end if;
      else
        -- Seen before in this file: the header has to say the same
        -- thing. Named against the row it disagrees with, because
        -- "INV-1 has two dates" is not findable in a thousand lines.
        if (v_head ->> 'type') <> v_type then
          v_problem := format(
            'Row %s calls %s a %s and this row calls it a %s.',
            v_head ->> 'row', v_no, v_head ->> 'type', v_type);
        elsif (v_head ->> 'contact') <> lower(v_contact) then
          v_problem := format(
            'Row %s puts %s against customer %s and this row puts it '
            'against %s.', v_head ->> 'row', v_no,
            v_head ->> 'contact', lower(v_contact));
        elsif (v_head ->> 'date')::date <> v_date then
          v_problem := format(
            'Row %s dates %s %s and this row dates it %s.',
            v_head ->> 'row', v_no, v_head ->> 'date', v_date);
        elsif (v_head ->> 'currency') <> v_currency then
          v_problem := format(
            'Row %s puts %s in %s and this row puts it in %s.',
            v_head ->> 'row', v_no, v_head ->> 'currency', v_currency);
        end if;
      end if;
    end if;

    v_out := v_out || jsonb_build_object(
      'row', i,
      'doc_no', v_no,
      'status', case when v_problem is null then 'ok' else 'error' end,
      'problem', v_problem);
  end loop;

  return v_out;
end $$;

comment on function app.validate_sales_transactions(uuid, jsonb) is
  'What is wrong with a file of transaction lines, row by row. See 0631.';

revoke all on function app.validate_sales_transactions(uuid, jsonb)
  from public, anon;
grant execute on function app.validate_sales_transactions(uuid, jsonb)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Importing them
-- ---------------------------------------------------------------------
create or replace function public.import_sales_transactions(
  p_org_id uuid,
  p_rows   jsonb,
  p_commit boolean default false)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  r         jsonb;
  v_results jsonb;
  v_bad     integer;
  v_total   integer;
  v_no      text;
  v_key     text;
  v_docs    jsonb := '{}'::jsonb;
  v_doc     uuid;
  v_line    integer;
  v_lines   jsonb := '{}'::jsonb;
  v_made    integer := 0;
begin
  if not app.can_write(p_org_id) then
    raise exception 'not permitted to import' using errcode = '42501';
  end if;

  v_results := app.validate_sales_transactions(p_org_id, p_rows);
  select count(*) filter (where x ->> 'status' = 'error'), count(*)
    into v_bad, v_total
    from jsonb_array_elements(v_results) x;

  -- All or nothing, as every other importer here. A file half imported
  -- is a file nobody can run again: the good half is now a duplicate.
  if p_commit and v_bad > 0 then
    raise exception
      'Nothing was imported: % of % rows have a problem. Fix the file '
      'and run it again.', v_bad, v_total using errcode = '22023';
  end if;

  if p_commit then
    for r in select * from jsonb_array_elements(p_rows)
    loop
      v_no  := app.import_text(r, 'doc_no');
      v_key := lower(v_no);

      if v_docs ? v_key then
        v_doc  := (v_docs ->> v_key)::uuid;
        v_line := (v_lines ->> v_key)::integer + 1;
      else
        insert into public.sales_documents (
          org_id, doc_type, doc_no, doc_date, due_date, contact_id,
          reference, currency, exchange_rate, status,
          import_source, import_ref, imported_at, created_by)
        values (
          p_org_id,
          lower(coalesce(app.import_text(r, 'doc_type'),
                         'invoice'))::app.sales_doc_type,
          v_no,
          app.import_date(app.import_text(r, 'doc_date')),
          app.import_date(app.import_text(r, 'due_date')),
          (select c.id from public.contacts c
            where c.org_id = p_org_id
              and lower(c.code) = lower(app.import_text(r, 'contact_code'))
              and c.deleted_at is null),
          app.import_text(r, 'reference'),
          upper(coalesce(app.import_text(r, 'currency'),
            (select base_currency from public.organizations
              where id = p_org_id))),
          coalesce(app.import_number(
            app.import_text(r, 'exchange_rate'), null), 1),
          -- Drafts. The header says why, and it is the line in this
          -- migration a reviewer should be slowest to change.
          'draft',
          'transactions', v_no, now(), auth.uid())
        returning id into v_doc;

        v_docs  := v_docs  || jsonb_build_object(v_key, v_doc::text);
        v_line  := 1;
        v_made  := v_made + 1;
      end if;

      -- Quantity, price and tax code only. `app.calc_document_line` and
      -- `app.recalc_sales_totals` do the arithmetic, so an imported
      -- invoice adds up exactly the way a typed one does.
      insert into public.sales_document_lines (
        org_id, document_id, line_no, description, item_id,
        quantity, unit_price, discount_percent, tax_code_id)
      values (
        p_org_id, v_doc, v_line,
        coalesce(app.import_text(r, 'description'), ''),
        (select it.id from public.items it
          where it.org_id = p_org_id
            and lower(it.code) = lower(app.import_text(r, 'item_code'))
            and it.deleted_at is null),
        app.import_number(app.import_text(r, 'quantity'), 1),
        app.import_number(app.import_text(r, 'unit_price'), 0),
        coalesce(app.import_number(
          app.import_text(r, 'discount_percent'), null), 0),
        (select t.id from public.tax_codes t
          where t.org_id = p_org_id
            and lower(t.code) = lower(app.import_text(r, 'tax_code'))));

      v_lines := v_lines || jsonb_build_object(v_key, v_line);
    end loop;
  end if;

  return jsonb_build_object(
    'rows', v_results,
    'total', v_total,
    'errors', v_bad,
    'documents', v_made,
    'committed', p_commit);
end $$;

comment on function public.import_sales_transactions(uuid, jsonb, boolean) is
  'Imports sales invoices, credit notes and debit notes from one row '
  'per line, grouped by document number. Creates DRAFTS and posts '
  'nothing. p_commit false reports what would happen. See 0631.';

revoke all on function public.import_sales_transactions(uuid, jsonb, boolean)
  from public, anon;
grant execute on function public.import_sales_transactions(uuid, jsonb, boolean)
  to authenticated, service_role;
