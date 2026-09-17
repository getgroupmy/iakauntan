-- =====================================================================
-- iAkauntan :: 0632 the supplier's own number
--
-- `0631` brought in a year of sales documents. This is the other side,
-- and it is not a mirror image: a bill carries TWO numbers.
--
--   * `doc_no` is ours -- the reference this company files it under.
--   * `supplier_doc_no` is theirs -- what is printed on the paper, what
--     they will quote when they chase it, and what `0628` looks at to
--     decide whether the same bill has arrived twice.
--
-- A sales document has only the first, because the paper being scanned
-- into one is this company's own. So the grouping key here is `doc_no`,
-- as before, but the DUPLICATE question is asked of `supplier_doc_no`,
-- and asked per supplier -- which is the pair `0406` never considered
-- and `0628` added `app.supplier_doc_key` for.
--
-- ---------------------------------------------------------------------
-- The duplicate check is 0628's, not a second one
--
-- `public.duplicate_purchase_documents` already answers "is this bill
-- already on the books", normalising the number so `INV-4471`,
-- `inv 4471` and `INV4471` are one invoice typed by three people. This
-- calls it rather than writing a second matcher, because two answers to
-- "have we had this before" is how a company pays a supplier twice.
--
-- It is a WARNING there and a REFUSAL here, and that is deliberate
-- rather than inconsistent. A person entering one bill can see the
-- match and judge it -- a supplier re-issuing a corrected invoice under
-- the same number is real. A file of four hundred rows has nobody
-- looking at any one of them, so the same match has to stop the import
-- and be fixed in the file.
--
-- ---------------------------------------------------------------------
-- Everything else is 0631's, for 0631's reasons
--
-- One row per LINE grouped by document number; a bad row poisons its
-- whole document; the header must agree across a group and a
-- disagreement names the row it disagrees with; drafts only, because a
-- changeover is exactly when the file is wrong; the totals come from
-- `app.calc_document_line` and `app.recalc_purchase_totals` rather than
-- from arithmetic here.
-- =====================================================================

create or replace function app.validate_purchase_transactions(
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
  v_supp_no  text;
  v_date     date;
  v_currency text;
  v_qty      numeric;
  v_price    numeric;
  v_tax      text;
  v_item     text;
  v_contact_id uuid;
  v_problem  text;
  v_heads    jsonb := '{}'::jsonb;
  v_head     jsonb;
  v_dup      record;
begin
  select base_currency into v_base
    from public.organizations where id = p_org_id;

  for r in select * from jsonb_array_elements(p_rows)
  loop
    i := i + 1;
    v_problem := null;
    v_contact_id := null;

    v_no       := app.import_text(r, 'doc_no');
    v_type     := lower(coalesce(app.import_text(r, 'doc_type'), 'bill'));
    v_contact  := app.import_text(r, 'contact_code');
    v_supp_no  := app.import_text(r, 'supplier_doc_no');
    v_date     := app.import_date(app.import_text(r, 'doc_date'));
    v_currency := upper(coalesce(app.import_text(r, 'currency'), v_base));
    v_qty      := app.import_number(app.import_text(r, 'quantity'), 1);
    v_price    := app.import_number(app.import_text(r, 'unit_price'), null);
    v_tax      := app.import_text(r, 'tax_code');
    v_item     := app.import_text(r, 'item_code');
    v_key      := lower(coalesce(v_no, ''));

    if v_contact is not null then
      select c.id into v_contact_id
        from public.contacts c
       where c.org_id = p_org_id and lower(c.code) = lower(v_contact)
         and c.deleted_at is null;
    end if;

    if v_no is null then
      v_problem := 'No document number. It is what groups the lines of '
                || 'one document together, so a row without one cannot '
                || 'belong to anything.';
    elsif v_type not in ('bill', 'purchase_credit_note',
                         'purchase_debit_note') then
      v_problem := format(
        '%s is not a kind of document this imports. Use bill, '
        'purchase_credit_note or purchase_debit_note.',
        app.import_text(r, 'doc_type'));
    elsif v_contact is null then
      v_problem := 'No supplier code.';
    elsif v_contact_id is null then
      v_problem := format(
        'There is no supplier with the code %s. Import the contacts '
        'first.', v_contact);
    elsif v_date is null then
      v_problem := format('%s has no date, or one that could not be '
                       || 'read.', v_no);
    elsif v_price is null then
      v_problem := 'No unit price on this line.';
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

    if v_problem is null then
      v_head := v_heads -> v_key;

      if v_head is null then
        if exists (
          select 1 from public.purchase_documents d
           where d.org_id = p_org_id
             and lower(d.doc_no) = v_key
             and d.deleted_at is null)
        then
          v_problem := format(
            'There is already a %s numbered %s here.', v_type, v_no);
        elsif exists (
          select 1 from public.purchase_documents d
           where d.org_id = p_org_id
             and d.import_source = 'transactions'
             and lower(d.import_ref) = v_key)
        then
          v_problem := format(
            '%s was imported before. Running the same file twice does '
            'not import it twice.', v_no);
        else
          -- 0628's question, asked of the SUPPLIER's number. A warning
          -- on a screen where somebody can judge it; a refusal here,
          -- where a file of four hundred rows has nobody looking at any
          -- one of them.
          select * into v_dup
            from public.duplicate_purchase_documents(
                   v_contact_id, v_type, v_supp_no, v_date, null, null)
           limit 1;

          if v_dup.id is not null then
            v_problem := format(
              '%s already has %s from this supplier (%s). Take it out of '
              'the file, or change the number if it really is a '
              'different document.',
              v_dup.doc_no, coalesce(v_dup.supplier_doc_no, 'this'),
              v_dup.reason);
          else
            v_heads := v_heads || jsonb_build_object(v_key,
              jsonb_build_object(
                'row', i, 'type', v_type, 'contact', lower(v_contact),
                'date', v_date, 'currency', v_currency,
                'supplier_no', coalesce(lower(v_supp_no), '')));
          end if;
        end if;
      else
        if (v_head ->> 'type') <> v_type then
          v_problem := format(
            'Row %s calls %s a %s and this row calls it a %s.',
            v_head ->> 'row', v_no, v_head ->> 'type', v_type);
        elsif (v_head ->> 'contact') <> lower(v_contact) then
          v_problem := format(
            'Row %s puts %s against supplier %s and this row puts it '
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
        -- The one a sales document has no equivalent of. Two supplier
        -- numbers under one of ours means two bills were run together,
        -- and importing them as one is a payable for the wrong money
        -- addressed to a number the supplier will not recognise.
        elsif (v_head ->> 'supplier_no')
              <> coalesce(lower(v_supp_no), '') then
          v_problem := format(
            'Row %s gives %s the supplier''s number %s and this row '
            'gives it %s.', v_head ->> 'row', v_no,
            coalesce(nullif(v_head ->> 'supplier_no', ''), '(none)'),
            coalesce(v_supp_no, '(none)'));
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

comment on function app.validate_purchase_transactions(uuid, jsonb) is
  'What is wrong with a file of purchase transaction lines, row by row. '
  'See 0632.';

revoke all on function app.validate_purchase_transactions(uuid, jsonb)
  from public, anon;
grant execute on function app.validate_purchase_transactions(uuid, jsonb)
  to authenticated, service_role;

create or replace function public.import_purchase_transactions(
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

  v_results := app.validate_purchase_transactions(p_org_id, p_rows);
  select count(*) filter (where x ->> 'status' = 'error'), count(*)
    into v_bad, v_total
    from jsonb_array_elements(v_results) x;

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
        insert into public.purchase_documents (
          org_id, doc_type, doc_no, doc_date, due_date, contact_id,
          supplier_doc_no, reference, currency, exchange_rate, status,
          import_source, import_ref, imported_at, created_by)
        values (
          p_org_id,
          lower(coalesce(app.import_text(r, 'doc_type'),
                         'bill'))::app.purchase_doc_type,
          v_no,
          app.import_date(app.import_text(r, 'doc_date')),
          app.import_date(app.import_text(r, 'due_date')),
          (select c.id from public.contacts c
            where c.org_id = p_org_id
              and lower(c.code) = lower(app.import_text(r, 'contact_code'))
              and c.deleted_at is null),
          app.import_text(r, 'supplier_doc_no'),
          app.import_text(r, 'reference'),
          upper(coalesce(app.import_text(r, 'currency'),
            (select base_currency from public.organizations
              where id = p_org_id))),
          coalesce(app.import_number(
            app.import_text(r, 'exchange_rate'), null), 1),
          'draft',
          'transactions', v_no, now(), auth.uid())
        returning id into v_doc;

        v_docs  := v_docs  || jsonb_build_object(v_key, v_doc::text);
        v_line  := 1;
        v_made  := v_made + 1;
      end if;

      insert into public.purchase_document_lines (
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

comment on function public.import_purchase_transactions(uuid, jsonb, boolean) is
  'Imports bills, purchase credit notes and purchase debit notes from '
  'one row per line, grouped by document number. Refuses a bill this '
  'supplier has already sent (0628). Creates DRAFTS and posts nothing. '
  'See 0632.';

revoke all on function public.import_purchase_transactions(uuid, jsonb, boolean)
  from public, anon;
grant execute on function public.import_purchase_transactions(
  uuid, jsonb, boolean) to authenticated, service_role;
