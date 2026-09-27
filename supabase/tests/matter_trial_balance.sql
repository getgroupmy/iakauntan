-- =====================================================================
-- iAkauntan :: a trial balance for one matter
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/matter_trial_balance.sql
--
-- `0687`. A law firm keeps the firm's books and one set per matter, and
-- the second is a statutory obligation rather than a view over the
-- first. `0021` built the client ledger; nothing put the matter where
-- the REST of the ledger could see it, so a bill from a searcher or a
-- journal correcting last month landed in the firm's books and stopped.
--
-- Three things have to be true, and two of them are arithmetic that
-- would look perfectly plausible if it were wrong:
--
--   * ONE MATTER'S LINES, AND NO OTHER'S. The whole point. A report
--     that quietly included the matter next to it would still balance,
--     still look like a trial balance, and be wrong in a way nobody
--     spots until a client asks.
--   * AND NOT THE FIRM'S. Lines with no matter on them -- rent,
--     salaries, the firm's own bank charges -- are the firm's and must
--     not appear under a client's heading.
--   * NO OPENING BALANCE OFF `accounts`. `report_trial_balance` adds
--     `accounts.opening_balance`, which is what the FIRM brought
--     forward when the books were opened. It belongs to no matter.
--     Carrying it here would put the firm's entire opening position
--     onto whichever matter was asked for, and the report would still
--     add up.
--
-- And one that is not arithmetic at all: another firm's matter id must
-- not be accepted onto this firm's ledger line. RLS scopes a row by its
-- own `org_id` and says nothing about the ids it carries.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A posted, balanced entry with both lines against one matter.
create or replace function pg_temp.post_to(
  p_org uuid, p_matter uuid, p_debit uuid, p_credit uuid,
  p_amount numeric, p_on date default current_date)
returns uuid language plpgsql as $$
declare v_entry uuid;
begin
  insert into public.gl_entries
    (org_id, entry_no, entry_date, description, status)
  values (p_org, 'T-' || substr(gen_random_uuid()::text, 1, 8), p_on,
          'test', 'posted')
  returning id into v_entry;
  insert into public.gl_lines
    (org_id, entry_id, line_no, account_id, debit, credit, matter_id)
  values (p_org, v_entry, 1, p_debit, p_amount, 0, p_matter),
         (p_org, v_entry, 2, p_credit, 0, p_amount, p_matter);
  return v_entry;
end;
$$;

do $$
declare
  v_owner  uuid := pg_temp.test_user();
  v_org    uuid;
  v_other  uuid;
  v_c1     uuid;
  v_m1     uuid;
  v_m2     uuid;
  v_cash   uuid;
  v_fees   uuid;
  v_n      integer;
  v_dr     numeric;
  v_open   numeric;
begin
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Guaman Sdn Bhd');
  perform public.setup_legal_module(v_org);

  select id into v_cash from public.accounts
   where org_id = v_org and code = '1120';
  select id into v_fees from public.accounts
   where org_id = v_org and account_type = 'revenue' limit 1;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CL1', 'Puan Aminah', 'customer') returning id into v_c1;
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_org, 'M-1', 'Sale of a house', v_c1, v_owner)
  returning id into v_m1;
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_org, 'M-2', 'A tenancy dispute', v_c1, v_owner)
  returning id into v_m2;

  -- One matter, one movement.
  perform pg_temp.post_to(v_org, v_m1, v_cash, v_fees, 500.00);
  -- The matter next door, which must not appear on M-1's report.
  perform pg_temp.post_to(v_org, v_m2, v_cash, v_fees, 900.00);
  -- And the firm's own: no matter at all.
  perform pg_temp.post_to(v_org, null, v_cash, v_fees, 7000.00);

  -- -------------------------------------------------------------------
  -- One matter's lines, and no other's
  -- -------------------------------------------------------------------
  select sum(debit) into v_dr
    from public.report_matter_trial_balance(v_org, v_m1);
  perform pg_temp.check_eq(
    'a matter''s trial balance carries only that matter''s movements',
    v_dr, 500.00);

  select sum(debit) into v_dr
    from public.report_matter_trial_balance(v_org, v_m2);
  perform pg_temp.check_eq(
    'and the matter next door has its own, untouched by the first',
    v_dr, 900.00);

  -- The firm's 7,000 is on neither. Asserted as a sum over BOTH
  -- matters rather than by reading one, because a report that leaked
  -- the firm's lines into every matter would still pass the two
  -- assertions above if it leaked them evenly.
  select coalesce(sum(t.debit), 0) into v_dr
    from (select * from public.report_matter_trial_balance(v_org, v_m1)
          union all
          select * from public.report_matter_trial_balance(v_org, v_m2)) t;
  perform pg_temp.check_eq(
    'and the firm''s own lines are on neither of them', v_dr, 1400.00);

  -- -------------------------------------------------------------------
  -- It balances, which is what makes it a trial balance
  -- -------------------------------------------------------------------
  select sum(debit) - sum(credit) into v_dr
    from public.report_matter_trial_balance(v_org, v_m1);
  perform pg_temp.check_eq('and it balances', v_dr, 0.00);

  -- -------------------------------------------------------------------
  -- No opening balance off the account
  --
  -- The error that would look right. `accounts.opening_balance` is the
  -- FIRM's brought-forward figure; carried onto a matter it would put
  -- the firm's whole opening position under a client's name, and the
  -- report would still add up.
  -- -------------------------------------------------------------------
  update public.accounts set opening_balance = 25000.00
   where id = v_cash;

  select opening_balance into v_open
    from public.report_matter_trial_balance(v_org, v_m1)
   where account_id = v_cash;
  perform pg_temp.check_eq(
    'the firm''s brought-forward balance is not a matter''s',
    v_open, 0.00);

  select sum(debit) into v_dr
    from public.report_matter_trial_balance(v_org, v_m1);
  perform pg_temp.check_eq(
    'and the movements are unchanged by it', v_dr, 500.00);

  -- -------------------------------------------------------------------
  -- Only the accounts this matter has moved
  -- -------------------------------------------------------------------
  select count(*) into v_n
    from public.report_matter_trial_balance(v_org, v_m1);
  perform pg_temp.check_eq(
    'a matter''s report lists the accounts it moved, not the whole chart',
    v_n, 2);

  -- -------------------------------------------------------------------
  -- A date range still means what it means
  -- -------------------------------------------------------------------
  perform pg_temp.post_to(v_org, v_m1, v_cash, v_fees, 300.00,
                          app.today() - 400);
  select sum(debit) into v_dr
    from public.report_matter_trial_balance(
           v_org, v_m1, app.today() - 30, app.today());
  perform pg_temp.check_eq(
    'a movement from last year is not this period''s debit', v_dr, 500.00);

  select opening_balance into v_open
    from public.report_matter_trial_balance(
           v_org, v_m1, app.today() - 30, app.today())
   where account_id = v_cash;
  perform pg_temp.check_eq(
    'it is the opening balance instead, which is where it belongs',
    v_open, 300.00);

  -- -------------------------------------------------------------------
  -- A draft is not a trial balance entry
  -- -------------------------------------------------------------------
  insert into public.gl_entries
    (org_id, entry_no, entry_date, description, status)
  values (v_org, 'T-draft', current_date, 'not posted', 'draft');
  insert into public.gl_lines
    (org_id, entry_id, line_no, account_id, debit, credit, matter_id)
  select v_org, id, 1, v_cash, 999.00, 0, v_m1 from public.gl_entries
   where org_id = v_org and status = 'draft';
  select sum(debit) into v_dr
    from public.report_matter_trial_balance(v_org, v_m1);
  perform pg_temp.check_eq(
    'and an unposted entry is not on it', v_dr, 800.00);

  -- -------------------------------------------------------------------
  -- The pull an internal audit wants
  --
  -- The trial balance says where the matter stands. This says what
  -- happened, in order, so somebody can tick it against the file.
  -- -------------------------------------------------------------------
  select count(*) into v_n
    from public.report_matter_ledger(v_org, v_m1);
  -- Two entries of two lines each: the 500 and the 300 from last year.
  -- The draft is not among them and neither is M-2's or the firm's.
  perform pg_temp.check_eq(
    'the pull lists every posted line of this matter and no other',
    v_n, 4);

  select sum(debit) - sum(credit) into v_dr
    from public.report_matter_ledger(v_org, v_m1);
  perform pg_temp.check_eq('and it nets to nothing, as a ledger does',
    v_dr, 0.00);

  -- Oldest first, because an audit reads forwards. The running balance
  -- is only meaningful in that order, which is why it is computed over
  -- the report's own ordering rather than left to the caller.
  perform pg_temp.check_true(
    'oldest first',
    (select entry_date from public.report_matter_ledger(v_org, v_m1)
     limit 1) = app.today() - 400);

  -- The running balance after the last row is the matter's position.
  -- Both entries are a debit and a matching credit, so it returns to
  -- zero -- and a running balance that did NOT would mean the window
  -- was summing something other than the rows as printed.
  -- The LAST row as the report prints it. Ordered by the report's own
  -- keys, `line_no` among them -- my first version left it out, sorted
  -- by date alone, and got an arbitrary one of the two lines that
  -- share a date. Which is exactly the gap that put `line_no` on the
  -- report: a caller cannot reproduce the order without it.
  select running_balance into v_dr
    from public.report_matter_ledger(v_org, v_m1)
   order by entry_date desc, entry_no desc, line_no desc limit 1;
  perform pg_temp.check_eq(
    'and the running balance closes where the ledger does', v_dr, 0.00);

  -- What created the entry, which is the thing an audit of client money
  -- asks about before it asks about the narration.
  perform pg_temp.check_true(
    'every row says what created it',
    not exists (select 1 from public.report_matter_ledger(v_org, v_m1)
                 where source is null));

  select count(*) into v_n
    from public.report_matter_ledger(v_org, v_m2);
  perform pg_temp.check_eq(
    'and the matter next door pulls its own two lines', v_n, 2);
end $$;

-- ---------------------------------------------------------------------
-- Another firm's matter cannot be put on this firm's ledger line
--
-- RLS scopes a row by its own `org_id` and says nothing about the ids
-- it carries in its foreign key columns. `0160` closed this on
-- `gl_lines.account_id` and gave the reason it has to be closed at the
-- LINE: several posting paths build their lines as jsonb and hand them
-- to `create_gl_entry`, where reading the callers would never have
-- caught the next one.
-- ---------------------------------------------------------------------
do $$
declare
  v_owner   uuid := pg_temp.test_user();
  v_mine    uuid;
  v_theirs  uuid;
  v_their_m uuid;
  v_acct    uuid;
  v_entry   uuid;
  v_c       uuid;
begin
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.allow_many_companies();
  v_mine := pg_temp.test_org('Firm One Sdn Bhd');
  v_theirs := pg_temp.test_org('Firm Two Sdn Bhd');
  perform public.setup_legal_module(v_theirs);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_theirs, 'CL9', 'Their client', 'customer') returning id into v_c;
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_theirs, 'M-9', 'Their matter', v_c, v_owner)
  returning id into v_their_m;

  select id into v_acct from public.accounts
   where org_id = v_mine and code = '1120';
  insert into public.gl_entries
    (org_id, entry_no, entry_date, description, status)
  values (v_mine, 'T-probe', current_date, 'probe', 'draft')
  returning id into v_entry;

  perform pg_temp.check_refused(
    'a ledger line may not name another firm''s matter',
    format($q$insert into public.gl_lines
               (org_id, entry_id, line_no, account_id, debit, credit,
                matter_id)
             values (%L, %L, 1, %L, 10, 0, %L)$q$,
           v_mine, v_entry, v_acct, v_their_m),
    '%gl_lines_matter_same_org%');
end $$;

-- ---------------------------------------------------------------------
-- The matter arrives through the real posting path
--
-- `0688`. Everything above posts by inserting `gl_lines` directly,
-- which proves the reports read the column and nothing about whether
-- anything WRITES it. `app.create_gl_entry_internal` is the only
-- function in this product that inserts into `gl_lines` -- every bill,
-- expense, journal and client movement builds its lines as jsonb and
-- hands them there -- so this is the one seam that decides whether the
-- matter ever reaches a real transaction.
--
-- Three things, and the third is the one a form will hit first.
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_org   uuid;
  v_c     uuid;
  v_m     uuid;
  v_cash  uuid;
  v_fees  uuid;
  v_entry uuid;
  v_n     integer;
  v_dr    numeric;
begin
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Posting Path Sdn Bhd');
  perform public.setup_legal_module(v_org);
  -- The real posting path checks the period; the direct inserts above
  -- do not, which is one more reason this block is worth having.
  perform public.create_fiscal_year(v_org, date_trunc('year', app.today())::date);

  select id into v_cash from public.accounts
   where org_id = v_org and code = '1120';
  select id into v_fees from public.accounts
   where org_id = v_org and account_type = 'revenue' limit 1;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CL1', 'A client', 'customer') returning id into v_c;
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_org, 'M-7', 'A conveyance', v_c, v_owner) returning id into v_m;

  -- A line that names its matter keeps it.
  v_entry := app.create_gl_entry_internal(
    v_org, app.today(), 'manual',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', 250,
                         'matter_id', v_m),
      jsonb_build_object('account_id', v_fees, 'credit', 250,
                         'matter_id', v_m)),
    'A matter-tagged journal');

  select count(*) into v_n from public.gl_lines
   where entry_id = v_entry and matter_id = v_m;
  perform pg_temp.check_eq(
    'a line posted with a matter keeps it', v_n, 2);

  select sum(debit) into v_dr
    from public.report_matter_trial_balance(v_org, v_m);
  perform pg_temp.check_eq(
    'and the report built on that column sees it', v_dr, 250.00);

  -- TWO MATTERS ON ONE ENTRY, which every fixture above misses because
  -- they all tag both lines the same. A mutation sweep found it: making
  -- every line take the FIRST line's matter passed everything.
  --
  -- It is not a hypothetical shape. A transfer between client ledgers
  -- is exactly this entry -- one matter credited, another debited, no
  -- bank movement -- and under that mutant the whole transfer would
  -- post against the paying matter and the receiving one would show
  -- nothing.
  declare v_m2 uuid;
  begin
    insert into public.matters
      (org_id, matter_no, name, client_id, fee_earner)
    values (v_org, 'M-8', 'Another conveyance', v_c, v_owner)
    returning id into v_m2;

    v_entry := app.create_gl_entry_internal(
      v_org, app.today(), 'manual',
      jsonb_build_array(
        jsonb_build_object('account_id', v_cash, 'debit', 75,
                           'matter_id', v_m),
        jsonb_build_object('account_id', v_fees, 'credit', 75,
                           'matter_id', v_m2)),
      'One entry, two matters');

    select count(*) into v_n from public.gl_lines
     where entry_id = v_entry and matter_id = v_m;
    perform pg_temp.check_eq(
      'each line keeps its OWN matter, not the first line''s', v_n, 1);
    select count(*) into v_n from public.gl_lines
     where entry_id = v_entry and matter_id = v_m2;
    perform pg_temp.check_eq(
      'and the other matter gets the other line', v_n, 1);
  end;

  -- A line that names none is the firm's own, not an error.
  v_entry := app.create_gl_entry_internal(
    v_org, app.today(), 'manual',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', 900),
      jsonb_build_object('account_id', v_fees, 'credit', 900)),
    'The rent');

  select count(*) into v_n from public.gl_lines
   where entry_id = v_entry and matter_id is null;
  perform pg_temp.check_eq(
    'a line with no matter posts as the firm''s own', v_n, 2);

  -- AND THE ONE A FORM HITS FIRST. A picker that was opened and closed
  -- again sends an empty string, not an absent key. Without the
  -- `nullif`, `''::uuid` raises and the whole journal is refused --
  -- which is a screen that will not post rather than a line that is
  -- untagged.
  v_entry := app.create_gl_entry_internal(
    v_org, app.today(), 'manual',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', 10,
                         'matter_id', ''),
      jsonb_build_object('account_id', v_fees, 'credit', 10,
                         'matter_id', '')),
    'Matter picker opened and closed');

  select count(*) into v_n from public.gl_lines
   where entry_id = v_entry and matter_id is null;
  perform pg_temp.check_eq(
    'an empty matter is no matter, and does not refuse the posting',
    v_n, 2);
end $$;

rollback;
