-- =====================================================================
-- iAkauntan :: 0633 the journals that came before
--
-- The last part of G6. `0631` brought in sales documents and `0632`
-- purchase documents; this is the general journal — depreciation,
-- accruals, payroll postings, the corrections somebody made in March.
--
-- ---------------------------------------------------------------------
-- This one POSTS, and the reason is not impatience
--
-- `0625`, `0628`, `0631` and `0632` each drew the same line: suggest,
-- warn, import as a draft, let a person look. This breaks it, and the
-- reason is specific rather than convenient.
--
-- **A journal has no draft state that the rest of this database
-- understands.** `gl_entries.status` permits `'draft'` and the reports
-- filter on `'posted'`, so a draft would rightly stay out of the trial
-- balance — but `app.apply_account_balance` fires on every `gl_lines`
-- row and moves `accounts.current_balance` whatever the entry's status
-- is. A "draft" journal would therefore be invisible on the trial
-- balance and fully present on the chart of accounts.
--
-- Two numbers disagreeing about the same money is precisely what `0629`
-- was written to prevent, and inventing the state here would create it.
-- Nothing else in this database has ever made a draft `gl_entry`:
-- `create_gl_entry_internal` writes `'posted'` outright, and
-- `app.refuse_unapproved_posting` treats every manual entry as a
-- posting at insert.
--
-- So this posts through `public.create_gl_entry` — the path the manual
-- journal screen uses, with the fiscal-period check, the closed-period
-- refusal, the approval gate and the balance assertion all already on
-- it. Writing a second path into `gl_lines` would be a second set of
-- those guards to keep in step.
--
-- What replaces the draft is the DRY RUN: `p_commit` false reports
-- every row and writes nothing, and a file with one bad row imports
-- none of it.
--
-- ---------------------------------------------------------------------
-- The check that makes a journal a journal
--
-- Each entry must BALANCE. `app.assert_gl_balanced` is deferred to
-- commit and would refuse the transaction, which for an import means a
-- constraint message about one entry and nothing said about the other
-- four hundred. So it is checked per entry here, first, and reported
-- with both totals and the difference — the number somebody has to go
-- and find in a spreadsheet.
--
-- ---------------------------------------------------------------------
-- The old entry number is kept, and is not `entry_no`
--
-- `create_gl_entry_internal` draws `entry_no` from this company's own
-- sequence under an advisory lock, which is right: the numbers this
-- ledger issues are its own and must not have another system's holes in
-- them. The old number goes on `reference`, where somebody looking for
-- "JV-2025-0088" will find it, and on `import_ref`, where
-- `gl_entries_import_key` makes running the same file twice a refusal.
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
  'the entries that do not balance. See 0633.';

revoke all on function app.validate_journal_rows(uuid, jsonb)
  from public, anon;
grant execute on function app.validate_journal_rows(uuid, jsonb)
  to authenticated, service_role;

create or replace function public.import_journals(
  p_org_id uuid,
  p_rows   jsonb,
  p_commit boolean default false)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_results jsonb;
  v_bad     integer;
  v_total   integer;
  v_key     text;
  v_no      text;
  v_made    integer := 0;
  v_entry   uuid;
  v_lines   jsonb;
  v_date    date;
  v_desc    text;
begin
  -- `can_post`, not `can_write`. The other two importers make drafts and
  -- ask only that somebody may write; this one puts entries in the
  -- ledger, so it asks what posting asks. `create_gl_entry` checks the
  -- same thing again for every entry, which is the guard that holds for
  -- a caller that did not come through here.
  if not app.can_post(p_org_id) then
    raise exception 'not permitted to import journals'
      using errcode = '42501';
  end if;

  v_results := app.validate_journal_rows(p_org_id, p_rows);
  select count(*) filter (where x ->> 'status' = 'error'), count(*)
    into v_bad, v_total
    from jsonb_array_elements(v_results) x;

  if p_commit and v_bad > 0 then
    raise exception
      'Nothing was imported: % of % rows have a problem. Fix the file '
      'and run it again.', v_bad, v_total using errcode = '22023';
  end if;

  if p_commit then
    for v_key, v_no, v_date, v_desc in
      select lower(app.import_text(r, 'entry_no')),
             min(app.import_text(r, 'entry_no')),
             min(app.import_date(app.import_text(r, 'entry_date'))),
             min(app.import_text(r, 'description'))
        from jsonb_array_elements(p_rows) r
       group by 1
       order by 2
    loop
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'account_id', (select a.id from public.accounts a
                               where a.org_id = p_org_id
                                 and lower(a.code)
                                     = lower(app.import_text(r, 'account_code'))),
               'description', app.import_text(r, 'description'),
               'debit', round(app.import_number(
                 app.import_text(r, 'debit'), 0), 2),
               'credit', round(app.import_number(
                 app.import_text(r, 'credit'), 0), 2),
               'contact_id', (select c.id from public.contacts c
                               where c.org_id = p_org_id
                                 and lower(c.code)
                                     = lower(app.import_text(r, 'contact_code'))
                                 and c.deleted_at is null))))
        into v_lines
        from jsonb_array_elements(p_rows) r
       where lower(app.import_text(r, 'entry_no')) = v_key;

      -- The path the manual journal screen uses: the fiscal-period
      -- check, the closed-period refusal, the approval gate and the
      -- balance assertion are all already on it.
      v_entry := public.create_gl_entry(
        p_org_id, v_date, 'manual'::app.journal_source, v_lines,
        coalesce(v_desc, 'Imported journal ' || v_no),
        null, null,
        -- The old number, where somebody looking for it will find it.
        v_no, app.base_currency(p_org_id), 1);

      -- And where running the same file twice becomes a refusal rather
      -- than a second set of entries. `gl_entries_import_key` is unique
      -- over these two, and the validator reads them.
      update public.gl_entries
         set import_source = 'journals', import_ref = v_no,
             imported_at = now()
       where id = v_entry;

      v_made := v_made + 1;
    end loop;
  end if;

  return jsonb_build_object(
    'rows', v_results,
    'total', v_total,
    'errors', v_bad,
    'documents', v_made,
    'committed', p_commit);
end $$;

comment on function public.import_journals(uuid, jsonb, boolean) is
  'Imports general journals from one row per line, grouped by entry '
  'number. Unlike the document importers this POSTS: a journal has no '
  'draft state the rest of the database understands. See 0633.';

revoke all on function public.import_journals(uuid, jsonb, boolean)
  from public, anon;
grant execute on function public.import_journals(uuid, jsonb, boolean)
  to authenticated, service_role;
