-- =====================================================================
-- What goes on the receipt, chosen by the shop
--
-- `pos_outlets.receipt_header` and `receipt_footer` have existed since
-- 0206. Three demo seeds fill them in. Nothing has ever read them, and
-- the till's own "receipt" is a dialog with four numbers on it — a
-- total, the rounding, the cash due and the change. A customer has
-- never been handed anything, and a shop has never been able to decide
-- what would be on it if they were.
--
-- ---------------------------------------------------------------------
-- The paper is rendered here, not on the device
--
-- `pos_receipt_text` returns the receipt as plain text, wrapped to the
-- paper's own width. That is what a thermal printer wants — ESC/POS is
-- text with a cut at the end — and it means the counter, the phone, the
-- reprint an hour later and the copy a manager reads back all show the
-- same paper. A layout written in Dart would be a layout that only
-- exists where Dart runs, and this module already sells through a
-- kiosk, a waiter's tablet and an offline van.
--
-- It also makes the choices assertable. "Turn the cashier's name off
-- and it is not on the paper" is a test; "turn it off and the widget
-- tree has one fewer Text" is a test of the wrong thing.
--
-- ---------------------------------------------------------------------
-- The choices are per outlet, and so is the text
--
-- One row per outlet, and the header and footer stay on `pos_outlets`
-- where 0206 put them rather than being copied here. Two copies of the
-- shop's own address would be two copies that disagree by Thursday.
-- `upsert_pos_receipt_settings` writes both in one call, so there is no
-- moment where a shop has saved half of it.
--
-- An outlet with no row prints the defaults, which are the things every
-- Malaysian receipt has: the shop, the sale number, the time, what was
-- bought, what it came to, what was paid and the change. Nothing about
-- this feature requires a shop to configure it before it works.
--
-- ---------------------------------------------------------------------
-- Money is never optional
--
-- The booleans cover the things a shop might not want on the paper: the
-- cashier's name, the table, the item codes, the tax summary, the
-- points balance, the customer. There is deliberately no switch for a
-- discount, a promotion, a delivery fee or a tender. A receipt that can
-- be configured not to mention money that changed hands is a receipt
-- that can be used to hide it.
-- =====================================================================

-- ---------------------------------------------------------------------
-- How wide the paper is
-- ---------------------------------------------------------------------
--
-- Shops buy paper in millimetres and printers count in characters. 58mm
-- is 32 columns and 80mm is 48 at the usual font, so the shop picks the
-- roll it buys and the arithmetic happens here.
create or replace function app.receipt_width(p_mm smallint)
returns integer
language sql
immutable
set search_path = public, app, pg_temp
as $$
  select case when coalesce(p_mm, 80) <= 58 then 32 else 48 end;
$$;

comment on function app.receipt_width(smallint) is
  'Columns of text on a roll of this width: 32 for 58mm, 48 for 80mm. A shop picks the paper it buys and the arithmetic happens here.';

-- ---------------------------------------------------------------------
-- A line with something at each end
-- ---------------------------------------------------------------------
--
-- The shape almost every line on a receipt has. The right-hand side is
-- flush right because that is the column a customer's eye runs down,
-- and the left is truncated rather than wrapped when the two would
-- collide — a dish name that pushes the price onto the next line makes
-- the total unreadable, and the dish is already identified by then.
create or replace function app.receipt_pair(
  p_left  text,
  p_right text,
  p_width integer)
returns text
language sql
immutable
set search_path = public, app, pg_temp
as $$
  select case
    when length(coalesce(p_left, '')) + length(coalesce(p_right, '')) + 1 > p_width
      then left(coalesce(p_left, ''),
                greatest(p_width - length(coalesce(p_right, '')) - 1, 0))
           || ' ' || coalesce(p_right, '')
    else coalesce(p_left, '')
         || repeat(' ', p_width - length(coalesce(p_left, ''))
                        - length(coalesce(p_right, '')))
         || coalesce(p_right, '')
  end;
$$;

create or replace function app.receipt_centre(p_text text, p_width integer)
returns text
language sql
immutable
set search_path = public, app, pg_temp
as $$
  select case
    when length(coalesce(p_text, '')) >= p_width then left(coalesce(p_text, ''), p_width)
    else repeat(' ', (p_width - length(coalesce(p_text, ''))) / 2) || coalesce(p_text, '')
  end;
$$;

-- ---------------------------------------------------------------------
-- The words, in the language the shop prints in
-- ---------------------------------------------------------------------
--
-- Two languages because those are the two a Malaysian counter actually
-- uses. A third is a row in this function, not a redesign.
create or replace function app.receipt_label(p_key text, p_lang text)
returns text
language sql
immutable
set search_path = public, app, pg_temp
as $$
  select case when coalesce(p_lang, 'en') = 'ms' then
    case p_key
      when 'sale'      then 'Jualan'
      when 'cashier'   then 'Juruwang'
      when 'table'     then 'Meja'
      when 'customer'  then 'Pelanggan'
      when 'subtotal'  then 'Jumlah kecil'
      when 'discount'  then 'Diskaun'
      when 'delivery'  then 'Penghantaran'
      when 'tax'       then 'Cukai'
      when 'rounding'  then 'Pembundaran'
      when 'total'     then 'JUMLAH'
      when 'change'    then 'Baki'
      when 'points'    then 'Mata ganjaran'
      when 'balance'   then 'Baki mata'
      when 'voided'    then '*** DIBATALKAN ***'
      when 'unpaid'    then '*** BELUM DIBAYAR ***'
      when 'reprint'   then '(salinan)'
      else p_key
    end
  else
    case p_key
      when 'sale'      then 'Sale'
      when 'cashier'   then 'Cashier'
      when 'table'     then 'Table'
      when 'customer'  then 'Customer'
      when 'subtotal'  then 'Subtotal'
      when 'discount'  then 'Discount'
      when 'delivery'  then 'Delivery'
      when 'tax'       then 'Tax'
      when 'rounding'  then 'Rounding'
      when 'total'     then 'TOTAL'
      when 'change'    then 'Change'
      when 'points'    then 'Points earned'
      when 'balance'   then 'Points balance'
      when 'voided'    then '*** VOIDED ***'
      when 'unpaid'    then '*** NOT PAID ***'
      when 'reprint'   then '(copy)'
      else p_key
    end
  end;
$$;

-- ---------------------------------------------------------------------
-- What this shop puts on it
-- ---------------------------------------------------------------------
create table if not exists public.pos_receipt_settings (
  outlet_id uuid primary key references public.pos_outlets (id) on delete cascade,
  org_id    uuid not null references public.organizations (id) on delete cascade,

  -- The roll the shop buys.
  paper_mm  smallint not null default 80 check (paper_mm in (58, 80)),

  -- How many come out of the printer. A shop that keeps a copy for the
  -- till drawer prints two.
  copies    smallint not null default 1 check (copies between 1 and 3),

  language  text not null default 'en' check (language in ('en', 'ms')),

  -- The optional half. Everything that is money is printed whatever
  -- these say — see the header.
  show_item_codes   boolean not null default false,
  show_cashier      boolean not null default true,
  show_table        boolean not null default true,
  show_channel      boolean not null default false,
  show_tax_summary  boolean not null default true,
  show_customer     boolean not null default true,
  show_points       boolean not null default true,

  -- The square a customer photographs to ask for an invoice under a
  -- company name. Printed only when the company has e-Invoice on: a QR
  -- pointing at a feature nobody bought is a support call.
  show_einvoice_qr  boolean not null default true,

  updated_at timestamptz not null default now()
);

create index if not exists pos_receipt_settings_org_idx
  on public.pos_receipt_settings (org_id);

comment on table public.pos_receipt_settings is
  'What this outlet prints on its paper. The header and footer text stay on pos_outlets where 0206 put them; two copies of a shop''s own address would be two copies that disagree by Thursday.';
comment on column public.pos_receipt_settings.show_einvoice_qr is
  'The square a customer photographs to ask for an invoice under a company name. Printed only when the company has e-Invoice switched on.';

-- ---------------------------------------------------------------------
-- The settings, defaulted rather than required
-- ---------------------------------------------------------------------
--
-- An outlet with no row prints the defaults. Nothing about this feature
-- makes a shop configure it before the till works.
create or replace function app.pos_receipt_config(p_outlet uuid)
returns public.pos_receipt_settings
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_row public.pos_receipt_settings;
begin
  select * into v_row from public.pos_receipt_settings where outlet_id = p_outlet;
  if v_row.outlet_id is null then
    v_row.outlet_id := p_outlet;
    select o.org_id into v_row.org_id from public.pos_outlets o where o.id = p_outlet;
    v_row.paper_mm := 80;
    v_row.copies := 1;
    v_row.language := 'en';
    v_row.show_item_codes := false;
    v_row.show_cashier := true;
    v_row.show_table := true;
    v_row.show_channel := false;
    v_row.show_tax_summary := true;
    v_row.show_customer := true;
    v_row.show_points := true;
    v_row.show_einvoice_qr := true;
  end if;
  return v_row;
end;
$$;

revoke all on function app.pos_receipt_config(uuid) from public, anon;
grant execute on function app.pos_receipt_config(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Setting it, header and choices together
-- ---------------------------------------------------------------------
create or replace function public.upsert_pos_receipt_settings(
  p_outlet     uuid,
  p_header     text default null,
  p_footer     text default null,
  p_paper_mm   smallint default 80,
  p_copies     smallint default 1,
  p_language   text default 'en',
  p_item_codes boolean default false,
  p_cashier    boolean default true,
  p_table      boolean default true,
  p_channel    boolean default false,
  p_tax        boolean default true,
  p_customer   boolean default true,
  p_points     boolean default true,
  p_qr         boolean default true)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org uuid;
begin
  select o.org_id into v_org from public.pos_outlets o where o.id = p_outlet;
  if v_org is null then
    raise exception 'No such outlet.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to set up this shop' using errcode = '42501';
  end if;

  -- Both in one statement's reach, so there is no moment where a shop
  -- has saved half of what it typed.
  update public.pos_outlets o
     set receipt_header = nullif(btrim(coalesce(p_header, '')), ''),
         receipt_footer = nullif(btrim(coalesce(p_footer, '')), ''),
         updated_at = now()
   where o.id = p_outlet;

  insert into public.pos_receipt_settings (
    outlet_id, org_id, paper_mm, copies, language, show_item_codes,
    show_cashier, show_table, show_channel, show_tax_summary,
    show_customer, show_points, show_einvoice_qr)
  values (
    p_outlet, v_org, coalesce(p_paper_mm, 80), coalesce(p_copies, 1),
    coalesce(p_language, 'en'), coalesce(p_item_codes, false),
    coalesce(p_cashier, true), coalesce(p_table, true),
    coalesce(p_channel, false), coalesce(p_tax, true),
    coalesce(p_customer, true), coalesce(p_points, true),
    coalesce(p_qr, true))
  on conflict (outlet_id) do update
     set paper_mm = excluded.paper_mm,
         copies = excluded.copies,
         language = excluded.language,
         show_item_codes = excluded.show_item_codes,
         show_cashier = excluded.show_cashier,
         show_table = excluded.show_table,
         show_channel = excluded.show_channel,
         show_tax_summary = excluded.show_tax_summary,
         show_customer = excluded.show_customer,
         show_points = excluded.show_points,
         show_einvoice_qr = excluded.show_einvoice_qr,
         updated_at = now();

  return p_outlet;
end;
$$;

revoke all on function public.upsert_pos_receipt_settings(
  uuid, text, text, smallint, smallint, text, boolean, boolean, boolean,
  boolean, boolean, boolean, boolean, boolean) from public, anon;
grant execute on function public.upsert_pos_receipt_settings(
  uuid, text, text, smallint, smallint, text, boolean, boolean, boolean,
  boolean, boolean, boolean, boolean, boolean) to authenticated;

comment on function public.upsert_pos_receipt_settings(
  uuid, text, text, smallint, smallint, text, boolean, boolean, boolean,
  boolean, boolean, boolean, boolean, boolean) is
  'Saves what an outlet prints — the header and footer on pos_outlets, the choices on pos_receipt_settings — in one call, so a shop is never left having saved half of it.';

create or replace function public.pos_receipt_settings_for(p_outlet uuid)
returns table (
  outlet_id        uuid,
  outlet_name      text,
  header           text,
  footer           text,
  paper_mm         smallint,
  copies           smallint,
  language         text,
  show_item_codes  boolean,
  show_cashier     boolean,
  show_table       boolean,
  show_channel     boolean,
  show_tax_summary boolean,
  show_customer    boolean,
  show_points      boolean,
  show_einvoice_qr boolean)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select o.id, o.name, o.receipt_header, o.receipt_footer,
         c.paper_mm, c.copies, c.language, c.show_item_codes,
         c.show_cashier, c.show_table, c.show_channel, c.show_tax_summary,
         c.show_customer, c.show_points, c.show_einvoice_qr
    from public.pos_outlets o
    cross join lateral app.pos_receipt_config(o.id) c
   where o.id = p_outlet
     and app.can_read_module(o.org_id, 'pos');
$$;

grant execute on function public.pos_receipt_settings_for(uuid) to authenticated;

comment on function public.pos_receipt_settings_for(uuid) is
  'What this outlet prints, defaults included. An outlet nobody has configured comes back with the defaults rather than with nulls.';

-- ---------------------------------------------------------------------
-- The paper
-- ---------------------------------------------------------------------
--
-- One function, returning the text a printer takes. Rendered here so
-- the counter, the phone, the kiosk, the van that was offline this
-- morning and the reprint an hour later all produce the same paper —
-- and so that "turn the cashier's name off and it is not on it" is a
-- thing a test can assert rather than a thing somebody looks at.
--
-- Works on a parked bill as well as a completed one, because "bill
-- please" is a print too. A parked bill says so where the change would
-- be, rather than pretending money has been taken.
create or replace function public.pos_receipt_text(p_sale uuid)
returns text
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale   public.pos_sales;
  v_cfg    public.pos_receipt_settings;
  v_org    public.organizations;
  v_outlet public.pos_outlets;
  v_w      integer;
  v_lang   text;
  v_out    text := '';
  v_line   record;
  v_t      record;
  v_txt    text;
  v_paid   numeric := 0;
  v_change numeric := 0;
  v_name   text;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_sale.org_id, 'pos') then
    raise exception 'not permitted to read this shop' using errcode = '42501';
  end if;

  select * into v_org from public.organizations where id = v_sale.org_id;
  select * into v_outlet from public.pos_outlets where id = v_sale.outlet_id;
  v_cfg  := app.pos_receipt_config(v_sale.outlet_id);
  v_w    := app.receipt_width(v_cfg.paper_mm);
  v_lang := v_cfg.language;

  -- ----------------------------------------------------------------
  -- The head
  -- ----------------------------------------------------------------
  -- The shop's own words first if it wrote any, and its name if it did
  -- not. A blank receipt with no shop on it is a receipt nobody can
  -- take back to anybody.
  if coalesce(btrim(v_outlet.receipt_header), '') <> '' then
    foreach v_txt in array string_to_array(v_outlet.receipt_header, E'\n') loop
      v_out := v_out || app.receipt_centre(btrim(v_txt), v_w) || E'\n';
    end loop;
  else
    v_out := v_out || app.receipt_centre(coalesce(v_org.name, ''), v_w) || E'\n';
    if coalesce(v_outlet.name, '') <> '' then
      v_out := v_out || app.receipt_centre(v_outlet.name, v_w) || E'\n';
    end if;
  end if;

  -- The registration a Malaysian receipt is expected to carry. Printed
  -- from the company record rather than typed into the header, because
  -- a number retyped per outlet is a number wrong at one of them.
  if coalesce(v_org.registration_no, '') <> '' then
    v_out := v_out || app.receipt_centre(v_org.registration_no, v_w) || E'\n';
  end if;
  if v_org.is_sst_registered and coalesce(v_org.sst_registration_no, '') <> '' then
    v_out := v_out
      || app.receipt_centre('SST ' || v_org.sst_registration_no, v_w) || E'\n';
  end if;

  v_out := v_out || repeat('-', v_w) || E'\n';

  -- ----------------------------------------------------------------
  -- Which sale, and when
  -- ----------------------------------------------------------------
  v_out := v_out || app.receipt_pair(
    app.receipt_label('sale', v_lang) || ' ' || coalesce(v_sale.sale_no, ''),
    to_char(coalesce(v_sale.completed_at, v_sale.opened_at)
            at time zone 'Asia/Kuala_Lumpur', 'DD/MM/YY HH24:MI'),
    v_w) || E'\n';

  if v_cfg.show_cashier then
    select p.full_name into v_name from public.profiles p where p.id = v_sale.sold_by;
    if coalesce(v_name, '') <> '' then
      v_out := v_out || app.receipt_label('cashier', v_lang) || ': ' || v_name || E'\n';
    end if;
  end if;

  if v_cfg.show_table and v_sale.table_id is not null then
    select t.code into v_name from public.pos_tables t where t.id = v_sale.table_id;
    v_out := v_out || app.receipt_pair(
      app.receipt_label('table', v_lang) || ': ' || coalesce(v_name, ''),
      case when coalesce(v_sale.covers, 0) > 0
           then v_sale.covers || ' pax' else '' end,
      v_w) || E'\n';
  end if;

  if v_cfg.show_channel and v_sale.order_channel is not null then
    v_out := v_out || replace(v_sale.order_channel::text, '_', ' ') || E'\n';
  end if;

  if v_cfg.show_customer and v_sale.contact_id is not null then
    select c.name into v_name from public.contacts c where c.id = v_sale.contact_id;
    if coalesce(v_name, '') <> '' then
      v_out := v_out
        || app.receipt_label('customer', v_lang) || ': ' || v_name || E'\n';
    end if;
  end if;

  v_out := v_out || repeat('-', v_w) || E'\n';

  -- ----------------------------------------------------------------
  -- What was bought
  -- ----------------------------------------------------------------
  for v_line in
    select l.*, i.code as item_code
      from public.pos_sale_lines l
      left join public.items i on i.id = l.item_id
     where l.sale_id = p_sale
     order by l.line_no
  loop
    v_out := v_out || app.receipt_pair(
      trim(to_char(v_line.quantity, 'FM999999990.###')) || ' x '
        || coalesce(v_line.description, ''),
      to_char(v_line.line_total, 'FM999999990.00'),
      v_w) || E'\n';

    if v_cfg.show_item_codes and coalesce(v_line.item_code, '') <> '' then
      v_out := v_out || '  ' || v_line.item_code || E'\n';
    end if;

    -- What was asked for on the plate. Always printed: a customer
    -- charged two ringgit for an extra egg is entitled to see the egg.
    for v_t in
      select m.name, m.price_delta, m.quantity
        from public.pos_sale_line_modifiers m
       where m.line_id = v_line.id
       order by m.created_at
    loop
      v_out := v_out || app.receipt_pair(
        '  + ' || v_t.name,
        case when v_t.price_delta = 0 then ''
             else to_char(v_t.price_delta * v_t.quantity, 'FM999999990.00') end,
        v_w) || E'\n';
    end loop;

    -- The money somebody took off this line, and why they said they
    -- did. Never optional: see the header.
    if coalesce(v_line.discount_amount, 0) > 0 then
      v_out := v_out || app.receipt_pair(
        '  ' || app.receipt_label('discount', v_lang)
          || coalesce(' - ' || v_line.discount_reason, ''),
        '-' || to_char(v_line.discount_amount, 'FM999999990.00'),
        v_w) || E'\n';
    end if;
  end loop;

  v_out := v_out || repeat('-', v_w) || E'\n';

  -- ----------------------------------------------------------------
  -- What it came to
  -- ----------------------------------------------------------------
  v_out := v_out || app.receipt_pair(
    app.receipt_label('subtotal', v_lang),
    to_char(coalesce(v_sale.subtotal, 0), 'FM999999990.00'), v_w) || E'\n';

  if coalesce(v_sale.bill_discount, 0) > 0 then
    v_out := v_out || app.receipt_pair(
      app.receipt_label('discount', v_lang)
        || coalesce(' - ' || v_sale.bill_discount_reason, ''),
      '-' || to_char(v_sale.bill_discount, 'FM999999990.00'), v_w) || E'\n';
  end if;

  -- Named, one per row. "Less RM 6.00" with no name on it is the line
  -- customers ask about and cashiers cannot answer.
  for v_t in
    select p.name, sp.amount
      from public.pos_sale_promotions sp
      join public.pos_promotions p on p.id = sp.promotion_id
     where sp.sale_id = p_sale and sp.amount > 0
     order by p.name
  loop
    v_out := v_out || app.receipt_pair(
      v_t.name, '-' || to_char(v_t.amount, 'FM999999990.00'), v_w) || E'\n';
  end loop;

  if coalesce(v_sale.loyalty_discount, 0) > 0 then
    v_out := v_out || app.receipt_pair(
      app.receipt_label('points', v_lang),
      '-' || to_char(v_sale.loyalty_discount, 'FM999999990.00'), v_w) || E'\n';
  end if;

  -- The ride. On the paper whatever the settings say, because it is
  -- money the customer is being charged.
  if coalesce(v_sale.delivery_fee, 0) > 0 then
    select z.name into v_name
      from public.pos_deliveries d
      left join public.pos_delivery_zones z on z.id = d.zone_id
     where d.sale_id = p_sale;
    v_out := v_out || app.receipt_pair(
      app.receipt_label('delivery', v_lang) || coalesce(' - ' || v_name, ''),
      to_char(v_sale.delivery_fee, 'FM999999990.00'), v_w) || E'\n';
  end if;

  if v_cfg.show_tax_summary and coalesce(v_sale.tax_amount, 0) <> 0 then
    v_out := v_out || app.receipt_pair(
      app.receipt_label('tax', v_lang),
      to_char(v_sale.tax_amount, 'FM999999990.00'), v_w) || E'\n';
  end if;

  if coalesce(v_sale.rounding_amount, 0) <> 0 then
    v_out := v_out || app.receipt_pair(
      app.receipt_label('rounding', v_lang),
      to_char(v_sale.rounding_amount, 'FM999999990.00'), v_w) || E'\n';
  end if;

  v_out := v_out || app.receipt_pair(
    app.receipt_label('total', v_lang),
    to_char(coalesce(v_sale.total_amount, 0), 'FM999999990.00'), v_w) || E'\n';

  -- ----------------------------------------------------------------
  -- What was handed over
  -- ----------------------------------------------------------------
  v_out := v_out || repeat('-', v_w) || E'\n';

  if v_sale.status = 'parked' then
    -- A bill printed for a table that has not paid yet. It says so
    -- rather than showing a change of nothing, which reads like a
    -- settled sale to anybody glancing at it.
    v_out := v_out || app.receipt_centre(
      app.receipt_label('unpaid', v_lang), v_w) || E'\n';
  else
    for v_t in
      select tt.name, t.amount, t.change_given
        from public.pos_tenders t
        join public.pos_tender_types tt on tt.id = t.tender_type_id
       where t.sale_id = p_sale
       order by t.created_at
    loop
      v_out := v_out || app.receipt_pair(
        v_t.name, to_char(v_t.amount, 'FM999999990.00'), v_w) || E'\n';
      v_paid := v_paid + v_t.amount;
      v_change := v_change + coalesce(v_t.change_given, 0);
    end loop;

    if v_change <> 0 then
      v_out := v_out || app.receipt_pair(
        app.receipt_label('change', v_lang),
        to_char(v_change, 'FM999999990.00'), v_w) || E'\n';
    end if;
  end if;

  if v_sale.status = 'voided' then
    v_out := v_out || app.receipt_centre(
      app.receipt_label('voided', v_lang), v_w) || E'\n';
  end if;

  -- ----------------------------------------------------------------
  -- The points, and the words at the bottom
  -- ----------------------------------------------------------------
  if v_cfg.show_points
     and app.can_read_module(v_sale.org_id, 'loyalty')
     and v_sale.loyalty_account_id is not null then
    v_out := v_out || repeat('-', v_w) || E'\n';
    v_out := v_out || app.receipt_pair(
      app.receipt_label('points', v_lang),
      coalesce(v_sale.loyalty_points_earned, 0)::text, v_w) || E'\n';
    select coalesce(sum(e.points), 0)::text into v_name
      from public.loyalty_entries e
     where e.account_id = v_sale.loyalty_account_id;
    v_out := v_out || app.receipt_pair(
      app.receipt_label('balance', v_lang), coalesce(v_name, '0'), v_w) || E'\n';
  end if;

  if coalesce(btrim(v_outlet.receipt_footer), '') <> '' then
    v_out := v_out || E'\n';
    foreach v_txt in array string_to_array(v_outlet.receipt_footer, E'\n') loop
      v_out := v_out || app.receipt_centre(btrim(v_txt), v_w) || E'\n';
    end loop;
  end if;

  return v_out;
end;
$$;

grant execute on function public.pos_receipt_text(uuid) to authenticated;

comment on function public.pos_receipt_text(uuid) is
  'The receipt as plain text, wrapped to the outlet''s paper width. Rendered on the server so the counter, the phone, the kiosk and an hour-later reprint all produce the same paper.';

-- ---------------------------------------------------------------------
-- Something to look at while choosing
-- ---------------------------------------------------------------------
--
-- The settings screen previews the real thing rather than a mock-up, so
-- the last sale this outlet rang up is what it renders. A shop that has
-- sold nothing yet is told to ring one up — which beats showing an
-- invented basket that will not match the paper when it matters.
create or replace function public.pos_recent_sale(p_outlet uuid)
returns uuid
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select s.id
    from public.pos_sales s
   where s.outlet_id = p_outlet
     and s.status = 'completed'
     and app.can_read_module(s.org_id, 'pos')
   order by s.completed_at desc nulls last
   limit 1;
$$;

grant execute on function public.pos_recent_sale(uuid) to authenticated;

comment on function public.pos_recent_sale(uuid) is
  'The last bill this outlet settled. Used by the receipt settings screen so the preview is a real receipt rather than an invented basket.';

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
alter table public.pos_receipt_settings enable row level security;

create policy pos_receipt_settings_read on public.pos_receipt_settings for select
  to authenticated using (app.can_read_module(org_id, 'pos'));

-- No write policy: the header and the choices are saved together by
-- `upsert_pos_receipt_settings`, and a client that could write this
-- table directly could save one half of them.
grant select on public.pos_receipt_settings to authenticated;
