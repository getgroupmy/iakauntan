-- =====================================================================
-- iAkauntan :: the statement as the screen reads it
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fs_export.sql
--
-- `mbrs.sql` asserts the arithmetic underneath: that the statements
-- balance, that `fs_freeze` writes figures, that what was filed stays
-- filed while the ledger moves on, that the deadlines are calendar
-- months and that the audit exemption looks at three years. All of it
-- reads `fs_prepare` and `fs_figures` directly.
--
-- `fs_export` is what the screen and the export actually call, and it
-- was named by no test. It has one decision of its own, and everything
-- a director sees rests on it: a draft is recomputed from the ledger
-- every time it is opened, and anything past draft comes from the
-- figures that were frozen. Get that backwards and a set of accounts
-- already filed with SSM redraws itself from today's ledger — a
-- statement that disagrees with the one the registrar holds, shown to
-- the person who signed it.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.mbrs_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'mbrs', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  return v_org;
end $$;

create or replace function pg_temp.jv(
  p_org uuid, p_no text, p_date date, p_dr uuid, p_cr uuid, p_amount numeric)
returns void language plpgsql as $$
declare v_entry uuid;
begin
  insert into public.gl_entries
    (org_id, entry_no, entry_date, source, status, description)
  values (p_org, p_no, p_date, 'manual', 'posted', p_no)
  returning id into v_entry;
  insert into public.gl_lines (org_id, entry_id, line_no, account_id, debit, credit)
  values (p_org, v_entry, 1, p_dr, p_amount, 0),
         (p_org, v_entry, 2, p_cr, 0, p_amount);
end $$;

create or replace function pg_temp.acct(p_org uuid, p_subtype text)
returns uuid language sql as $$
  select id from public.accounts
   where org_id = p_org and account_subtype = p_subtype::app.account_subtype
     and not is_group
   order by code limit 1;
$$;

-- A year with figures in it, ready to freeze.
create or replace function pg_temp.a_filing(p_org uuid)
returns uuid language plpgsql as $$
declare v_id uuid; v_bank uuid; v_cap uuid; v_sales uuid; v_exp uuid;
begin
  perform public.create_fiscal_year(p_org, date '2025-01-01');
  v_bank  := pg_temp.acct(p_org, 'bank');
  v_cap   := pg_temp.acct(p_org, 'share_capital');
  v_sales := pg_temp.acct(p_org, 'sales');
  v_exp   := pg_temp.acct(p_org, 'operating_expense');

  perform pg_temp.jv(p_org, 'JV-1', date '2025-01-02', v_bank, v_cap, 100000);
  perform pg_temp.jv(p_org, 'JV-2', date '2025-06-30', v_bank, v_sales, 250000);
  perform pg_temp.jv(p_org, 'JV-3', date '2025-06-30', v_exp,  v_bank, 180000);

  insert into public.fs_filings
    (org_id, fy_start, fy_end, framework, audit_status, employee_count)
  values (p_org, date '2025-01-01', date '2025-12-31', 'mpers', 'unaudited', 3)
  returning id into v_id;
  return v_id;
end $$;

create or replace function pg_temp.exported(p_filing uuid, p_code text)
returns numeric language sql stable as $$
  select x.current_amount from public.fs_export(p_filing) x
   where x.element_code = p_code;
$$;

-- ---------------------------------------------------------------------
-- Before it is frozen, and after
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.mbrs_org('Exporter MBRS Sdn Bhd');
  v_filing uuid; v_exp uuid; v_bank uuid;
begin
  v_filing := pg_temp.a_filing(v_org);
  v_bank := pg_temp.acct(v_org, 'bank');
  v_exp  := pg_temp.acct(v_org, 'operating_expense');

  -- A draft is a working document. It is recomputed on every read, and
  -- it says so, because the screen puts the two states differently in
  -- front of a director about to sign.
  perform pg_temp.check_eq('a draft exports what the ledger says now',
    pg_temp.exported(v_filing, 'AdministrativeExpenses'), 180000);
  perform pg_temp.check_true('and reports itself as not frozen',
    (select bool_and(not x.is_frozen) from public.fs_export(v_filing) x));

  -- Still a draft, so a journal into the year moves what it exports.
  perform pg_temp.jv(v_org, 'JV-4', date '2025-12-31', v_exp, v_bank, 5000);
  perform pg_temp.check_eq('a draft follows the ledger',
    pg_temp.exported(v_filing, 'AdministrativeExpenses'), 185000);

  perform public.fs_freeze(v_filing);

  perform pg_temp.check_eq('once frozen it exports what was frozen',
    pg_temp.exported(v_filing, 'AdministrativeExpenses'), 185000);
  perform pg_temp.check_true('and says so',
    (select bool_and(x.is_frozen) from public.fs_export(v_filing) x));

  -- The whole point of the module, read through the function the screen
  -- actually calls. mbrs.sql asserts this against `fs_figures`; nothing
  -- asserted that `fs_export` reaches for them rather than recomputing.
  perform pg_temp.jv(v_org, 'JV-5', date '2025-12-31', v_exp, v_bank, 9000);
  perform pg_temp.check_eq('and a later correction does not move it',
    pg_temp.exported(v_filing, 'AdministrativeExpenses'), 185000);

  -- The positive control. Without this the assertion above would hold
  -- just as well if the correction had never been posted.
  perform pg_temp.check_eq('though the ledger itself has moved',
    (select amount from app.fs_figures_at(v_org, date '2025-01-01', date '2025-12-31')
      where element_code = 'AdministrativeExpenses'), 194000);
end $$;

-- ---------------------------------------------------------------------
-- The same statement, before and after
--
-- Both states show the elements that carry a figure — `fs_prepare`
-- filters on that, and `fs_freeze` writes what it returned — so
-- freezing should change the numbers' source and nothing else about the
-- page. The two branches nevertheless build the list differently, one
-- from the taxonomy outwards and one from the frozen figures inwards,
-- and they order by different columns. A statement that loses a line or
-- reshuffles itself at the moment it is filed would be noticed by the
-- director signing it and by nothing else here.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.mbrs_org('Shape MBRS Sdn Bhd');
  v_filing uuid; v_draft text[]; v_frozen text[]; v_dropped text;
  v_second uuid;
begin
  v_filing := pg_temp.a_filing(v_org);

  -- In export order, not sorted: the order is half of what is asserted.
  select array_agg(x.element_code) into v_draft
    from public.fs_export(v_filing) x;
  perform public.fs_freeze(v_filing);
  select array_agg(x.element_code) into v_frozen
    from public.fs_export(v_filing) x;

  perform pg_temp.check_eq('freezing changes the source and not the page',
    array_to_string(v_frozen, ','), array_to_string(v_draft, ','));

  -- A revised taxonomy, and the two things that stop it rewriting a
  -- filed statement.
  --
  -- SSM revises the MBRS taxonomy, and `authenticated` holds delete on
  -- `mbrs_elements`. The frozen branch of `fs_export` reaches its labels
  -- through an inner join to that table, so on the face of it an element
  -- retired after a filing was made would take that filing's line with
  -- it — silently, out of the one document in this system that may never
  -- change.
  --
  -- It cannot, and the reason is a foreign key rather than anything in
  -- the function: `fs_figures.element_code` references the taxonomy, so
  -- an element a filing has used cannot be removed at all. That is what
  -- makes the inner join sound, and it is asserted here so that dropping
  -- the constraint fails a test that says why it mattered.
  v_dropped := v_frozen[2];
  begin
    delete from public.mbrs_elements where code = v_dropped;
    raise exception 'FAIL: retired an element a filing had used';
  exception when foreign_key_violation then
    raise notice 'ok   an element a filing used cannot be retired';
  end;

  -- The way one is actually retired is `is_active`, and that is where
  -- the two branches differ on purpose. A draft is the current
  -- taxonomy, so a deactivated element leaves it. A filed statement is
  -- what was filed, so the same element stays on it.
  update public.mbrs_elements set is_active = false where code = v_dropped;
  perform pg_temp.check_true('a deactivated element stays on what was filed',
    exists (select 1 from public.fs_export(v_filing) x
             where x.element_code = v_dropped));
  perform pg_temp.check_eq('and the filing is the length it was filed at',
    (select count(*) from public.fs_export(v_filing)),
    array_length(v_frozen, 1));

  -- The positive control: the same deactivation does take it off a
  -- draft, so the assertion above is about the freeze rather than about
  -- `is_active` doing nothing.
  --
  -- The second filing is made into a variable first. Calling it inside
  -- the `exists` would run it once per candidate row — the trap
  -- `outbound_email.sql` already carries a note about — and each call
  -- would try to create the same company again.
  v_second := pg_temp.a_filing(pg_temp.mbrs_org('Draft MBRS Sdn Bhd'));
  perform pg_temp.check_true('while a draft drops it',
    not exists (select 1 from public.fs_export(v_second) x
                 where x.element_code = v_dropped));

  -- Put the taxonomy back. `mbrs_elements` has no org_id — it is one
  -- table shared by every company and by every block in this file — so a
  -- deactivation left lying here follows the transaction into the next
  -- fixture, which then cannot balance because its share capital has
  -- quietly left the statement.
  update public.mbrs_elements set is_active = true where code = v_dropped;
end $$;

-- ---------------------------------------------------------------------
-- Who may read one
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.mbrs_org('Guard MBRS Sdn Bhd');
  v_owner uuid := pg_temp.test_user();
  v_outsider uuid := pg_temp.another_user('outsider@iakauntan.test');
  v_other uuid; v_filing uuid;
begin
  v_filing := pg_temp.a_filing(v_org);

  begin
    perform * from public.fs_export(gen_random_uuid());
    raise exception 'FAIL: exported a filing that does not exist';
  exception when sqlstate 'P0002' then
    raise notice 'ok   a filing that does not exist is refused';
  end;

  -- Somebody else's accounts. These are the figures a company files with
  -- the registrar and nobody outside it has any business reading them
  -- early.
  perform pg_temp.sign_in_as(v_outsider);
  begin
    perform * from public.fs_export(v_filing);
    raise exception 'FAIL: an outsider read another company''s draft';
  exception when sqlstate '42501' then
    raise notice 'ok   another company''s draft accounts are refused';
  end;
  perform pg_temp.sign_in_as(v_owner);

  -- And on a filing that has been frozen, which is the case that tests
  -- this function rather than the one behind it.
  --
  -- The assertion above passes with `fs_export`'s own membership check
  -- deleted, because a draft is answered by `fs_prepare`, which carries
  -- the same check and raises the same 42501. The frozen branch reads
  -- `fs_figures` directly, and `fs_export` is SECURITY DEFINER, so there
  -- is nothing else between an outsider and a set of filed accounts.
  perform public.fs_freeze(v_filing);
  perform pg_temp.sign_in_as(v_outsider);
  begin
    perform * from public.fs_export(v_filing);
    raise exception 'FAIL: an outsider read another company''s filed accounts';
  exception when sqlstate '42501' then
    raise notice 'ok   and so are the filed ones';
  end;
  perform pg_temp.sign_in_as(v_owner);
end $$;

rollback;
