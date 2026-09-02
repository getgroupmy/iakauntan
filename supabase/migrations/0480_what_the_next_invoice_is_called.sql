-- ---------------------------------------------------------------------
-- 0480  What the next invoice is called
-- ---------------------------------------------------------------------
-- Every document this system issues is numbered from
-- `public.number_sequences`: a prefix, a reset policy, a padding, a
-- suffix and the next number, one row per series per company, made on
-- the first draw with the defaults of 0001 and the prefix of
-- `app.default_doc_prefix`. Nothing edits the row. There is no screen
-- for it, no function that sets it, and the row is behind RLS that
-- lets an admin update it -- from a SQL console. So a company that
-- numbers its invoices `INV/2026/0001`, or whose old system stopped at
-- INV-2026-00412 and must carry on from 00413, could not say so. They
-- were typing the number over the drawn one on each document, and the
-- counter kept drawing numbers nobody used.
--
-- ### What changes
--
--   * `public.document_numbering(org)` lists every series of the
--     modules the company has -- label, prefix, suffix, padding, reset
--     policy, the next number, the last one issued -- and a sample of
--     what the next draw will return, composed the same way the draw
--     composes it and drawing nothing. A series that has no row yet is
--     listed with the defaults it would get, and says so.
--   * `public.set_document_numbering(org, series, prefix, suffix,
--     padding, reset, next)` sets a series, admin only, and returns the
--     sample of the next number. The next number cannot be set below
--     the last one issued while the prefix, suffix and reset policy
--     stay the same: the numbers below it are on documents already, and
--     `sales_documents (org_id, doc_no)` would refuse the draw later,
--     with the index's message, on somebody else's screen. A new prefix
--     or a new suffix or a new policy is a new series, and may start
--     from 1.
--   * Setting the reset policy writes the period key the policy needs.
--     `never` drops it; `yearly` and `monthly` take the current period,
--     so the admin's next number is the number the next draw returns,
--     not 1 because the key was stale.
--   * A change to the shape of a series is audited -- `audit_changes`
--     on `number_sequences`, on delete and on update of prefix, suffix,
--     padding and reset policy. A draw, which updates only the next
--     number and the period key, writes no audit row: that path runs
--     for every invoice, and the invoice is its own record.
--
-- ### The number that lost a digit
--
-- The draw padded the number with `lpad(n, padding, '0')`, and
-- `lpad` truncates on the right when the text is already longer than
-- the padding: the 100,000th number in a series padded to five is
-- `lpad('100000', 5, '0')`, which is `'10000'` -- the same string the
-- 10,000th got. `app.compose_document_number` pads a short number and
-- leaves a long one whole, and the draw is restated on it. No company
-- has reached that number; the assertion is there so that none finds
-- out on the day.
--
-- ### What stays
--
--   * `app.next_document_number_internal` draws as it did: the row is
--     made on first use, locked, reset when the period turns, and
--     moved on by one. Only the arithmetic of the text has moved into
--     the helper.
--   * `app.contact_code_shape` (0479) reads the same row and the same
--     defaults, and the preview it gives an import file still matches
--     what the draw returns.
--   * Who may draw is unchanged: any member, through
--     `public.next_document_number`.
--
-- ### Mutants
--
-- Each restated into a built database and run against
-- `supabase/tests/document_numbering.sql`:
--
--   * `set_document_numbering` guarded by `is_org_member` instead of
--     `can_admin` -- killed by "an accountant may read the numbering
--     and may not set it";
--   * the lowering guard dropped -- killed by "the next number cannot
--     go below the last issued";
--   * the lowering guard applied even when the prefix changes -- killed
--     by "a new prefix may start from 1";
--   * `compose_document_number` written with `lpad` alone -- killed by
--     "the hundred-thousandth number keeps its digits";
--   * the sample composed from the stored next number regardless of a
--     stale period key -- killed by "after the year turns the sample
--     says 00001";
--   * the period key not written when the policy is set -- killed by
--     "the number set is the number drawn";
--   * `audit_changes` on every update -- killed by "drawing a number
--     writes no audit row";
--   * no `audit_changes` at all -- killed by "setting a series writes
--     an audit row";
--   * every series listed regardless of module -- killed by "a series
--     of a module the company has not bought is not listed";
--   * a series not in `app.numbered_series` accepted -- killed by "an
--     unknown series is refused";
--   * the sample composed differently from the draw -- killed by "the
--     sample is the number the next draw returns";
--   * the restated internal draw granted to `authenticated`, as a
--     restatement's grant line reflexively is -- killed by "the
--     unchecked draw is not exposed to the API" here, by `ledger.sql`
--     ("nor is the unchecked numbering") and by
--     `app_writers_are_not_a_client_surface.sql`, which found it first.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- The series there are
-- ---------------------------------------------------------------------
-- Every doc type the migrations and the app draw from, with the module
-- it belongs to. The self-check below holds it against
-- `app.default_doc_prefix`: a type with a default prefix and no entry
-- here would be drawn and never listed.
create or replace function app.numbered_series()
returns table (doc_type text, label text, module text, ordinal integer)
language sql immutable
set search_path = pg_catalog, pg_temp
as $$
  select * from (values
    -- sales
    ('quotation',            'Quotations',                 'sales',              10),
    ('sales_order',          'Sales orders',               'sales',              20),
    ('delivery_order',       'Delivery orders',            'sales',              30),
    ('invoice',              'Invoices',                   'sales',              40),
    ('credit_note',          'Credit notes',               'sales',              50),
    ('debit_note',           'Debit notes',                'sales',              60),
    ('refund_note',          'Refund notes',               'sales',              70),
    ('proforma',             'Proforma invoices',          'sales',              80),
    ('receipt',              'Receipts',                   'sales',              90),
    ('deposit',              'Deposits',                   'sales',             100),
    -- purchases
    ('purchase_request',     'Purchase requests',          'purchases',         110),
    ('purchase_order',       'Purchase orders',            'purchases',         120),
    ('goods_received',       'Goods received notes',       'purchases',         130),
    ('bill',                 'Bills',                      'purchases',         140),
    ('purchase_credit_note', 'Purchase credit notes',      'purchases',         150),
    ('purchase_debit_note',  'Purchase debit notes',       'purchases',         160),
    ('purchase_return',      'Purchase returns',           'purchases',         170),
    ('payment',              'Supplier payments',          'purchases',         180),
    ('expense',              'Expenses',                   'purchases',         190),
    -- accounting
    ('journal',              'Journal vouchers',           'accounting',        200),
    ('contra',               'Contras',                    'accounting',        210),
    ('bank_transfer',        'Bank transfers',             'accounting',        220),
    ('cheque',               'Post-dated cheques',         'accounting',        230),
    ('withholding',          'Withholding tax',            'accounting',        240),
    -- contacts
    ('contact',              'Customers',                  'contacts',          250),
    ('supplier',             'Suppliers',                  'contacts',          260),
    ('prospect',             'Prospects',                  'contacts',          270),
    ('item',                 'Items',                      'contacts',          280),
    -- crm
    ('lead',                 'Leads',                      'crm',               290),
    ('opportunity',          'Opportunities',              'crm',               300),
    -- inventory
    ('stock_adjustment',     'Stock adjustments',          'inventory',         310),
    ('stock_movement',       'Stock movements',            'inventory',         320),
    ('stock_transfer',       'Stock transfers',            'inventory',         330),
    ('landed_cost',          'Landed costs',               'inventory',         340),
    -- manufacturing
    ('manufacturing_order',  'Manufacturing orders',       'manufacturing',     350),
    -- payroll and hr
    ('payroll_run',          'Payroll runs',               'payroll',           360),
    ('leave_request',        'Leave requests',             'hr',                370),
    -- pos
    ('pos_shift',            'Shifts',                     'pos',               380),
    ('pos_sale',             'Sales',                      'pos',               390),
    -- ticketing
    ('ticket',               'Tickets',                    'ticketing',         400),
    -- legal
    ('client_txn',           'Client account transactions','legal',             410),
    ('matter',               'Matters',                    'legal',             420),
    -- property
    ('strata_charge',        'Strata charges',             'property_strata',   430),
    ('rent_run',             'Rent runs',                  'property_nonstrata',440)
  ) as v(doc_type, label, module, ordinal);
$$;

revoke all on function app.numbered_series() from public, anon;
grant execute on function app.numbered_series() to authenticated;

comment on function app.numbered_series() is
  'Every series a document is numbered from, with the module it belongs '
  'to and the order it is listed in. See 0480.';

-- ---------------------------------------------------------------------
-- The period a series is in
-- ---------------------------------------------------------------------
create or replace function app.series_period_key(p_reset_policy text)
returns text
language sql stable
set search_path = pg_catalog, public, app, pg_temp
as $$
  select case p_reset_policy
    when 'yearly'  then to_char(app.today(), 'YYYY')
    when 'monthly' then to_char(app.today(), 'YYYYMM')
    else null end;
$$;

revoke all on function app.series_period_key(text) from public, anon;
grant execute on function app.series_period_key(text) to authenticated;

-- ---------------------------------------------------------------------
-- The text of a number
-- ---------------------------------------------------------------------
-- Pads a short number to the padding and leaves a long one whole.
-- `lpad` alone cuts a long one down -- see the header.
create or replace function app.compose_document_number(
  p_prefix text, p_period_key text, p_number bigint, p_padding integer,
  p_suffix text)
returns text
language sql immutable
set search_path = pg_catalog, pg_temp
as $$
  select coalesce(p_prefix, '')
      || coalesce(p_period_key || '-', '')
      || case when length(p_number::text) >= coalesce(p_padding, 1)
              then p_number::text
              else lpad(p_number::text, p_padding, '0') end
      || coalesce(p_suffix, '');
$$;

revoke all on function app.compose_document_number(text, text, bigint, integer, text)
  from public, anon;
grant execute on function app.compose_document_number(text, text, bigint, integer, text)
  to authenticated;

comment on function app.compose_document_number(text, text, bigint, integer, text) is
  'prefix || period || padded number || suffix, the way every drawn '
  'number is written. Never truncates. See 0480.';

-- ---------------------------------------------------------------------
-- The draw, restated on the helpers
-- ---------------------------------------------------------------------
create or replace function app.next_document_number_internal(
  p_org_id uuid, p_doc_type text)
returns text
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_seq public.number_sequences;
  v_period_key text;
  v_number bigint;
begin
  insert into public.number_sequences (org_id, doc_type, prefix)
  values (p_org_id, p_doc_type, app.default_doc_prefix(p_doc_type))
  on conflict (org_id, doc_type) do nothing;

  select * into v_seq from public.number_sequences
   where org_id = p_org_id and doc_type = p_doc_type for update;

  v_period_key := app.series_period_key(v_seq.reset_policy);

  if v_seq.reset_policy <> 'never'
     and v_seq.period_key is distinct from v_period_key then
    v_number := 1;
  else
    v_number := v_seq.next_value;
  end if;

  update public.number_sequences
     set next_value = v_number + 1, period_key = v_period_key
   where id = v_seq.id;

  return app.compose_document_number(
    v_seq.prefix, v_period_key, v_number, v_seq.padding, v_seq.suffix);
end; $$;

-- Internal, as 0056 left it: for other definer functions and the
-- scheduler. Reaching it from an API key would skip the membership
-- check the public wrapper makes, so no client role may execute it.
revoke all on function app.next_document_number_internal(uuid, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- What the series are set to, and what the next one will be called
-- ---------------------------------------------------------------------
create or replace function public.document_numbering(p_org_id uuid)
returns table (
  doc_type     text,
  label        text,
  module       text,
  prefix       text,
  suffix       text,
  padding      integer,
  reset_policy text,
  next_value   bigint,
  last_issued  bigint,
  period_key   text,
  sample       text,
  is_default   boolean)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;

  return query
  with s as (
    select n.doc_type, n.label, n.module, n.ordinal,
           coalesce(q.prefix, app.default_doc_prefix(n.doc_type)) as prefix,
           coalesce(q.suffix, '') as suffix,
           coalesce(q.padding::integer, 5) as padding,
           coalesce(q.reset_policy, 'yearly') as reset_policy,
           q.id is null as is_default,
           -- The number the next draw returns: 1 when there is no row
           -- yet or the period has turned since the last draw, else the
           -- stored next number.
           case when q.id is null then 1::bigint
                when q.reset_policy <> 'never'
                 and q.period_key is distinct from
                     app.series_period_key(q.reset_policy) then 1::bigint
                else q.next_value end as effective_next
      from app.numbered_series() n
      left join public.number_sequences q
        on q.org_id = p_org_id and q.doc_type = n.doc_type
     where app.module_visible(p_org_id, n.module))
  select s.doc_type, s.label, s.module, s.prefix, s.suffix, s.padding,
         s.reset_policy, s.effective_next,
         case when s.effective_next > 1 then s.effective_next - 1 end,
         app.series_period_key(s.reset_policy),
         app.compose_document_number(
           s.prefix, app.series_period_key(s.reset_policy),
           s.effective_next, s.padding, s.suffix),
         s.is_default
    from s
   order by s.ordinal;
end; $$;

revoke all on function public.document_numbering(uuid) from public, anon;
grant execute on function public.document_numbering(uuid) to authenticated;

comment on function public.document_numbering(uuid) is
  'Every series of the modules the company has, as it is set, with a '
  'sample of the next number composed the way the draw composes it. '
  'Draws nothing. See 0480.';

-- ---------------------------------------------------------------------
-- Setting a series
-- ---------------------------------------------------------------------
create or replace function public.set_document_numbering(
  p_org_id uuid, p_doc_type text, p_prefix text, p_suffix text,
  p_padding integer, p_reset_policy text, p_next_value bigint)
returns text
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_seq public.number_sequences;
  v_label text;
  v_prefix text := coalesce(p_prefix, '');
  v_suffix text := coalesce(p_suffix, '');
  v_effective bigint;
  v_period_key text;
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an owner or admin may set document numbering'
      using errcode = '42501';
  end if;

  select n.label into v_label from app.numbered_series() n
   where n.doc_type = p_doc_type;
  if v_label is null then
    raise exception 'Unknown series %', p_doc_type using errcode = '22023';
  end if;

  if v_prefix !~ '^[A-Za-z0-9/_.#-]{0,12}$' then
    raise exception 'The prefix may be up to 12 letters, digits, / _ . # or -'
      using errcode = '22023';
  end if;
  if v_suffix !~ '^[A-Za-z0-9/_.#-]{0,12}$' then
    raise exception 'The suffix may be up to 12 letters, digits, / _ . # or -'
      using errcode = '22023';
  end if;
  if p_padding is null or p_padding < 1 or p_padding > 12 then
    raise exception 'The number is padded to between 1 and 12 digits'
      using errcode = '22023';
  end if;
  if p_reset_policy is null
     or p_reset_policy not in ('never', 'yearly', 'monthly') then
    raise exception 'The numbering restarts never, yearly or monthly'
      using errcode = '22023';
  end if;
  if p_next_value is null or p_next_value < 1
     or p_next_value > 999999999999 then
    raise exception 'The next number is between 1 and 999999999999'
      using errcode = '22023';
  end if;

  insert into public.number_sequences (org_id, doc_type, prefix)
  values (p_org_id, p_doc_type, app.default_doc_prefix(p_doc_type))
  on conflict (org_id, doc_type) do nothing;

  select * into v_seq from public.number_sequences
   where org_id = p_org_id and doc_type = p_doc_type for update;

  -- The number the next draw would return as the series stands.
  if v_seq.reset_policy <> 'never'
     and v_seq.period_key is distinct from
         app.series_period_key(v_seq.reset_policy) then
    v_effective := 1;
  else
    v_effective := v_seq.next_value;
  end if;

  -- Below the last one issued, in the same series, is a number that is
  -- on a document already.
  if p_next_value < v_effective
     and v_prefix = v_seq.prefix
     and v_suffix = v_seq.suffix
     and p_reset_policy = v_seq.reset_policy then
    raise exception
      'The last of % issued was %; the next cannot be lower than % '
      'unless the prefix, suffix or reset policy changes.',
      lower(v_label),
      app.compose_document_number(
        v_seq.prefix, app.series_period_key(v_seq.reset_policy),
        v_effective - 1, v_seq.padding, v_seq.suffix),
      v_effective
      using errcode = '23514';
  end if;

  v_period_key := app.series_period_key(p_reset_policy);

  update public.number_sequences
     set prefix       = v_prefix,
         suffix       = v_suffix,
         padding      = p_padding,
         reset_policy = p_reset_policy,
         next_value   = p_next_value,
         period_key   = v_period_key
   where id = v_seq.id;

  return app.compose_document_number(
    v_prefix, v_period_key, p_next_value, p_padding, v_suffix);
end; $$;

revoke all on function public.set_document_numbering(
  uuid, text, text, text, integer, text, bigint) from public, anon;
grant execute on function public.set_document_numbering(
  uuid, text, text, text, integer, text, bigint) to authenticated;

comment on function public.set_document_numbering(
  uuid, text, text, text, integer, text, bigint) is
  'Set a series -- prefix, suffix, padding, reset policy, next number -- '
  'and return the sample of the next number. Admin only. The next '
  'number cannot go below the last issued while the series keeps its '
  'prefix, suffix and reset policy. See 0480.';

-- ---------------------------------------------------------------------
-- The trail
-- ---------------------------------------------------------------------
-- On the shape, not on the draw: every invoice moves `next_value` and
-- `period_key`, and the invoice is the record of that.
drop trigger if exists audit_changes on public.number_sequences;
create trigger audit_changes
  after delete or update of prefix, suffix, padding, reset_policy
  on public.number_sequences
  for each row execute function app.write_audit_log();

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_draw text := pg_get_functiondef(
    to_regprocedure('app.next_document_number_internal(uuid, text)'));
  v_set text := pg_get_functiondef(
    to_regprocedure('public.set_document_numbering(uuid, text, text, text, integer, text, bigint)'));
  v_list text := pg_get_functiondef(
    to_regprocedure('public.document_numbering(uuid)'));
  v_prefix_src text := pg_get_functiondef(
    to_regprocedure('app.default_doc_prefix(text)'));
  v_missing text;
  v_default text;
  v_trigger text;
begin
  -- The draw composes through the helper, and no longer pads with
  -- lpad on its own.
  if position('app.compose_document_number' in v_draw) = 0
     or position('app.series_period_key' in v_draw) = 0 then
    raise exception '0480: the draw does not use the helpers';
  end if;
  if position('lpad(' in v_draw) > 0 then
    raise exception '0480: the draw still pads with lpad';
  end if;
  -- And the helper does not truncate.
  if app.compose_document_number('INV-', '2026', 100000, 5, '')
       <> 'INV-2026-100000' then
    raise exception '0480: compose_document_number truncates';
  end if;
  if app.compose_document_number('INV-', '2026', 7, 5, '/A')
       <> 'INV-2026-00007/A' then
    raise exception '0480: compose_document_number does not pad';
  end if;

  -- Every doc type with a default prefix is a listed series.
  select string_agg(m[1], ', ') into v_missing
    from regexp_matches(v_prefix_src, 'when ''(\w+)''', 'g') as m
   where m[1] not in (select n.doc_type from app.numbered_series() n);
  if v_missing is not null then
    raise exception '0480: series with a default prefix and no listing: %',
      v_missing;
  end if;
  -- And every listed series names a module that exists.
  select string_agg(n.doc_type, ', ') into v_missing
    from app.numbered_series() n
   where not exists (select 1 from public.platform_modules m
                      where m.code = n.module);
  if v_missing is not null then
    raise exception '0480: series of a module that does not exist: %',
      v_missing;
  end if;

  -- The fallbacks the listing shows for a series with no row are the
  -- column defaults the first draw would write.
  select pg_get_expr(d.adbin, d.adrelid) into v_default
    from pg_attribute a join pg_attrdef d
      on d.adrelid = a.attrelid and d.adnum = a.attnum
   where a.attrelid = 'public.number_sequences'::regclass
     and a.attname = 'padding';
  if v_default <> '5' or position('coalesce(q.padding::integer, 5)' in v_list) = 0 then
    raise exception '0480: the padding fallback is not the column default';
  end if;
  select pg_get_expr(d.adbin, d.adrelid) into v_default
    from pg_attribute a join pg_attrdef d
      on d.adrelid = a.attrelid and d.adnum = a.attnum
   where a.attrelid = 'public.number_sequences'::regclass
     and a.attname = 'reset_policy';
  if v_default <> '''yearly''::text'
     or position('coalesce(q.reset_policy, ''yearly'')' in v_list) = 0 then
    raise exception '0480: the reset policy fallback is not the column default';
  end if;

  -- The guards.
  if position('app.can_admin(p_org_id)' in v_set) = 0 then
    raise exception '0480: set_document_numbering is not admin only';
  end if;
  if position('app.is_org_member(p_org_id)' in v_list) = 0 then
    raise exception '0480: document_numbering is not member only';
  end if;
  if position('p_next_value < v_effective' in v_set) = 0 then
    raise exception '0480: the next number may go below the last issued';
  end if;
  if position('app.module_visible(p_org_id, n.module)' in v_list) = 0 then
    raise exception '0480: series of modules the company has not bought are listed';
  end if;

  -- The trail is on the shape, not on the draw.
  select pg_get_triggerdef(t.oid) into v_trigger
    from pg_trigger t
   where t.tgrelid = 'public.number_sequences'::regclass
     and t.tgname = 'audit_changes';
  if v_trigger is null then
    raise exception '0480: number_sequences is not audited';
  end if;
  if v_trigger !~* 'AFTER DELETE OR UPDATE OF prefix, suffix, padding, reset_policy ON' then
    raise exception '0480: the trail is not scoped to the shape: %', v_trigger;
  end if;

  -- Who may call what.
  if not has_function_privilege('authenticated',
       'public.document_numbering(uuid)', 'execute') then
    raise exception '0480: authenticated cannot read document_numbering';
  end if;
  if not has_function_privilege('authenticated',
       'public.set_document_numbering(uuid, text, text, text, integer, text, bigint)',
       'execute') then
    raise exception '0480: authenticated cannot call set_document_numbering';
  end if;
  if has_function_privilege('authenticated',
       'app.next_document_number_internal(uuid, text)', 'execute') then
    raise exception '0480: the unchecked draw is reachable from an API key';
  end if;
  if has_function_privilege('anon', 'public.document_numbering(uuid)', 'execute')
     or has_function_privilege('anon',
          'public.set_document_numbering(uuid, text, text, text, integer, text, bigint)',
          'execute')
     or has_function_privilege('anon', 'app.numbered_series()', 'execute')
     or has_function_privilege('anon',
          'app.compose_document_number(text, text, bigint, integer, text)', 'execute')
     or has_function_privilege('anon', 'app.series_period_key(text)', 'execute')
     or has_function_privilege('anon',
          'app.next_document_number_internal(uuid, text)', 'execute') then
    raise exception '0480: anon can reach the numbering';
  end if;
end $do$;
