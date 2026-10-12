-- =====================================================================
-- iAkauntan :: 0840 what is in the books stays
--
-- Three records outlive the screen they were made on, because something
-- else now stands on them. A posted manufacturing order is the reason
-- for its journal and its stock movements. A fixed asset that has been
-- depreciated is what the ledger's accumulated depreciation explains,
-- one `depreciation_entries` row a run. A lodged set of accounts is the
-- record of what went to SSM. Their delete policies ask only whether
-- the member may write -- and the rows that depend on each either stay
-- behind or cascade away with it.
--
-- Measured on 12 October 2026, locally, as the owner with the role
-- `authenticated`: a posted manufacturing order deleted -- its journal
-- and both its stock movements stayed, with nothing behind them; a van
-- depreciated RM600 deleted -- its depreciation entries went with it and
-- the ledger still carried the RM600; a lodged filing deleted, with its
-- four frozen figures. The app deletes none of the three.
--
-- Answered "refuse deleting what's in the books": a client's delete --
-- role `authenticated` or `anon`, at the top trigger depth -- is refused
-- for a posted manufacturing order, a fixed asset with a depreciation
-- entry or a disposal, and a lodged filing. A draft order, an asset
-- never depreciated and a filing not lodged are as deletable as before.
-- The platform's own definer teardown, and a company deleted outright
-- and cascading, run as the owner and pass -- as `0764` has it for a
-- posted receipt. NOT security definer.
--
-- Production held two posted orders, seven depreciated assets and two
-- lodged filings on 12 October, every one in a demonstration company.
-- =====================================================================

create or replace function app.what_is_in_the_books_stays()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return old;
  end if;

  -- One table a branch, so a column is only read on the table that has
  -- it.
  if tg_table_name = 'manufacturing_orders' then
    if old.gl_entry_id is not null then
      raise exception
        'Manufacturing order % is posted, and its journal and the stock it '
        'moved stand on it. Deleting it would leave them with nothing '
        'behind them.',
        old.order_no
        using errcode = '42501';
    end if;
  elsif tg_table_name = 'fixed_assets' then
    if old.disposal_entry_id is not null
       or exists (select 1 from public.depreciation_entries e
                   where e.asset_id = old.id) then
      raise exception
        'Asset % has been depreciated or disposed of, and the ledger carries '
        'what that charged. Deleting it would leave that with nothing in '
        'the register to explain it. An asset leaves the register by being '
        'disposed of.',
        old.asset_no
        using errcode = '42501';
    end if;
  elsif tg_table_name = 'fs_filings' then
    if old.status = 'lodged' then
      raise exception
        'These accounts have been lodged with SSM, and stay as the record '
        'of what was lodged. A correction is a fresh set.'
        using errcode = '42501';
    end if;
  end if;
  return old;
end $$;

revoke all on function app.what_is_in_the_books_stays()
  from public, anon, authenticated;

comment on function app.what_is_in_the_books_stays() is
  'Before a delete on manufacturing_orders, fixed_assets and fs_filings: '
  'refuses a client''s delete of a posted order, an asset depreciated or '
  'disposed of, and a lodged filing. Definer teardown passes. 0840.';

create trigger what_is_in_the_books_stays
  before delete on public.manufacturing_orders
  for each row execute function app.what_is_in_the_books_stays();
create trigger what_is_in_the_books_stays
  before delete on public.fixed_assets
  for each row execute function app.what_is_in_the_books_stays();
create trigger what_is_in_the_books_stays
  before delete on public.fs_filings
  for each row execute function app.what_is_in_the_books_stays();
