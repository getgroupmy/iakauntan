-- =====================================================================
-- iAkauntan :: 0827 a revision leaves the estimate it replaced
--
-- `open_tax_estimate` makes a CP204 or CP500 estimate, deciding its form
-- from the entity type and its year of assessment from the basis
-- period; `revise_tax_estimate` makes a CP204A as a NEW row pointing at
-- the one it replaces, which it marks superseded. `tax_estimate_schedule`
-- reads the whole chain: each instalment is payable at whatever the
-- estimate in force on its due date said (`0672`), so the superseded
-- estimate is still the record of what was payable before the revision.
-- The screen's "change the estimate" dialog writes six fields on the
-- live estimate -- the figure, last year's figure, the first-period
-- flag, the commencement date, capital and income -- and nothing else.
-- But `0667`'s policies let a client write every column of every row.
--
-- Measured on 12 October 2026, locally, as the owner with the role
-- `authenticated`: an estimate of RM120,000 revised to RM240,000 in the
-- ninth month, RM10,000 paid on the first instalment. The superseded
-- original rewritten to RM0 put instalments one to seven at RM0 -- the
-- RM10,000 paid against nothing due -- and the tax tile's overdue
-- figure fell from seven instalments and RM94,000 to one and RM48,000.
-- The form typed as CP500 on a Sdn Bhd handed it six instalments for
-- twelve; the revision month moved from nine to two rewrote seven
-- instalments that had already fallen due; and an estimate could be
-- inserted already superseded, on the wrong form, for 2031.
--
-- Answered "guard the chain". Insert and delete are revoked from
-- clients and their policies dropped: the two functions make an
-- estimate and nothing in the app deletes one. A trigger refuses a
-- client's own statement -- role `authenticated` or `anon`, at the top
-- trigger depth -- that changes a superseded estimate at all, or that
-- writes `org_id`, `fiscal_year_id`, `year_of_assessment`, `form`,
-- `revises_id`, `revision_month`, `status` or `created_by` on any. The
-- functions run as their owner and pass. NOT security definer. The
-- dialog's six fields on the live estimate are as before.
--
-- Production held no estimates on 12 October.
-- =====================================================================

revoke insert, delete on public.tax_estimates from authenticated, anon;
drop policy if exists tax_estimates_insert on public.tax_estimates;
drop policy if exists tax_estimates_delete on public.tax_estimates;

create or replace function app.a_tax_estimate_is_kept()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  -- What opening and revising decide. The rest is the dialog's.
  c_chain constant text[] := array[
    'org_id', 'fiscal_year_id', 'year_of_assessment', 'form',
    'revises_id', 'revision_month', 'status', 'created_by'];
  v_old jsonb;
  v_new jsonb;
  v_col text;
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return new;
  end if;

  if old.status = 'superseded' then
    raise exception
      'This % for year of assessment % was replaced by a revision, and '
      'the instalments that fell due before it are still payable at what '
      'it said. Change the revision instead.',
      old.form, old.year_of_assessment
      using errcode = '42501';
  end if;

  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  foreach v_col in array c_chain loop
    if v_new -> v_col is distinct from v_old -> v_col then
      raise exception
        'The % of this % for year of assessment % is set when it is '
        'opened or revised, not by hand.',
        v_col, old.form, old.year_of_assessment
        using errcode = '42501';
    end if;
  end loop;

  return new;
end $$;

revoke all on function app.a_tax_estimate_is_kept() from public, anon, authenticated;

comment on function app.a_tax_estimate_is_kept() is
  'On tax_estimates: refuses a client''s own change to a superseded '
  'estimate, and to the columns opening and revising decide -- org, '
  'year, year of assessment, form, the estimate revised and the month, '
  'status and who made it. The dialog''s six fields on the live '
  'estimate stay the client''s. 0827.';

create trigger a_tax_estimate_is_kept
  before update on public.tax_estimates
  for each row execute function app.a_tax_estimate_is_kept();

comment on table public.tax_estimates is
  'A CP204 estimate for a basis period, and its revisions. A revision '
  'is a new row pointing at the one it replaces -- CP204A is its own '
  'form, and overwriting the original would lose the figure the 85% '
  'floor is measured against. MADE ONLY BY FUNCTION -- 0827 revoked '
  'insert and delete from clients: open_tax_estimate and '
  'revise_tax_estimate make one, and a_tax_estimate_is_kept keeps a '
  'superseded one and the columns they decide.';
