-- =====================================================================
-- iAkauntan :: 0637 the layout an accountant signs off
--
-- G8 on the AutoCount list: customisable P&L and Balance Sheet layouts
-- with formula rows. The verdict is accurate, which after six wrong
-- ones is worth saying: `report_spec.dart` composes the sections in
-- Dart, the sections are fixed, and no user can change them.
--
--     Revenue / Cost of Sales / Gross profit / Expenses / Net profit
--
-- That is one opinion about a P&L. It is a reasonable one and it is
-- wrong for plenty of real sets of accounts: a firm that wants EBITDA
-- as a line, a manufacturer that wants factory overhead separated from
-- administrative, a company whose auditor asks for "Other income"
-- above the operating line rather than below it.
--
-- ---------------------------------------------------------------------
-- The composition moves into the database
--
-- Today the screen and the PDF share `report_spec.dart`, which is the
-- right instinct -- one composition, two renderers. But a LAYOUT is
-- data, and the moment a user can edit it the arithmetic that turns
-- accounts into a signed-off P&L stops being presentation and becomes
-- a rule. CLAUDE.md's first line is that the database is the
-- application, and a gross profit computed in Dart is a rule enforced
-- nowhere.
--
-- So `report_with_layout` returns ROWS THAT ARE ALREADY COMPOSED --
-- label, amount, kind, depth -- and both renderers draw what they are
-- given. The built-in layout is expressed in the same shape as a
-- custom one and seeded per company on demand, so there is exactly one
-- code path and the default is not a special case that drifts.
--
-- ---------------------------------------------------------------------
-- A formula is a list of signed references, not an expression
--
-- The obvious design is a text column holding `revenue - cost_of_sales`
-- and an evaluator. This does not do that, deliberately.
--
-- An expression needs a parser; a parser in SQL over user-supplied text
-- is a hazard with no upside here, and precedence bugs in a figure
-- somebody signs are the worst kind of bug to find late. What real
-- layouts actually need is addition and subtraction of rows already
-- computed above:
--
--     gross profit  = revenue - cost of sales
--     net profit    = gross profit - expenses
--     total assets  = current assets + fixed assets
--
-- So a formula row carries a jsonb array of `{"row": <key>, "sign": 1}`.
-- No parsing, no precedence, no injection, and the thing a user builds
-- on screen is the thing stored. Multiplication and division are NOT
-- supported and their absence is the design: a ratio is not a line of
-- a P&L, it is a different report.
--
-- A formula may only reference rows ABOVE it, enforced by
-- `app.layout_rows_resolve` walking in `sort_order` and refusing a
-- forward reference. That is what makes a cycle impossible without a
-- cycle check: you cannot refer to what has not been computed.
--
-- ---------------------------------------------------------------------
-- What a section selects
--
-- By account TYPE, by SUBTYPE, or by naming accounts outright. A code
-- RANGE is deliberately absent: account codes here are text and a
-- company may renumber its chart, so a layout pinned to '5000'-'5999'
-- silently empties the day somebody does. Naming accounts survives a
-- renumbering because it holds ids.
-- =====================================================================

create type app.report_kind as enum ('profit_loss', 'balance_sheet');

create type app.layout_row_kind as enum (
  -- Accounts matching the selector, listed, and their total.
  'section',
  -- A figure computed from rows above it.
  'formula',
  -- A heading with nothing under it, for a layout that wants one.
  'heading'
);

-- What a row of a report is drawn from. A composite type rather than
-- a temporary table because `report_with_layout` is STABLE, and
-- PostgREST runs a STABLE function in a READ ONLY transaction where
-- `create temporary table` fails with 25006 -- see `0531` and
-- `scripts/check_stable_writers.py`. Gathered once into an array and
-- read many times.
create type app.account_balance as (
  account_id uuid,
  code text,
  name text,
  account_type app.account_type,
  account_subtype app.account_subtype,
  amount numeric
);

create table public.report_layouts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,

  kind app.report_kind not null,
  name text not null,

  -- The one this company uses for this report. At most one per kind,
  -- by partial unique index rather than by trigger, so two concurrent
  -- writes cannot both win.
  is_active boolean not null default false,

  -- True for the layout this migration seeds. It may be edited like
  -- any other -- the flag is so a screen can say "this is the standard
  -- one" and offer to start again from it, not a licence to refuse.
  is_builtin boolean not null default false,

  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,

  unique (org_id, id)
);

create unique index report_layouts_one_active
  on public.report_layouts (org_id, kind)
  where is_active and deleted_at is null;

create unique index report_layouts_name_key
  on public.report_layouts (org_id, kind, lower(name))
  where deleted_at is null;

create index report_layouts_org_idx
  on public.report_layouts (org_id, kind)
  where deleted_at is null;

comment on table public.report_layouts is
  'A company''s own P&L or Balance Sheet layout. The built-in one is '
  'seeded in the same shape as a custom one so there is one code path '
  'rather than a default that drifts. 0637.';

create table public.report_layout_rows (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  layout_id uuid not null,

  -- What a formula row refers to. Stable across a rename, which is the
  -- point of having it at all.
  row_key text not null,
  kind app.layout_row_kind not null,
  label text not null,
  sort_order integer not null,

  -- Indentation on the page. Presentation, but it belongs with the
  -- row rather than being inferred by a renderer that would have to
  -- guess.
  depth smallint not null default 0 check (depth between 0 and 4),
  emphasise boolean not null default false,

  -- Whether the accounts under a section are listed or only totalled.
  -- An accountant's P&L often shows "Administrative expenses" as one
  -- figure with the detail in a note.
  show_accounts boolean not null default true,

  -- A `section` selects accounts three ways, and exactly one of them.
  account_types app.account_type[],
  account_subtypes app.account_subtype[],
  account_ids uuid[],

  -- A `formula` is [{"row": "<row_key>", "sign": 1 | -1}, ...].
  formula jsonb,

  created_at timestamptz not null default now(),

  unique (layout_id, row_key),
  unique (layout_id, sort_order) deferrable initially deferred,

  constraint report_layout_rows_layout_same_org
    foreign key (org_id, layout_id)
    references public.report_layouts (org_id, id) on delete cascade,

  -- A section selects something; a formula computes something; a
  -- heading does neither. Said as a constraint because a section that
  -- selects nothing renders as a heading with no accounts and looks
  -- like a bug in the data rather than in the layout.
  constraint report_layout_rows_shape check (
    case kind
      when 'section' then
        formula is null
        and (coalesce(array_length(account_types, 1), 0)
           + coalesce(array_length(account_subtypes, 1), 0)
           + coalesce(array_length(account_ids, 1), 0)) > 0
      when 'formula' then
        account_types is null and account_subtypes is null
        and account_ids is null
        and formula is not null
        and jsonb_typeof(formula) = 'array'
        and jsonb_array_length(formula) > 0
      when 'heading' then
        formula is null and account_types is null
        and account_subtypes is null and account_ids is null
    end
  )
);

create index report_layout_rows_layout_idx
  on public.report_layout_rows (layout_id, sort_order);

comment on column public.report_layout_rows.formula is
  'For a formula row: [{"row": "<row_key>", "sign": 1|-1}, ...], '
  'referring only to rows ABOVE this one. A list of signed references '
  'rather than an expression, so there is no parser and no precedence '
  'to get wrong in a figure somebody signs. 0637.';

comment on column public.report_layout_rows.row_key is
  'What a formula refers to. Stable across a rename of the label, '
  'which is the whole reason it exists.';

alter table public.report_layouts enable row level security;
alter table public.report_layout_rows enable row level security;

create policy report_layouts_select on public.report_layouts
  for select to authenticated using (app.is_org_member(org_id));
create policy report_layout_rows_select on public.report_layout_rows
  for select to authenticated using (app.is_org_member(org_id));

grant select on public.report_layouts to authenticated;
grant select on public.report_layout_rows to authenticated;
revoke all on public.report_layouts from anon;
revoke all on public.report_layout_rows from anon;

create trigger set_updated_at before update on public.report_layouts
  for each row execute function app.set_updated_at();


-- The feed, because a layout decides what a signed P&L says and a
-- colleague with the report open should be told it moved. Safe to
-- attach precisely because nothing on a READ path writes these tables
-- -- see the note on `app.builtin_layout_rows` below, which is the
-- reason the built-in layout is not stored until somebody asks.
create trigger live_change_insert after insert on public.report_layouts
  referencing new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_update after update on public.report_layouts
  referencing old table as old_rows new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_delete after delete on public.report_layouts
  referencing old table as old_rows
  for each statement execute function app.note_live_change();

create trigger live_change_insert after insert on public.report_layout_rows
  referencing new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_update after update on public.report_layout_rows
  referencing old table as old_rows new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_delete after delete on public.report_layout_rows
  referencing old table as old_rows
  for each statement execute function app.note_live_change();

-- ---------------------------------------------------------------------
-- The built-in layout, as rows nobody stores
--
-- The first draft of this migration seeded the standard layout into
-- the tables the first time a report was opened. `live_change_feed.sql`
-- refused it, and was right to: CLAUDE.md's rule is that a read path
-- does not write, and a P&L is the most-read screen in the product.
-- Opening one would have written five rows and woken every colleague's
-- feed to announce a layout nobody chose.
--
-- So the standard layout is a SET-RETURNING FUNCTION rather than a
-- seed. `report_with_layout` reads stored rows when a company has a
-- layout and these when it does not, through the same loop and the
-- same arithmetic -- so there is still one composition path, which was
-- the point of storing it. `create_layout_from_builtin` materialises
-- them, once, when somebody actually opens the builder.
--
-- The test asserts the two agree rather than trusting that they do.
-- ---------------------------------------------------------------------
create or replace function app.builtin_layout_rows(p_kind app.report_kind)
returns table (
  row_key text, kind app.layout_row_kind, label text, sort_order integer,
  depth smallint, emphasise boolean, show_accounts boolean,
  account_types app.account_type[],
  account_subtypes app.account_subtype[],
  account_ids uuid[], formula jsonb)
language sql immutable
set search_path = public, app, pg_temp as $$
  select * from (values
    ('revenue', 'section'::app.layout_row_kind, 'Revenue', 10, 0::smallint,
     false, true, array['revenue']::app.account_type[],
     null::app.account_subtype[], null::uuid[], null::jsonb),
    ('cost_of_sales', 'section', 'Cost of Sales', 20, 0::smallint, false, true,
     null, array['cost_of_sales']::app.account_subtype[], null, null),
    ('gross_profit', 'formula', 'Gross profit', 30, 0::smallint, false, false,
     null, null, null,
     '[{"row": "revenue", "sign": 1}, {"row": "cost_of_sales", "sign": -1}]'::jsonb),
    ('expenses', 'section', 'Expenses', 40, 0::smallint, false, true, null,
     -- Every expense subtype EXCEPT cost of sales, named rather than
     -- expressed as "not cost_of_sales": a subtype added to the enum
     -- later would otherwise appear in a company's Expenses block
     -- without anybody having chosen it.
     array['operating_expense', 'payroll_expense', 'depreciation_expense',
           'finance_cost', 'tax_expense',
           'other_expense']::app.account_subtype[], null, null),
    ('net_profit', 'formula', 'Net profit', 50, 0::smallint, true, false,
     null, null, null,
     '[{"row": "gross_profit", "sign": 1}, {"row": "expenses", "sign": -1}]'::jsonb)
  ) as r(row_key, kind, label, sort_order, depth, emphasise, show_accounts,
         account_types, account_subtypes, account_ids, formula)
  where p_kind = 'profit_loss'
  union all
  select * from (values
    ('assets', 'section'::app.layout_row_kind, 'Assets', 10, 0::smallint,
     false, true, array['asset']::app.account_type[],
     null::app.account_subtype[], null::uuid[], null::jsonb),
    ('liabilities', 'section', 'Liabilities', 20, 0::smallint, false, true,
     array['liability']::app.account_type[], null, null, null),
    ('equity', 'section', 'Equity', 30, 0::smallint, false, true,
     array['equity']::app.account_type[], null, null, null),
    ('difference', 'formula', 'Assets less liabilities and equity', 40,
     0::smallint, true, false, null, null, null,
     '[{"row": "assets", "sign": 1}, {"row": "liabilities", "sign": -1},
       {"row": "equity", "sign": -1}]'::jsonb)
  ) as r(row_key, kind, label, sort_order, depth, emphasise, show_accounts,
         account_types, account_subtypes, account_ids, formula)
  where p_kind = 'balance_sheet'
  order by 4;
$$;

comment on function app.builtin_layout_rows(app.report_kind) is
  'The standard layout, as rows rather than as stored data, so that '
  'opening a report does not WRITE one. Same shape as '
  'report_layout_rows, read through the same loop. 0637.';

revoke all on function app.builtin_layout_rows(app.report_kind)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Composing a report from a layout
--
-- The arithmetic, in one place. Both renderers draw what comes back.
--
-- Rows are walked in `sort_order`, and a formula may only refer to a
-- key already computed. That one rule is what makes a cycle impossible:
-- there is no way to refer forwards, so there is nothing to detect. A
-- forward reference RAISES rather than reading as zero, because a Net
-- profit line that silently omitted Gross profit would be a wrong
-- figure on a signed document and nothing would say so.
-- ---------------------------------------------------------------------
create or replace function public.report_with_layout(
  p_org_id uuid,
  p_kind app.report_kind,
  p_from date default null,
  p_to date default null,
  p_layout_id uuid default null,
  p_project_code text default null,
  p_department_code text default null)
returns table (
  row_key text,
  kind app.layout_row_kind,
  label text,
  depth smallint,
  emphasise boolean,
  amount numeric,
  account_code text,
  account_name text,
  sort_order integer,
  line_no integer)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_layout uuid;
  v_row    record;
  v_acct   record;
  v_total  numeric(18, 2);
  v_ref    jsonb;
  v_seen   jsonb := '{}'::jsonb;
  v_line   integer;
  v_balances app.account_balance[];
  -- `current_date` is UTC, and a Malaysian business day is eight hours
  -- ahead of it: at 7am in Kuala Lumpur on the 1st, `current_date` is
  -- still the 31st and the report would stop a day short. `utc_is_not_
  -- today.sql` refuses the default outright, which is how this was
  -- caught rather than reasoned about.
  v_to     date := coalesce(p_to, app.today());
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  -- A balance sheet for one project is not a thing this schema can
  -- answer: a cumulative position needs every line ever posted, and
  -- the opening balances carry no dimension. Refusing says so;
  -- ignoring it would return a figure that balances and is wrong,
  -- which is the worst way to be wrong.
  if p_kind = 'balance_sheet'
     and (p_project_code is not null or p_department_code is not null) then
    raise exception
      'A balance sheet cannot be filtered by project or department: '
      'opening balances carry neither.' using errcode = '0A000';
  end if;

  if p_layout_id is not null then
    select l.id into v_layout from public.report_layouts l
     where l.id = p_layout_id and l.org_id = p_org_id
       and l.deleted_at is null;
    if v_layout is null then
      raise exception 'Layout % not found', p_layout_id using errcode = 'P0002';
    end if;
  else
    select l.id into v_layout from public.report_layouts l
     where l.org_id = p_org_id and l.kind = p_kind
       and l.is_active and l.deleted_at is null;
  end if;

  -- The balances every row is drawn from, gathered ONCE into an array.
  -- Not a temporary table: this function is STABLE, PostgREST runs a
  -- STABLE function in a READ ONLY transaction, and `create temporary
  -- table` there fails with 25006 -- so the report would not have run
  -- from the app at all.
  if p_kind = 'profit_loss' then
    select array_agg(b::app.account_balance) into v_balances from (
      select a.id, a.code, a.name, a.account_type, a.account_subtype,
             round(sum(case when a.account_type = 'revenue'
                            then l.credit - l.debit
                            else l.debit - l.credit end), 2)
        from public.gl_lines l
        join public.gl_entries e on e.id = l.entry_id
        join public.accounts a on a.id = l.account_id
       where l.org_id = p_org_id
         and e.status = 'posted'
         and (p_from is null or e.entry_date >= p_from)
         and e.entry_date <= v_to
         and (p_project_code is null or l.project_code = p_project_code)
         and (p_department_code is null
              or l.department_code = p_department_code)
       group by a.id, a.code, a.name, a.account_type, a.account_subtype
    ) b;
  else
    -- A balance sheet is cumulative to a date, so `p_from` is ignored
    -- rather than applied: a balance sheet "from March" is not a
    -- thing, and silently honouring it would produce a figure that
    -- balances and is wrong.
    select array_agg(b::app.account_balance) into v_balances from (
      select a.id, a.code, a.name, a.account_type, a.account_subtype,
             round(sum(case when a.account_type in ('asset', 'expense')
                            then l.debit - l.credit
                            else l.credit - l.debit end), 2)
        from public.gl_lines l
        join public.gl_entries e on e.id = l.entry_id
        join public.accounts a on a.id = l.account_id
       where l.org_id = p_org_id
         and e.status = 'posted'
         and e.entry_date <= v_to
       group by a.id, a.code, a.name, a.account_type, a.account_subtype
    ) b;
  end if;

  -- A company with no posted entries aggregates to NULL, and `unnest`
  -- of a null array is not an empty set -- it is an error waiting in
  -- the first section. Every layout row still renders, at zero.
  v_balances := coalesce(v_balances, array[]::app.account_balance[]);

  for v_row in
    -- Stored rows where the company has a layout, the standard ones
    -- where it has not. One loop, one set of arithmetic, and opening a
    -- report writes nothing.
    select r.row_key, r.kind, r.label, r.sort_order, r.depth, r.emphasise,
           r.show_accounts, r.account_types, r.account_subtypes,
           r.account_ids, r.formula
      from public.report_layout_rows r
     where v_layout is not null and r.layout_id = v_layout
    union all
    select b.row_key, b.kind, b.label, b.sort_order, b.depth, b.emphasise,
           b.show_accounts, b.account_types, b.account_subtypes,
           b.account_ids, b.formula
      from app.builtin_layout_rows(p_kind) b
     where v_layout is null
     order by 4
  loop
    if v_row.kind = 'formula' then
      v_total := 0;
      for v_ref in select * from jsonb_array_elements(v_row.formula) loop
        if not (v_seen ? (v_ref ->> 'row')) then
          raise exception
            'Row "%" refers to "%", which is not above it. A formula may '
            'only use rows already computed.',
            v_row.row_key, v_ref ->> 'row' using errcode = '23514';
        end if;
        v_total := v_total
                 + coalesce((v_ref ->> 'sign')::numeric, 1)
                   * (v_seen ->> (v_ref ->> 'row'))::numeric;
      end loop;
    elsif v_row.kind = 'heading' then
      v_total := null;
    else
      select coalesce(sum(b.amount), 0) into v_total
        from unnest(v_balances) b
       where (v_row.account_types is null
              or b.account_type = any(v_row.account_types))
         and (v_row.account_subtypes is null
              or b.account_subtype = any(v_row.account_subtypes))
         and (v_row.account_ids is null
              or b.account_id = any(v_row.account_ids));
    end if;

    if v_row.kind <> 'heading' then
      v_seen := v_seen || jsonb_build_object(v_row.row_key, v_total);
    end if;

    row_key := v_row.row_key; kind := v_row.kind; label := v_row.label;
    depth := v_row.depth; emphasise := v_row.emphasise; amount := v_total;
    account_code := null; account_name := null;
    sort_order := v_row.sort_order; line_no := 0;
    return next;

    -- The accounts under a section, after its total, numbered so a
    -- renderer keeps them together without re-sorting. A zero balance
    -- is left out: a P&L listing every account a company has ever
    -- opened is a list nobody reads.
    if v_row.kind = 'section' and v_row.show_accounts then
      v_line := 0;
      for v_acct in
        select b.amount, b.code, b.name from unnest(v_balances) b
         where (v_row.account_types is null
                or b.account_type = any(v_row.account_types))
           and (v_row.account_subtypes is null
                or b.account_subtype = any(v_row.account_subtypes))
           and (v_row.account_ids is null
                or b.account_id = any(v_row.account_ids))
           and b.amount <> 0
         order by b.code
      loop
        v_line := v_line + 1;
        row_key := v_row.row_key; kind := v_row.kind; label := v_acct.name;
        depth := (v_row.depth + 1)::smallint; emphasise := false;
        amount := v_acct.amount; account_code := v_acct.code;
        account_name := v_acct.name;
        sort_order := v_row.sort_order; line_no := v_line;
        return next;
      end loop;
    end if;
  end loop;
end;
$$;

comment on function public.report_with_layout(
  uuid, app.report_kind, date, date, uuid, text, text) is
  'A P&L or Balance Sheet composed from the company''s layout: one row '
  'per section, formula and account, already totalled. Both the screen '
  'and the PDF draw what this returns, so the arithmetic on a document '
  'somebody signs lives in one place. Reads only. 0637.';

revoke all on function public.report_with_layout(
  uuid, app.report_kind, date, date, uuid, text, text) from public, anon;
grant execute on function public.report_with_layout(
  uuid, app.report_kind, date, date, uuid, text, text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Making one
--
-- A company starts from the standard layout rather than a blank page.
-- A blank P&L builder is a page nobody finishes: the standard layout is
-- right for most companies and what they want is usually one change to
-- it.
-- ---------------------------------------------------------------------
create or replace function public.create_layout_from_builtin(
  p_org_id uuid, p_kind app.report_kind, p_name text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_id uuid; v_name text;
begin
  if not app.can_write(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  v_name := coalesce(nullif(trim(p_name), ''),
                     case p_kind when 'profit_loss' then 'Profit & loss'
                                 else 'Balance sheet' end);

  -- Becoming active means the previous active one stops being, and the
  -- partial index refuses two -- so it is cleared first, in the same
  -- transaction, and a failure below leaves the old one standing.
  update public.report_layouts set is_active = false
   where org_id = p_org_id and kind = p_kind and is_active
     and deleted_at is null;

  insert into public.report_layouts
    (org_id, kind, name, is_active, is_builtin, created_by)
  values (p_org_id, p_kind, v_name, true, false, auth.uid())
  returning id into v_id;

  insert into public.report_layout_rows
    (org_id, layout_id, row_key, kind, label, sort_order, depth,
     emphasise, show_accounts, account_types, account_subtypes,
     account_ids, formula)
  select p_org_id, v_id, b.row_key, b.kind, b.label, b.sort_order,
         b.depth, b.emphasise, b.show_accounts, b.account_types,
         b.account_subtypes, b.account_ids, b.formula
    from app.builtin_layout_rows(p_kind) b;

  return v_id;
end;
$$;

comment on function public.create_layout_from_builtin(
  uuid, app.report_kind, text) is
  'Copies the standard layout into a company''s own, editable one, and '
  'makes it active. Writes report_layouts and report_layout_rows. 0637.';

-- ---------------------------------------------------------------------
-- Replacing its rows
--
-- All of them at once, because a layout is one thing: rows refer to
-- each other by key, and applying a builder's changes one row at a time
-- would pass through states where a formula refers to a row that has
-- not arrived yet. The whole set is validated, then swapped.
-- ---------------------------------------------------------------------
create or replace function public.save_layout_rows(
  p_layout_id uuid, p_rows jsonb)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_org   uuid;
  v_row   jsonb;
  v_keys  text[] := array[]::text[];
  v_ref   jsonb;
  v_n     integer := 0;
begin
  select org_id into v_org from public.report_layouts
   where id = p_layout_id and deleted_at is null;
  if v_org is null then
    raise exception 'Layout % not found', p_layout_id using errcode = 'P0002';
  end if;
  if not app.can_write(v_org) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'A layout needs at least one row' using errcode = '23514';
  end if;

  -- Validated in full BEFORE anything is deleted, so a layout that is
  -- refused is the layout that was there before rather than an empty
  -- one. The forward-reference rule is checked here as well as being
  -- unreachable at read time: a builder should be told which row is
  -- wrong while it is open, not the next time somebody opens the
  -- report.
  for v_row in select * from jsonb_array_elements(p_rows) loop
    if coalesce(v_row ->> 'row_key', '') = '' then
      raise exception 'Every row needs a key' using errcode = '23514';
    end if;
    if v_row ->> 'row_key' = any(v_keys) then
      raise exception 'Two rows share the key "%"', v_row ->> 'row_key'
        using errcode = '23514';
    end if;
    if v_row ->> 'kind' = 'formula' then
      for v_ref in select * from jsonb_array_elements(v_row -> 'formula') loop
        if not (v_ref ->> 'row' = any(v_keys)) then
          raise exception
            'Row "%" refers to "%", which is not above it. A formula may '
            'only use rows already computed.',
            v_row ->> 'row_key', v_ref ->> 'row' using errcode = '23514';
        end if;
      end loop;
    end if;
    v_keys := v_keys || (v_row ->> 'row_key');
  end loop;

  delete from public.report_layout_rows where layout_id = p_layout_id;

  insert into public.report_layout_rows
    (org_id, layout_id, row_key, kind, label, sort_order, depth,
     emphasise, show_accounts, account_types, account_subtypes,
     account_ids, formula)
  select v_org, p_layout_id,
         r ->> 'row_key',
         (r ->> 'kind')::app.layout_row_kind,
         coalesce(r ->> 'label', r ->> 'row_key'),
         -- The order the builder sent them in. Taken from the position
         -- rather than from a field, so a builder that reorders rows
         -- does not also have to renumber them.
         (ord * 10)::integer,
         coalesce((r ->> 'depth')::smallint, 0::smallint),
         coalesce((r ->> 'emphasise')::boolean, false),
         coalesce((r ->> 'show_accounts')::boolean, true),
         case when r ? 'account_types' then
           (select array_agg(x::app.account_type)
              from jsonb_array_elements_text(r -> 'account_types') x) end,
         case when r ? 'account_subtypes' then
           (select array_agg(x::app.account_subtype)
              from jsonb_array_elements_text(r -> 'account_subtypes') x) end,
         case when r ? 'account_ids' then
           (select array_agg(x::uuid)
              from jsonb_array_elements_text(r -> 'account_ids') x) end,
         case when r ->> 'kind' = 'formula' then r -> 'formula' end
    from jsonb_array_elements(p_rows) with ordinality as t(r, ord);

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

comment on function public.save_layout_rows(uuid, jsonb) is
  'Replaces a layout''s rows in one go, validating the whole set before '
  'deleting anything -- so a refused layout is the one that was there '
  'rather than an empty one. Writes report_layout_rows. 0637.';

create or replace function public.report_layouts_for(
  p_org_id uuid, p_kind app.report_kind)
returns setof public.report_layouts
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select * from public.report_layouts
   where org_id = p_org_id and kind = p_kind and deleted_at is null
     and app.is_org_member(p_org_id)
   order by is_active desc, name;
$$;

comment on function public.report_layouts_for(uuid, app.report_kind) is
  'A company''s layouts for one report, the active one first. 0637.';

create or replace function public.layout_rows(p_layout_id uuid)
returns setof public.report_layout_rows
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select r.* from public.report_layout_rows r
    join public.report_layouts l on l.id = r.layout_id
   where r.layout_id = p_layout_id and l.deleted_at is null
     and app.is_org_member(r.org_id)
   order by r.sort_order;
$$;

comment on function public.layout_rows(uuid) is
  'One layout''s rows, in order, for the builder. 0637.';

create or replace function public.activate_report_layout(p_layout_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_org uuid; v_kind app.report_kind;
begin
  select org_id, kind into v_org, v_kind from public.report_layouts
   where id = p_layout_id and deleted_at is null;
  if v_org is null then
    raise exception 'Layout % not found', p_layout_id using errcode = 'P0002';
  end if;
  if not app.can_write(v_org) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  update public.report_layouts set is_active = false
   where org_id = v_org and kind = v_kind and is_active
     and deleted_at is null and id <> p_layout_id;
  update public.report_layouts set is_active = true where id = p_layout_id;
end;
$$;

comment on function public.activate_report_layout(uuid) is
  'Makes one layout the one this company''s report uses. Writes '
  'report_layouts. 0637.';

create or replace function public.archive_report_layout(p_layout_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_org uuid;
begin
  select org_id into v_org from public.report_layouts
   where id = p_layout_id and deleted_at is null;
  if v_org is null then
    raise exception 'Layout % not found', p_layout_id using errcode = 'P0002';
  end if;
  if not app.can_write(v_org) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  -- Archiving the active one leaves the company with none, and
  -- `report_with_layout` then falls back to the standard rows. That is
  -- the right outcome and the reason the fallback is not a special
  -- case: there is always a report, whatever somebody deletes.
  update public.report_layouts
     set deleted_at = now(), is_active = false
   where id = p_layout_id;
end;
$$;

comment on function public.archive_report_layout(uuid) is
  'Retires a layout. The company falls back to the standard rows, so '
  'the report still draws. Writes report_layouts. 0637.';

revoke all on function public.create_layout_from_builtin(
  uuid, app.report_kind, text) from public, anon;
grant execute on function public.create_layout_from_builtin(
  uuid, app.report_kind, text) to authenticated, service_role;

revoke all on function public.save_layout_rows(uuid, jsonb) from public, anon;
grant execute on function public.save_layout_rows(uuid, jsonb)
  to authenticated, service_role;

revoke all on function public.report_layouts_for(uuid, app.report_kind)
  from public, anon;
grant execute on function public.report_layouts_for(uuid, app.report_kind)
  to authenticated, service_role;

revoke all on function public.layout_rows(uuid) from public, anon;
grant execute on function public.layout_rows(uuid)
  to authenticated, service_role;

revoke all on function public.activate_report_layout(uuid) from public, anon;
grant execute on function public.activate_report_layout(uuid)
  to authenticated, service_role;

revoke all on function public.archive_report_layout(uuid) from public, anon;
grant execute on function public.archive_report_layout(uuid)
  to authenticated, service_role;
