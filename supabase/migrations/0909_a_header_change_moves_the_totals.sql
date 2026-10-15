-- =====================================================================
-- iAkauntan :: 0909 a header change moves the totals
--
-- `app.recalc_sales_totals_for` and `app.recalc_purchase_totals_for`
-- work a document's totals out of its lines AND four things on its
-- header: the discount percentage, the discount amount (when there is
-- no percentage), the shipping, and the exchange rate. They run when a
-- line changes, and -- since `0706` -- when the rounding method does.
-- Nothing ran them when one of the four changed on its own, and since
-- `0905` nobody else may write the totals.
--
-- Measured on 15 October 2026, locally, as the owner with the role
-- `authenticated`, each on a draft RM1,000 invoice of one line, the
-- header changed and nothing else:
--
--   * shipping 500: the total stayed 1,000 and posting refused it,
--     "Journal does not balance: debits 1000.00, credits 1500.00";
--   * a 10% discount: never applied -- the discount stayed 0 and the
--     invoice posted 1210 1,000;
--   * a USD invoice's rate from 4.4 to 4.6: the ledger took RM4,600
--     at the new rate while `base_total_amount` -- which the dashboard
--     and the company reports add up -- stayed at RM4,400.
--
-- The app is not affected: it re-sends every line on every save, so a
-- line trigger always runs after its header is written. The API road
-- is: a header written on its own.
--
-- Production on 15 October: 216 documents, every header agreeing with
-- its inputs; none with shipping or a foreign rate.
--
-- Answered "recalculate on header": a client's own change of any of
-- the four, on a sales or purchase document, works the totals out
-- again at once. NOT what the database does for itself:
-- `complete_pos_sale` writes the discount and the shipping of a sale
-- and then its own totals -- the service charge's tax among them, which
-- the recalculation would drop -- and runs as its owner, so it is not
-- asked. The `WHEN` stops the recursion: the recalculation writes the
-- discount back, and a second pass writes what is already there.
-- =====================================================================

create or replace function app.recalc_totals_on_a_clients_header_change()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  -- NOT security definer, for 0781's reason: the question is who runs
  -- the statement. The functions that write these columns for
  -- themselves run as their owner and keep their own figures.
  if current_user not in ('authenticated', 'anon') then
    return null;
  end if;
  if tg_table_name = 'sales_documents' then
    perform app.recalc_sales_totals_for(new.id);
  else
    perform app.recalc_purchase_totals_for(new.id);
  end if;
  return null;
end;
$$;

revoke all on function app.recalc_totals_on_a_clients_header_change() from public, anon, authenticated;

comment on function app.recalc_totals_on_a_clients_header_change() is
  'Works a sales or purchase document''s totals out again when a client '
  'changes its discount percentage, discount amount, shipping or exchange '
  'rate on the header alone. The database''s own writers run as their '
  'owner and are not asked. 0909.';

create trigger recalc_totals_on_header
  after update of discount_percent, discount_amount, shipping_amount, exchange_rate
  on public.sales_documents
  for each row
  when (old.discount_percent is distinct from new.discount_percent
     or old.discount_amount is distinct from new.discount_amount
     or old.shipping_amount is distinct from new.shipping_amount
     or old.exchange_rate is distinct from new.exchange_rate)
  execute function app.recalc_totals_on_a_clients_header_change();

create trigger recalc_totals_on_header
  after update of discount_percent, discount_amount, shipping_amount, exchange_rate
  on public.purchase_documents
  for each row
  when (old.discount_percent is distinct from new.discount_percent
     or old.discount_amount is distinct from new.discount_amount
     or old.shipping_amount is distinct from new.shipping_amount
     or old.exchange_rate is distinct from new.exchange_rate)
  execute function app.recalc_totals_on_a_clients_header_change();
