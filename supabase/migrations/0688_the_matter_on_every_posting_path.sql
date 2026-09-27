-- =====================================================================
-- iAkauntan :: 0688 the matter, on every posting path at once
--
-- `0687` put `matter_id` on `gl_lines` and built the two reports that
-- read it. Nothing writes it.
--
-- This is the other half, and it is one line in one function.
--
-- ---------------------------------------------------------------------
-- Why one function is the whole job
--
-- `app.create_gl_entry_internal` is the only thing in this product that
-- inserts into `gl_lines`. Every posting route -- a bill, an expense, a
-- manual journal, a bank charge, a payroll run, a client account
-- movement -- builds its lines as jsonb and hands them here. `0160`
-- made the same observation for a different reason and drew the same
-- conclusion: this is where a change reaches every caller at once, and
-- where reading the callers would never have caught the next one.
--
-- So the matter travels the way `project_code` and `department_code`
-- already do. A caller that knows its matter puts `matter_id` on the
-- line; one that does not sends nothing and the line is the firm's own.
-- No caller has to be changed to keep working.
--
-- ---------------------------------------------------------------------
-- `nullif` before the cast, for `0640`'s reason
--
-- `0640` is the migration to read here. It found that the three uuid
-- fields on a line were read through `nullif(..., '')` and the two text
-- dimensions were not, and that an empty string stored as an empty
-- string becomes a nameless dimension in every report.
--
-- The uuids have the opposite failure and a louder one: `''::uuid`
-- raises, so a form that sends an empty string when nothing was picked
-- would not post an untagged line, it would refuse the entire journal.
-- That is the shape of thing a screen hits the first time somebody
-- opens the matter picker and closes it again.
--
-- ---------------------------------------------------------------------
-- What this does NOT validate
--
-- Nothing, beyond what the column already enforces -- and unlike
-- `project_code`, the column enforces plenty. `0687` gave it a
-- composite foreign key against `matters (org_id, id)`, so a line
-- naming another firm's matter is refused at the table by
-- `gl_lines_matter_same_org`, whatever route built it.
--
-- `0640` explains at length why the two text dimensions are deliberately
-- NOT keyed: an import carries the codes the old system used, and the
-- masters can legitimately arrive later or never. A matter is not that.
-- It is a record this system creates, one at a time, before any money
-- moves against it -- there is no import that needs to name a matter
-- that does not exist yet.
--
-- ---------------------------------------------------------------------
-- Restated whole from `0640`, which is what LAST defined it, with the
-- column, the value and nothing else changed.
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
      project_code, department_code, matter_id
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
      nullif(v_line ->> 'department_code', ''),
      -- `0687` put the matter on the line; this is what puts it there.
      -- `nullif` before the cast for the reason `0640` gives about the
      -- other three uuids: `''::uuid` is an error, and a form that
      -- sends an empty string when nothing was chosen would fail the
      -- whole posting rather than leave the line untagged.
      nullif(v_line ->> 'matter_id', '')::uuid);

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
