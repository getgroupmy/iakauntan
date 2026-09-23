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
  v_out jsonb;
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

  -- `0693`. The child goes in; the PARENT is what must not change.
  -- Its 250 is on the trial balance and promoting it would take that
  -- figure out of the reports -- which is the whole of `0655`'s
  -- reasoning and is untouched by something being nested under it.
  v_out := public.add_sub_account(v_used, 'Vehicles');
  perform pg_temp.check_eq('an account with a posting takes a sub-account',
    v_out ->> 'code', '9600-1000');

  perform pg_temp.check_eq('and is NOT promoted to a heading',
    v_out ->> 'parent_promoted', 'false');
  perform pg_temp.check_eq('and the account is still postable',
    (select is_group::text from public.accounts where id = v_used), 'false');
  perform pg_temp.check_eq('and now has the child',
    (select count(*)::text from public.accounts where parent_id = v_used), '1');

  -- Said, rather than left to be discovered. Somebody who has just
  -- nested an account under this one needs to know it is still a place
  -- money can land.
  perform pg_temp.check_eq('and the caller is told it stays postable',
    v_out ->> 'parent_stays_postable', 'true');
  perform pg_temp.check_true('and why',
    (v_out ->> 'not_promoted_because') like '%would leave the trial balance%');

  -- The figure is still reported, which is the thing all of this is
  -- protecting. It is the parent's own balance and never the sum of
  -- its children, so a child changes nothing about it.
  perform pg_temp.check_eq('and its balance is still on the trial balance',
    (select sum(debit - credit)::text from public.gl_lines
      where account_id = v_used), '250.00');
end $$;


-- ---------------------------------------------------------------------
-- An opening balance counts, though it is not a posted line
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_ob uuid;
  v_out jsonb;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Baki Awal Sdn Bhd');
  v_ob := pg_temp.sa_account(v_org, '9130', 'Petty cash', 'asset', 'cash');

  -- Written directly, which the API cannot do -- `0459`'s trigger
  -- refuses `authenticated` and leaves internal SQL alone, and
  -- `chart_of_accounts.sql` relies on the same thing.
  update public.accounts set opening_balance = 500 where id = v_ob;

  -- An opening balance is not a posted line and is still a figure on
  -- the balance sheet, so it stops the PROMOTION and not the child.
  v_out := public.add_sub_account(v_ob, 'Tin');
  perform pg_temp.check_eq('an opening balance still takes a sub-account',
    v_out ->> 'code', '9130-1000');
  perform pg_temp.check_eq('and the parent keeps its balance and its post',
    v_out ->> 'parent_stays_postable', 'true');
  perform pg_temp.check_true('for the reason the figure would be lost',
    (v_out ->> 'not_promoted_because') like '%carries an opening balance%');
  perform pg_temp.check_eq('so it is still postable',
    (select is_group::text from public.accounts where id = v_ob), 'false');

  -- Take the figure away and the same account is promoted, so this is
  -- a rule about the figure rather than about the account.
  update public.accounts set opening_balance = 0 where id = v_ob;
  v_out := public.add_sub_account(v_ob, 'Tin two');
  perform pg_temp.check_eq('and with it cleared, the parent is promoted',
    v_out ->> 'parent_promoted', 'true');
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
  v_out jsonb;
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

  -- The report `0693` came from: `1120 Bank Accounts` is one of these
  -- -- it is the bank leg `post_expense` falls back to -- and a company
  -- that wants `1120-M001 Maybank` under it was told the arrangement
  -- was impossible while already having one.
  v_out := public.add_sub_account(v_id, 'Split');
  perform pg_temp.check_true('a code the ledger posts to still takes one',
    (v_out ->> 'code') is not null);

  perform pg_temp.check_eq('and it is still postable afterwards',
    (select is_group::text from public.accounts where id = v_id), 'false');
  perform pg_temp.check_eq('which is what the caller is told',
    v_out ->> 'parent_stays_postable', 'true');
  perform pg_temp.check_true('and why',
    (v_out ->> 'not_promoted_because') like '%finds by number when it posts%');

  -- The thing that was actually being protected: the posting path goes
  -- on finding it. Every one of those lookups carries `not is_group`,
  -- so a promoted account is "no account found" a month later in
  -- somebody else's screen.
  perform pg_temp.check_eq('and the ledger can still find it by number',
    (select count(*)::text from public.accounts a
      where a.org_id = v_org and a.code = v_code and not a.is_group), '1');
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

  -- Nor does it "stay postable", which is `0693`'s other answer and
  -- means the same sort of thing: a fact about what changed. A heading
  -- was never postable, so saying it stayed that way would have the
  -- app tell somebody money can land on an account that has never
  -- taken any. Both false is the only honest pair here.
  perform pg_temp.check_eq('and it does not claim to stay postable',
    v_out ->> 'parent_stays_postable', 'false');
  perform pg_temp.check_true('and there is no reason to give',
    (v_out ->> 'not_promoted_because') is null);
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
