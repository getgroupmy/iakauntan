-- =====================================================================
-- iAkauntan :: a sub-account under one that never posted
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/sub_accounts.sql
--
-- `0655`. Asked for as a chart that can be broken down to any depth --
--
--     1120  Bank accounts
--       1120-1000  Maybank
--         1120-1000-1000  Multi Currency
--           1120-1000-1000-1000  USD
--       1120-2000  CIMB
--
-- -- with a sub-account allowed only while the parent has no
-- transactions.
--
-- The rule is what is asserted hardest, because the cost of getting it
-- wrong is invisible. Filing something under an account promotes that
-- account to a heading, and `0014`, `0016` and `0100` sum LEAVES --
-- `and not a.is_group`. A promoted account's own balance therefore
-- leaves the trial balance, the profit and loss and the cash flow
-- statement, all at once, silently, and the reports still foot.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A plain posting account, outside the seeded numbering so nothing
-- collides with the chart `test_org` lays down.
create or replace function pg_temp.sa_account(
  p_org uuid, p_code text, p_name text,
  p_type app.account_type default 'asset',
  p_subtype app.account_subtype default 'bank')
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.accounts (org_id, code, name, account_type, account_subtype)
  values (p_org, p_code, p_name, p_type, p_subtype)
  returning id into v_id;
  return v_id;
end $$;

-- The code of a child, so a failure names the number rather than a uuid.
create or replace function pg_temp.sa_code(p_id uuid)
returns text language sql stable as $$
  select code from public.accounts where id = p_id;
$$;


-- ---------------------------------------------------------------------
-- The shape the request drew
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_bank uuid;
  v_may uuid;
  v_cimb uuid;
  v_multi uuid;
  v_usd uuid;
  v_out jsonb;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Sub Akaun Sdn Bhd');
  v_bank := pg_temp.sa_account(v_org, '9120', 'Bank accounts');

  -- A posting account with nothing on it. Filing under it is allowed,
  -- and doing so turns it into a heading.
  perform pg_temp.check_eq('nothing stops a sub-account going under it',
    coalesce(app.sub_account_refusal(v_bank), '(none)'), '(none)');

  v_out := public.add_sub_account(v_bank, 'Maybank');
  v_may := (v_out ->> 'id')::uuid;
  perform pg_temp.check_eq('the first child is numbered 1000 under it',
    v_out ->> 'code', '9120-1000');
  perform pg_temp.check_eq('and the parent became a heading',
    v_out ->> 'parent_promoted', 'true');
  perform pg_temp.check_eq('which is a fact about the row, not a message',
    (select is_group::text from public.accounts where id = v_bank), 'true');
  perform pg_temp.check_eq('while the child itself posts',
    (select is_group::text from public.accounts where id = v_may), 'false');

  -- The second sibling steps by a thousand, so there is room to slot
  -- one in between without renumbering anything.
  v_cimb := (public.add_sub_account(v_bank, 'CIMB') ->> 'id')::uuid;
  perform pg_temp.check_eq('the second is 2000', pg_temp.sa_code(v_cimb),
    '9120-2000');

  -- A grandchild restarts at 1000 rather than continuing the parent's
  -- run. `1120-1000-1000`, exactly as drawn.
  v_multi := (public.add_sub_account(v_may, 'Multi Currency') ->> 'id')::uuid;
  perform pg_temp.check_eq('a grandchild starts again at 1000',
    pg_temp.sa_code(v_multi), '9120-1000-1000');
  perform pg_temp.check_eq('and Maybank is now a heading too',
    (select is_group::text from public.accounts where id = v_may), 'true');
  perform pg_temp.check_eq('but CIMB is untouched',
    (select is_group::text from public.accounts where id = v_cimb), 'false');

  -- And the depth the request asked for. The assertion that a
  -- three-level-deep child does not push its great-grandparent's next
  -- sibling number along is the one a naive `like parent || '-%'`
  -- fails.
  v_usd := (public.add_sub_account(v_multi, 'USD',
              p_currency => 'usd') ->> 'id')::uuid;
  perform pg_temp.check_eq('four levels deep',
    pg_temp.sa_code(v_usd), '9120-1000-1000-1000');
  -- Two statements, not one. A function that inserts, called inside
  -- the subquery of the select that reads the row back, cannot see its
  -- own write -- the select's snapshot was taken first.
  v_out := public.add_sub_account(v_usd, 'Cash');
  perform pg_temp.check_eq('and five',
    pg_temp.sa_code((v_out ->> 'id')::uuid),
    '9120-1000-1000-1000-1000');

  perform pg_temp.check_eq('a currency may be given, as the example asks',
    (select btrim(currency) from public.accounts where id = v_usd), 'USD');

  -- The grandchildren did not disturb the top level's numbering.
  perform pg_temp.check_eq('the next child of the top account is still 3000',
    app.next_sub_account_code(v_bank), '9120-3000');
end $$;


-- ---------------------------------------------------------------------
-- What a sub-account inherits
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_exp uuid;
  v_child uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Warisan Jenis Sdn Bhd');
  v_exp := pg_temp.sa_account(v_org, '9500', 'Travel',
                              'expense', 'operating_expense');

  v_child := (public.add_sub_account(v_exp, 'Flights') ->> 'id')::uuid;
  -- Not optional. An asset filed under an expense heading would sit on
  -- one statement by its type and another by its position.
  perform pg_temp.check_eq('a sub-account is the same kind as its parent',
    (select account_type::text from public.accounts where id = v_child),
    'expense');
  perform pg_temp.check_eq('and takes the parent''s subtype by default',
    (select account_subtype::text from public.accounts where id = v_child),
    'operating_expense');

  -- The subtype may differ, within the same statement.
  v_child := (public.add_sub_account(v_exp, 'Airport taxes',
                p_subtype => 'other_expense') ->> 'id')::uuid;
  perform pg_temp.check_eq('a different subtype is allowed',
    (select account_subtype::text from public.accounts where id = v_child),
    'other_expense');

  -- But not one from another statement. `0550`'s rule, still in force.
  perform pg_temp.check_refused(
    'and not one that belongs to a different statement',
    format('select public.add_sub_account(%L, %L, null, %L)',
           v_exp, 'Wrong', 'bank'),
    '%cannot have the subtype%', '23514');

  -- An explicit code is honoured; the generator is only what happens
  -- when nobody has an opinion.
  v_child := (public.add_sub_account(v_exp, 'Mileage',
                p_code => '9500-JALAN') ->> 'id')::uuid;
  perform pg_temp.check_eq('a typed code is kept',
    pg_temp.sa_code(v_child), '9500-JALAN');
  perform pg_temp.check_refused('and a code already in use is refused',
    format('select public.add_sub_account(%L, %L, %L)',
           v_exp, 'Again', '9500-JALAN'),
    '%already exists%', '23505');

  -- A hand-typed code must not derail the generated run, which is why
  -- the generator reads the codes rather than keeping a counter.
  perform pg_temp.check_eq('and does not disturb the generated numbering',
    app.next_sub_account_code(v_exp), '9500-3000');
end $$;


-- ---------------------------------------------------------------------
-- The rule: only under a parent that has no transactions
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_used uuid;
  v_other uuid;
  v_entry uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Sudah Berurusniaga Sdn Bhd');
  v_used := pg_temp.sa_account(v_org, '9600', 'Repairs',
                               'expense', 'operating_expense');
  v_other := pg_temp.sa_account(v_org, '9601', 'Sundry',
                                'expense', 'operating_expense');

  insert into public.gl_entries
    (org_id, entry_no, entry_date, source, status, description)
  values (v_org, 'JV-9', app.today(), 'manual', 'posted', 'A repair')
  returning id into v_entry;
  insert into public.gl_lines
    (org_id, entry_id, line_no, account_id, debit, credit)
  values (v_org, v_entry, 1, v_used, 250, 0),
         (v_org, v_entry, 2, v_other, 0, 250);

  perform pg_temp.check_refused(
    'an account with a posting cannot take a sub-account',
    format('select public.add_sub_account(%L, %L)', v_used, 'Vehicles'),
    '%has 1 posted entry%', '23514');
  -- And the reason is said, rather than left as a constraint name.
  perform pg_temp.check_refused('and the refusal says why it matters',
    format('select public.add_sub_account(%L, %L)', v_used, 'Vehicles'),
    '%would leave the trial balance%', '23514');

  -- Nothing happened to the account. A refusal that had already
  -- promoted the parent would be the worst of both.
  perform pg_temp.check_eq('and the account is still postable',
    (select is_group::text from public.accounts where id = v_used), 'false');
  perform pg_temp.check_eq('and has no children',
    (select count(*)::text from public.accounts where parent_id = v_used), '0');
end $$;


-- ---------------------------------------------------------------------
-- An opening balance counts, though it is not a posted line
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_ob uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Baki Awal Sdn Bhd');
  v_ob := pg_temp.sa_account(v_org, '9130', 'Petty cash', 'asset', 'cash');

  -- Written directly, which the API cannot do -- `0459`'s trigger
  -- refuses `authenticated` and leaves internal SQL alone, and
  -- `chart_of_accounts.sql` relies on the same thing.
  update public.accounts set opening_balance = 500 where id = v_ob;

  perform pg_temp.check_refused(
    'an opening balance is a figure too',
    format('select public.add_sub_account(%L, %L)', v_ob, 'Tin'),
    '%carries an opening balance%', '23514');

  -- Take it away and the same account accepts one, so this is a rule
  -- about the figure rather than about the account.
  update public.accounts set opening_balance = 0 where id = v_ob;
  perform pg_temp.check_eq('and with it cleared, it takes one',
    public.add_sub_account(v_ob, 'Tin') ->> 'code', '9130-1000');
end $$;


-- ---------------------------------------------------------------------
-- The one nobody would think of
-- ---------------------------------------------------------------------
--
-- `2120`, `5350` and their siblings are resolved BY NUMBER inside the
-- posting functions, every one of them with `and not is_group`.
-- Promoting one turns a working posting path into "no account found",
-- a month later, in somebody else's screen -- in payroll, or a claim,
-- or a cheque. `upsert_account` already refuses to RENUMBER these; this
-- refuses to promote them.
do $$
declare
  v_org uuid;
  v_code text;
  v_id uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kod Lejar Sdn Bhd');

  -- A seeded account whose number the ledger names, with nothing
  -- posted to it -- so the only thing standing in the way is the code.
  select a.id, a.code into v_id, v_code
    from public.accounts a
    join app.posting_account_codes() c on c.code = a.code
   where a.org_id = v_org
     and not a.is_group
     and coalesce(a.opening_balance, 0) = 0
     and not exists (select 1 from public.gl_lines l where l.account_id = a.id)
   order by a.code
   limit 1;

  perform pg_temp.check_true('the seeded chart has at least one such account',
    v_id is not null);

  perform pg_temp.check_refused(
    'a code the ledger posts to by number cannot become a heading',
    format('select public.add_sub_account(%L, %L)', v_id, 'Split'),
    '%finds by number when it posts%', '23514');
  perform pg_temp.check_eq('and it is still postable afterwards',
    (select is_group::text from public.accounts where id = v_id), 'false');
end $$;


-- ---------------------------------------------------------------------
-- A heading that is already a heading
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_head uuid;
  v_out jsonb;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Tajuk Sedia Ada Sdn Bhd');
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group)
  values (v_org, '9700', 'Overheads', 'expense', 'operating_expense', true)
  returning id into v_head;

  v_out := public.add_sub_account(v_head, 'Rent');
  perform pg_temp.check_eq('a heading takes one without ceremony',
    v_out ->> 'code', '9700-1000');
  -- `promoted` means "this changed under you", so a heading that was
  -- always a heading must answer false -- otherwise the app tells
  -- somebody their account has stopped being postable when it never
  -- was.
  perform pg_temp.check_eq('and nothing was promoted',
    v_out ->> 'parent_promoted', 'false');
end $$;


-- ---------------------------------------------------------------------
-- Who may
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_acct uuid;
  v_other uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kebenaran Carta Sdn Bhd');
  v_acct := pg_temp.sa_account(v_org, '9800', 'Sundry', 'expense',
                               'operating_expense');

  v_other := pg_temp.another_user('lain@example.test');
  perform pg_temp.sign_in_as(v_other);
  perform pg_temp.check_refused(
    'a stranger to the company may not extend its chart',
    format('select public.add_sub_account(%L, %L)', v_acct, 'Theirs'),
    '%post the books%', '42501');
  perform pg_temp.check_refused(
    'nor even ask whether it could be extended',
    format('select public.sub_account_refusal(%L)', v_acct),
    '%another company%', '42501');

  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_eq('and nothing was created',
    (select count(*)::text from public.accounts where parent_id = v_acct), '0');
  perform pg_temp.check_eq('nor promoted',
    (select is_group::text from public.accounts where id = v_acct), 'false');
end $$;

rollback;
