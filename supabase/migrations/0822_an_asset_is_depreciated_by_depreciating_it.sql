-- =====================================================================
-- iAkauntan :: 0822 an asset is depreciated by depreciating it
--
-- `run_depreciation` charges each asset from the day after its
-- `depreciated_to` to the date asked, adds the charge to
-- `accumulated_depreciation` and moves `depreciated_to` on; it reads
-- nothing else to know what has been charged. `dispose_fixed_asset`
-- posts the disposal, and only then sets `status` to disposed with the
-- date, the proceeds and the entry. The asset editor sends neither:
-- name, cost, method, life and the rest. But the table's policies let
-- a client write every column.
--
-- Measured on 11 October 2026, locally, as the owner with the role
-- `authenticated`: an RM12,000 van over sixty months, depreciated to 31
-- March -- RM600 in the register and in the ledger. Its accumulated
-- depreciation and `depreciated_to` reset by hand, and March run again:
-- charged again, RM1,200 in the ledger against RM600 in the register.
-- And `status` set to disposed by hand: accepted with no disposal
-- journal, and the asset gone from the register screen, its cost still
-- in the ledger.
--
-- Answered "guard the six columns", as `0813` did for an item's cost.
-- A trigger refuses a client's own statement -- role `authenticated` or
-- `anon`, at the top trigger depth -- that changes
-- `accumulated_depreciation`, `depreciated_to`, `status`,
-- `disposal_date`, `disposal_proceeds` or `disposal_entry_id`, or that
-- creates an asset with any of them other than as new. The functions
-- run as their owner and pass. NOT security definer. The editor's
-- fields are as before.
--
-- Production held seven assets, all depreciated and none disposed, on
-- 11 October.
-- =====================================================================

create or replace function app.fixed_asset_figures_are_the_runs()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.accumulated_depreciation <> 0
       or new.depreciated_to is not null
       or new.status is distinct from 'active'
       or new.disposal_date is not null
       or new.disposal_proceeds is not null
       or new.disposal_entry_id is not null then
      raise exception
        'An asset is registered as new: nothing depreciated and not '
        'disposed of (this one said % to %, %). Depreciation is charged '
        'by running it, and a disposal is posted by disposing of it.',
        new.accumulated_depreciation, new.depreciated_to, new.status
        using errcode = '42501';
    end if;
    return new;
  end if;

  if new.accumulated_depreciation is distinct from old.accumulated_depreciation
     or new.depreciated_to is distinct from old.depreciated_to then
    raise exception
      'What % has been depreciated by follows from the depreciation that '
      'was charged, and is not written directly (% to % -> % to %). The '
      'next run charges from the day after it.',
      new.asset_no, old.accumulated_depreciation, old.depreciated_to,
      new.accumulated_depreciation, new.depreciated_to
      using errcode = '42501';
  end if;

  if new.status is distinct from old.status
     or new.disposal_date is distinct from old.disposal_date
     or new.disposal_proceeds is distinct from old.disposal_proceeds
     or new.disposal_entry_id is distinct from old.disposal_entry_id then
    raise exception
      '% is % and becomes otherwise by being disposed of, which posts the '
      'proceeds and the gain or loss -- not by being marked so.',
      new.asset_no, old.status
      using errcode = '42501';
  end if;

  return new;
end $$;

revoke all on function app.fixed_asset_figures_are_the_runs() from public, anon, authenticated;

comment on function app.fixed_asset_figures_are_the_runs() is
  'On fixed_assets: refuses a client''s own statement that writes '
  'accumulated_depreciation, depreciated_to, status or the disposal '
  'columns, or creates an asset with any of them other than as new. '
  'run_depreciation, dispose_fixed_asset and capitalise_bill_line pass. '
  '0822.';

create trigger a_fixed_asset_figures_are_the_runs
  before insert or update on public.fixed_assets
  for each row execute function app.fixed_asset_figures_are_the_runs();
