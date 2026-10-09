-- =====================================================================
-- iAkauntan :: 0780 a paid bill is still a posted one
--
-- `capitalise_bill_line` and `report_uncapitalised_purchases` (`0382`)
-- both asked for a bill whose status is 'posted'. Paying a bill moves
-- it on: `app.apply_allocation` writes 'partial' while part of it is
-- paid and 'completed' once all of it is. So the moment a bill was
-- paid -- even in part -- its asset line dropped off the list of what
-- has been bought and not put in the register, and capitalising it was
-- refused with "BILL-1 has not been posted", which was untrue: the
-- cost was in the asset account, where the posting put it, and paying
-- the supplier does not take it out.
--
-- Measured on 9 October 2026, locally: a RM12,500 lathe on a bill
-- coded to plant, posted, on the list; paid in full, status
-- 'completed', off the list, RM12,500 still in the account, and
-- refused. Buy, pay, then capitalise at the month end is the ordinary
-- order, and it was the one order that could not be finished.
--
-- Answered "accept paid bills". Both functions now take a bill whose
-- journal is in the ledger and has not been undone: posted, part-paid
-- or paid. Draft and void stay refused, in the same words.
--
-- Restated from `0382`, whose text production runs exactly (identical
-- source hashes on 9 October). Production held no bill line on a fixed
-- asset account, so nothing that exists changes.
-- =====================================================================

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
  -- `0780`: paid in part or in full is still posted. Its journal is in
  -- the ledger and paying the supplier did not take the cost out.
  if v_doc.status not in ('posted', 'partial', 'completed') then
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
     and d.status in ('posted', 'partial', 'completed')
     and d.doc_type = 'bill'
     and a.account_subtype = 'fixed_asset'
     and (p_as_at is null or d.doc_date <= p_as_at)
     and not exists (select 1 from public.fixed_assets f
                      where f.purchase_line_id = l.id
                        and f.deleted_at is null)
   order by d.doc_date, d.doc_no, l.line_no;
$$;

comment on function public.capitalise_bill_line(
  uuid, text, text, text, text, integer, numeric, numeric) is
  'Makes a fixed asset out of a posted bill line, taking the cost, the '
  'date, the supplier and the account from the line rather than asking '
  'for them again. `purchase_document_id` was a column nothing wrote, '
  'so the register and the fixed asset accounts had no way to be '
  'compared. A bill paid in part or in full is still posted (`0780`).';
comment on function public.report_uncapitalised_purchases(uuid, date) is
  'Posted bill lines coded to a fixed asset account with no asset in '
  'the register against them — the reconciliation an auditor opens '
  'with, which the data could not answer. Paid bills included: paying '
  'the supplier does not take the cost out of the account (`0780`).';
