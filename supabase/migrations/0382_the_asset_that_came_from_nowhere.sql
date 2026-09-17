-- =====================================================================
-- iAkauntan :: 0382 the asset that came from nowhere
--
-- `fixed_assets.purchase_document_id` and `fixed_assets.supplier_id`
-- have been columns since `0084`. Neither is on the asset editor, in
-- the Dart model, or written by anything.
--
-- So the register and the ledger are two records of the same money that
-- have no way to be compared. Somebody posts a bill with a line coded
-- to Plant and equipment; the money lands in 1510. Somebody then opens
-- the asset editor and types a name, a cost and an acquisition date. If
-- they type 12,000 where the bill said 12,500 — the difference being
-- the delivery line, or the tax, or a typo — nothing anywhere says so.
-- The balance sheet shows 12,500 in fixed assets, the register adds up
-- to 12,000, depreciation is charged on the smaller figure for the next
-- five years, and the first person to notice is the auditor.
--
-- That reconciliation is the standard one: **the asset register agrees
-- with the fixed asset accounts in the general ledger**. It cannot be
-- done at all without knowing which asset came from which bill, which
-- is what the column was for.
--
-- ---------------------------------------------------------------------
-- Capitalising a line rather than typing an asset
--
-- `capitalise_bill_line` makes the asset out of the bill line, and the
-- figures are taken rather than asked for: the cost is the line's own
-- net amount, the acquisition date is the bill's date, the supplier is
-- the bill's supplier, and — the one that matters — the asset's
-- `asset_account_id` is **the account the line was actually posted to**.
--
-- That last one is the whole idea. The cost in the register and the
-- debit in the ledger are the same figure in the same account because
-- they come from the same row, rather than because two people happened
-- to choose the same account twice.
--
-- Nothing is posted. Creating an asset never has — the register is a
-- memorandum record and the bill's own posting already put the money in
-- the asset account. A capitalisation that posted again would double
-- the asset.
--
-- ---------------------------------------------------------------------
-- What it will not do
--
-- Capitalise a line twice. One line is one lot of money, and a second
-- asset made from it is the same cost depreciated twice, in a register
-- that then over-states the balance sheet by exactly the amount nobody
-- is looking for.
--
-- Capitalise from an unposted bill. An asset whose cost is not in the
-- ledger cannot be reconciled to it; the bill is posted first, which is
-- the same order everything else in this system uses.
--
-- Capitalise a line coded somewhere other than a fixed asset account.
-- A line charged to Repairs and maintenance and then put in the
-- register is the register and the ledger disagreeing on purpose. The
-- refusal names the account, because the fix is to correct the coding
-- on the bill and that is a different screen.
--
-- ---------------------------------------------------------------------
-- And the reconciliation itself
--
-- `report_uncapitalised_purchases` lists posted bill lines coded to a
-- fixed asset account with no asset in the register against them. It is
-- the question an auditor opens with, and until now the data could not
-- answer it.
-- =====================================================================

-- ---------------------------------------------------------------------
-- What is already there
-- ---------------------------------------------------------------------
do $$
declare v_n integer;
begin
  select count(*) into v_n from public.fixed_assets
   where deleted_at is null and purchase_document_id is null;
  if v_n > 0 then
    raise notice
      '0382: % asset(s) in the register name no purchase document. They '
      'were typed in, so whether the register agrees with the fixed '
      'asset accounts cannot be answered from the data. '
      'report_uncapitalised_purchases works from the other end and '
      'names the bills with nothing against them.', v_n;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- One line, one asset
-- ---------------------------------------------------------------------
-- `purchase_document_id` names the bill; a bill can carry several
-- capital items, so the column that has to be unique is the line. It is
-- added here rather than being one of `0084`'s, because until something
-- capitalised a line there was nothing to point at.
alter table public.fixed_assets
  add column if not exists purchase_line_id uuid
  references public.purchase_document_lines (id) on delete set null;

-- The rule is the index, not a check in the function: one line is one
-- lot of money, and two assets made from it is the same cost
-- depreciated twice. Partial on `deleted_at`, so a mistake can be
-- deleted and the line capitalised again.
create unique index if not exists fixed_assets_one_per_line
  on public.fixed_assets (purchase_line_id)
  where purchase_line_id is not null and deleted_at is null;

-- ---------------------------------------------------------------------
-- Making the asset out of the line
-- ---------------------------------------------------------------------
create or replace function public.capitalise_bill_line(
  p_line               uuid,
  p_asset_no           text,
  p_name               text default null,
  p_category           text default null,
  p_method             text default 'straight_line',
  p_useful_life_months integer default null,
  p_rate_percent       numeric default null,
  p_residual_value     numeric default 0)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_line  public.purchase_document_lines;
  v_doc   public.purchase_documents;
  v_acct  public.accounts;
  v_cost  numeric(18, 2);
  v_asset uuid;
begin
  select * into v_line from public.purchase_document_lines where id = p_line;
  if v_line.id is null then
    raise exception 'No such bill line.' using errcode = 'P0002';
  end if;
  if not app.can_write(v_line.org_id) then
    raise exception 'not permitted to capitalise a purchase'
      using errcode = '42501';
  end if;
  if not app.has_module(v_line.org_id, 'fixed_assets') then
    raise exception 'The fixed assets module is not enabled.'
      using errcode = '42501';
  end if;

  select * into v_doc from public.purchase_documents
   where id = v_line.document_id;
  if v_doc.status <> 'posted' then
    raise exception
      '% has not been posted. An asset whose cost is not in the ledger '
      'is one the register can never be reconciled to it.', v_doc.doc_no
      using errcode = '23514';
  end if;

  if exists (select 1 from public.fixed_assets
              where purchase_line_id = p_line and deleted_at is null) then
    raise exception
      'That line has already been capitalised. One line is one lot of '
      'money, and a second asset from it is the same cost depreciated '
      'twice.' using errcode = '23505';
  end if;

  -- The account the line was actually posted to, which is what makes
  -- the register and the ledger agree by construction.
  select * into v_acct from public.accounts where id = v_line.account_id;
  if v_acct.id is null then
    raise exception
      'That line names no account, so there is nothing to say the cost '
      'is sitting in.' using errcode = '23514';
  end if;
  if v_acct.account_subtype <> 'fixed_asset' then
    raise exception
      'That line was coded to % (%), which is not a fixed asset '
      'account. Correct the coding on % first: putting it in the '
      'register now is the register and the ledger disagreeing on '
      'purpose.', v_acct.name, v_acct.code, v_doc.doc_no
      using errcode = '23514';
  end if;

  -- The line's own net amount, in the company's own money. Tax is not
  -- part of cost where it is recoverable, and `line_subtotal` is the
  -- figure the posting used.
  v_cost := round(v_line.line_subtotal * v_doc.exchange_rate, 2);
  if v_cost <= 0 then
    raise exception 'A line worth nothing is not an asset.'
      using errcode = '23514';
  end if;
  if coalesce(p_residual_value, 0) > v_cost then
    raise exception
      'A residual value of % is more than the % the asset cost.',
      p_residual_value, v_cost using errcode = '23514';
  end if;

  insert into public.fixed_assets
    (org_id, asset_no, name, category, asset_account_id,
     acquisition_date, cost, residual_value, method,
     useful_life_months, rate_percent, supplier_id,
     purchase_document_id, purchase_line_id, created_by)
  values (v_line.org_id, btrim(p_asset_no),
          coalesce(nullif(btrim(coalesce(p_name, '')), ''),
                   nullif(v_line.description, ''), btrim(p_asset_no)),
          p_category, v_acct.id,
          v_doc.doc_date, v_cost, coalesce(p_residual_value, 0),
          p_method, p_useful_life_months, p_rate_percent,
          v_doc.contact_id, v_doc.id, v_line.id, auth.uid())
  returning id into v_asset;

  return v_asset;
end $$;

-- ---------------------------------------------------------------------
-- What has been bought and not put in the register
-- ---------------------------------------------------------------------
create or replace function public.report_uncapitalised_purchases(
  p_org   uuid,
  p_as_at date default null)
returns table (
  line_id       uuid,
  document_id   uuid,
  doc_no        text,
  doc_date      date,
  supplier_name text,
  description   text,
  account_code  text,
  account_name  text,
  amount        numeric)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select l.id, d.id, d.doc_no, d.doc_date, c.name, l.description,
         a.code, a.name,
         round(l.line_subtotal * d.exchange_rate, 2)
    from public.purchase_document_lines l
    join public.purchase_documents d on d.id = l.document_id
    join public.accounts a on a.id = l.account_id
    join public.contacts c on c.id = d.contact_id
   where l.org_id = p_org
     and app.can_read_module(p_org, 'fixed_assets')
     and d.status = 'posted'
     and d.doc_type = 'bill'
     and a.account_subtype = 'fixed_asset'
     and (p_as_at is null or d.doc_date <= p_as_at)
     and not exists (select 1 from public.fixed_assets f
                      where f.purchase_line_id = l.id
                        and f.deleted_at is null)
   order by d.doc_date, d.doc_no, l.line_no;
$$;

-- ---------------------------------------------------------------------
revoke all on function public.capitalise_bill_line(
  uuid, text, text, text, text, integer, numeric, numeric)
  from public, anon;
revoke all on function
  public.report_uncapitalised_purchases(uuid, date) from public, anon;

grant execute on function public.capitalise_bill_line(
  uuid, text, text, text, text, integer, numeric, numeric) to authenticated;
grant execute on function
  public.report_uncapitalised_purchases(uuid, date) to authenticated;

comment on function public.capitalise_bill_line(
  uuid, text, text, text, text, integer, numeric, numeric) is
  'Makes a fixed asset out of a posted bill line, taking the cost, the '
  'date, the supplier and the account from the line rather than asking '
  'for them again. `purchase_document_id` was a column nothing wrote, '
  'so the register and the fixed asset accounts had no way to be '
  'compared.';
comment on function public.report_uncapitalised_purchases(uuid, date) is
  'Posted bill lines coded to a fixed asset account with no asset in '
  'the register against them — the reconciliation an auditor opens '
  'with, which the data could not answer.';
