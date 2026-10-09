-- =====================================================================
-- iAkauntan :: 0774 a contact code in a journal file is somebody
--
-- The journal importer (`0633`) reads a customer or supplier code onto
-- each line -- the import screen maps "customer code" and "supplier
-- code" onto it -- and `app.validate_journal_rows` never looked at it.
-- `import_journals` then searched for the code and, finding nobody,
-- put nothing: a typo, or a contact deleted since the file was made,
-- went into the ledger as a line with no customer, and the preview had
-- said every row was fine.
--
-- On trade debtors that is the one line that matters. The debtors
-- account moves; the customer's ledger does not; the two disagree, and
-- the file that caused it was reported clean. The sales, purchase and
-- opening-balance importers each refuse an unknown contact already.
--
-- Answered "refuse unknown codes", 9 October 2026. An empty column is
-- still allowed -- most journal lines are on accounts that have no
-- customer -- and a code that is given has to match a contact of this
-- company that has not been deleted, in any case, as the importer
-- matches it. Found sweeping `import_journals`.
--
-- Restated from `0633`, whose text production runs exactly (identical
-- source hash on 9 October). Production had imported no journals.
-- =====================================================================

create or replace function app.validate_journal_rows(
  p_org_id uuid, p_rows jsonb)
returns jsonb
language plpgsql
stable
set search_path = public, app, pg_temp as $$
declare
  r         jsonb;
  i         integer := 0;
  v_out     jsonb := '[]'::jsonb;
  v_no      text;
  v_key     text;
  v_date    date;
  v_account text;
  v_contact text;
  v_debit   numeric;
  v_credit  numeric;
  v_problem text;
  v_acct    record;
  v_heads   jsonb := '{}'::jsonb;
  v_head    jsonb;
  v_sums    jsonb := '{}'::jsonb;
  v_rows_of jsonb := '{}'::jsonb;
  v_pair    jsonb;
  v_dr      numeric;
  v_cr      numeric;
  v_first   integer;
begin
  for r in select * from jsonb_array_elements(p_rows)
  loop
    i := i + 1;
    v_problem := null;

    v_no      := app.import_text(r, 'entry_no');
    v_date    := app.import_date(app.import_text(r, 'entry_date'));
    v_account := app.import_text(r, 'account_code');
    v_contact := app.import_text(r, 'contact_code');
    v_debit   := app.import_number(app.import_text(r, 'debit'), 0);
    v_credit  := app.import_number(app.import_text(r, 'credit'), 0);
    v_key     := lower(coalesce(v_no, ''));

    v_acct := null;
    if v_account is not null then
      select a.id, a.is_group, a.is_active into v_acct
        from public.accounts a
       where a.org_id = p_org_id and lower(a.code) = lower(v_account);
    end if;

    if v_no is null then
      v_problem := 'No entry number. It is what groups the lines of one '
                || 'journal together, so a row without one cannot belong '
                || 'to anything.';
    elsif v_date is null then
      v_problem := format('%s has no date, or one that could not be '
                       || 'read.', v_no);
    elsif v_account is null then
      v_problem := 'No account code.';
    elsif v_acct.id is null then
      v_problem := format(
        'There is no account %s in the chart. Import the chart first.',
        v_account);
    -- A group account is a heading. Posting to one puts money where no
    -- report will add it up, and the chart screen shows it under a
    -- total that does not include it.
    elsif v_acct.is_group then
      v_problem := format(
        '%s is a heading, not an account you can post to. Use one of the '
        'accounts under it.', v_account);
    elsif not v_acct.is_active then
      v_problem := format('%s has been retired.', v_account);
    elsif v_debit is null or v_credit is null then
      v_problem := 'The debit or the credit could not be read as a '
                || 'number.';
    elsif round(v_debit, 2) < 0 or round(v_credit, 2) < 0 then
      v_problem := 'A negative debit is a credit. Put it in the other '
                || 'column.';
    -- One column or the other. A line carrying both is two lines that
    -- were merged, and netting them would hide whichever is smaller
    -- from every report that looks at turnover rather than balance.
    elsif round(v_debit, 2) <> 0 and round(v_credit, 2) <> 0 then
      v_problem := 'This line has both a debit and a credit. A line is '
                || 'one or the other.';
    elsif round(v_debit, 2) = 0 and round(v_credit, 2) = 0 then
      v_problem := 'This line is for nothing.';
    -- `0774`. The column may be left empty; a code that is given has to
    -- be somebody. Dropping it was the alternative, and that posts a
    -- line on trade debtors with no customer on it -- the debtors
    -- account and the customer's ledger then disagree, and nothing said
    -- so. The other three importers already refuse it.
    elsif v_contact is not null and not exists (
      select 1 from public.contacts c
       where c.org_id = p_org_id and lower(c.code) = lower(v_contact)
         and c.deleted_at is null)
    then
      v_problem := format(
        'There is no customer or supplier with the code %s. Import the '
        'contacts first, or leave the column empty.', v_contact);
    end if;

    if v_problem is null then
      v_head := v_heads -> v_key;
      if v_head is null then
        if exists (
          select 1 from public.gl_entries e
           where e.org_id = p_org_id
             and e.import_source = 'journals'
             and lower(e.import_ref) = v_key)
        then
          v_problem := format(
            '%s was imported before. Running the same file twice does '
            'not import it twice.', v_no);
        else
          v_heads := v_heads || jsonb_build_object(v_key,
            jsonb_build_object('row', i, 'date', v_date));
        end if;
      elsif (v_head ->> 'date')::date <> v_date then
        v_problem := format(
          'Row %s dates %s %s and this row dates it %s.',
          v_head ->> 'row', v_no, v_head ->> 'date', v_date);
      end if;
    end if;

    -- Running totals for the balance check below. Only sound rows
    -- count: an entry whose lines could not be read is already refused,
    -- and adding its unreadable figures in would report a second
    -- problem about the first one.
    if v_problem is null then
      v_pair := coalesce(v_sums -> v_key,
                         jsonb_build_object('dr', 0, 'cr', 0));
      v_sums := v_sums || jsonb_build_object(v_key, jsonb_build_object(
        'dr', (v_pair ->> 'dr')::numeric + round(v_debit, 2),
        'cr', (v_pair ->> 'cr')::numeric + round(v_credit, 2)));
      if not (v_rows_of ? v_key) then
        v_rows_of := v_rows_of || jsonb_build_object(v_key, i);
      end if;
    end if;

    v_out := v_out || jsonb_build_object(
      'row', i,
      'doc_no', v_no,
      'status', case when v_problem is null then 'ok' else 'error' end,
      'problem', v_problem);
  end loop;

  -- The check that makes a journal a journal. Reported against the
  -- FIRST row of the entry, because that is the line somebody scrolls
  -- to, and with both totals and the difference, because "does not
  -- balance" sends them to add up a column by hand.
  for v_key in select jsonb_object_keys(v_sums)
  loop
    v_dr := ((v_sums -> v_key) ->> 'dr')::numeric;
    v_cr := ((v_sums -> v_key) ->> 'cr')::numeric;
    if round(v_dr, 2) <> round(v_cr, 2) then
      v_first := (v_rows_of ->> v_key)::integer;
      v_out := (
        select jsonb_agg(
          case when (x ->> 'row')::integer = v_first
               then x || jsonb_build_object(
                 'status', 'error',
                 'problem', format(
                   '%s does not balance: %s in debits against %s in '
                   'credits, %s out.',
                   x ->> 'doc_no',
                   to_char(v_dr, 'FM999G999G990D00'),
                   to_char(v_cr, 'FM999G999G990D00'),
                   to_char(abs(v_dr - v_cr), 'FM999G999G990D00')))
               else x end
          order by (x ->> 'row')::integer)
          from jsonb_array_elements(v_out) x);
    end if;
  end loop;

  return v_out;
end $$;

comment on function app.validate_journal_rows(uuid, jsonb) is
  'What is wrong with a file of journal lines, row by row, including '
  'the entries that do not balance. A contact code that is given must '
  'be a live contact of this company (`0774`); an empty one is allowed. '
  'See 0633.';
