-- =====================================================================
-- iAkauntan :: 0640 an empty dimension is no dimension
--
-- One word twice, in the only function that writes `gl_lines`.
--
-- `app.create_gl_entry_internal` reads every optional field off a
-- line's JSON through `nullif(..., '')` -- `contact_id`, `item_id`,
-- `tax_code_id` -- and read the two dimension codes without it:
--
--     nullif(v_line ->> 'contact_id', '')::uuid,
--     nullif(v_line ->> 'item_id', '')::uuid,
--     nullif(v_line ->> 'tax_code_id', '')::uuid,
--     ...
--     v_line ->> 'project_code', v_line ->> 'department_code');
--
-- The three with the cast NEED it, because `''::uuid` is an error and
-- the mistake announces itself. The two text ones do not: an empty
-- string stores as an empty string, and nothing complains.
--
-- ---------------------------------------------------------------------
-- What an empty string does to a report
--
-- It becomes a dimension. `''` is not null, so a P&L grouped by
-- department reports a nameless department beside the real ones,
-- holding whichever costs happened to arrive with a blank. Filtering
-- for "no department" misses them, because they have one; filtering for
-- any named department misses them too. They are attributed to a
-- department that does not exist and cannot be selected.
--
-- Nothing in this app sends a blank today -- the journal editor omits
-- the key when nothing is chosen and the document editor sends null --
-- so this is not a live defect. It is reachable from anything that
-- builds a line from a spreadsheet cell, which is exactly what the
-- importer `0610` laid the ground for: a CSV column that is present and
-- empty reads as `''` and not as absent.
--
-- ---------------------------------------------------------------------
-- What this deliberately does NOT do
--
-- Validate that a code names a real project or department.
--
-- `gl_lines.project_code` and `department_code` are plain text with no
-- foreign key, and it is tempting to close that here, in the one
-- function every posting route goes through. It is not done, and the
-- reason is a business one rather than caution.
--
-- An import is the case that decides it. `0610` writes rows with the
-- dimension codes the old system used, and the master records those
-- codes refer to can legitimately arrive in a LATER batch -- or never,
-- for a job closed years ago whose costs still have to be reproduced.
-- A foreign key there refuses a correct import, and refuses it in the
-- middle, having already written half of it.
--
-- So the codes stay free text, and a code that names nothing shows up
-- in a report as a dimension nobody recognises -- which is visible and
-- correctable, rather than an import that stops. If that is ever
-- revisited, the decision belongs to the whole ledger and not to one
-- caller: `post_manual_journal` validating its own lines while every
-- other route did not would read as a guarantee that is not one.
--
-- Restated whole from what is applied, with the two `nullif`s added and
-- nothing else changed.
-- =====================================================================

create or replace function app.create_gl_entry_internal(
  p_org_id uuid,
  p_entry_date date,
  p_source app.journal_source,
  p_lines jsonb,
  p_description text DEFAULT NULL::text,
  p_source_table text DEFAULT NULL::text,
  p_source_id uuid DEFAULT NULL::uuid,
  p_reference text DEFAULT NULL::text,
  p_currency character DEFAULT 'MYR'::bpchar,
  p_exchange_rate numeric DEFAULT 1)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$

declare
  v_entry_id uuid; v_period_id uuid; v_status text; v_line jsonb;
  v_no integer := 0; v_debit numeric(18,2) := 0; v_credit numeric(18,2) := 0;
  v_base character(3) := app.base_currency(p_org_id);
  v_foreign boolean;
  v_rate numeric(18,8) := coalesce(p_exchange_rate, 1);
  v_ln_debit numeric(18,2); v_ln_credit numeric(18,2);
  v_fc_debit numeric(18,2); v_fc_credit numeric(18,2);
begin
  v_period_id := app.period_for_date(p_org_id, p_entry_date);
  if v_period_id is null then
    raise exception
      'No fiscal period covers %. Create the fiscal year before posting to it.',
      p_entry_date using errcode = '23514';
  end if;

  select status into v_status from public.fiscal_periods where id = v_period_id;
  if v_status <> 'open' then
    raise exception 'Fiscal period for % is %', p_entry_date, v_status using errcode = '23514';
  end if;

  -- A foreign entry with no usable rate would post zeroes and balance,
  -- which is the worst way to be wrong.
  v_foreign := p_currency is not null and p_currency <> v_base;
  if v_foreign and v_rate <= 0 then
    raise exception 'A % entry needs an exchange rate; got %',
      p_currency, p_exchange_rate using errcode = '23514';
  end if;

  insert into public.gl_entries (
    org_id, entry_no, entry_date, fiscal_period_id, source,
    source_table, source_id, description, reference,
    currency, exchange_rate, status, posted_at, posted_by, created_by
  ) values (
    p_org_id, app.next_document_number_internal(p_org_id, 'journal'),
    p_entry_date, v_period_id, p_source, p_source_table, p_source_id,
    p_description, p_reference, p_currency, v_rate,
    'posted', now(), auth.uid(), auth.uid()
  ) returning id into v_entry_id;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    v_ln_debit  := round(coalesce((v_line ->> 'debit')::numeric, 0), 2);
    v_ln_credit := round(coalesce((v_line ->> 'credit')::numeric, 0), 2);

    if not v_foreign then
      -- Nothing foreign about it. Left at zero rather than repeating the
      -- base amount, so a non-zero fc figure always means "this line was
      -- in another currency".
      v_fc_debit := 0;
      v_fc_credit := 0;
    else
      v_fc_debit := round(coalesce((v_line ->> 'fc_debit')::numeric,
                                   v_ln_debit / v_rate), 2);
      v_fc_credit := round(coalesce((v_line ->> 'fc_credit')::numeric,
                                    v_ln_credit / v_rate), 2);
    end if;

    insert into public.gl_lines (
      org_id, entry_id, line_no, account_id, description, debit, credit,
      fc_debit, fc_credit,
      currency, exchange_rate, contact_id, item_id, tax_code_id, tax_amount,
      project_code, department_code
    ) values (
      p_org_id, v_entry_id, v_no,
      (v_line ->> 'account_id')::uuid, v_line ->> 'description',
      v_ln_debit, v_ln_credit, v_fc_debit, v_fc_credit,
      p_currency, v_rate,
      nullif(v_line ->> 'contact_id', '')::uuid,
      nullif(v_line ->> 'item_id', '')::uuid,
      nullif(v_line ->> 'tax_code_id', '')::uuid,
      round(coalesce((v_line ->> 'tax_amount')::numeric, 0), 2),
      nullif(v_line ->> 'project_code', ''),
      nullif(v_line ->> 'department_code', ''));

    v_debit := v_debit + v_ln_debit;
    v_credit := v_credit + v_ln_credit;
  end loop;

  if v_debit <> v_credit then
    raise exception 'Journal does not balance: debits %, credits %', v_debit, v_credit
      using errcode = '23514';
  end if;
  return v_entry_id;
end; 
$function$;
