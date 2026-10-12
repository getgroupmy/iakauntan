-- =====================================================================
-- iAkauntan :: 0836 a relief is claimed within its ceiling
--
-- `tax_computation_individual` (`0666`) works out a Form B or BE: the
-- reliefs in `tax_relief_claims` come off total income, summed as they
-- were typed. The claim dialog picks a relief from `0025`'s catalogue
-- and shows its ceiling under the box -- "At most RM2,500.00 -- enter
-- what was actually incurred" -- and nothing refused more. It is the
-- gap `0408` closed for PCB, "the relief ceiling that was only a helper
-- text", in the other place a relief is claimed.
--
-- Measured on 12 October 2026, locally, as the owner with the role
-- `authenticated`, on a Form B with RM120,000 of statutory income:
-- individual RM9,000, EPF RM4,000 and lifestyle RM2,500 give a tax of
-- RM10,525. Lifestyle typed as 25,000 gave RM5,980 -- RM4,545 too
-- little; lifestyle and individual each claimed twice gave RM8,070.
-- Every one was accepted.
--
-- Answered "cap each relief's total": a claim that would take a
-- relief's total on the computation above its ceiling -- in the PCB
-- schedule in force at the basis period's end, the one the dialog
-- offers from -- is refused, whether it is one claim over the ceiling
-- or the same relief claimed twice. A claim with no relief code (the
-- dialog's "something else") and a relief with no ceiling (the
-- children's, which are per child) are taken as typed. With no
-- schedule for the year the trigger stands aside, as `0408`'s does.
--
-- Production held no computation and no claim on 12 October.
-- =====================================================================

create or replace function app.a_relief_claimed_within_its_ceiling()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_end    date;
  v_sched  public.statutory_schedules;
  v_relief public.tax_reliefs;
  v_total  numeric;
begin
  if NEW.relief_code is null then
    return NEW;
  end if;

  select fy.end_date into v_end
    from public.tax_computations tc
    join public.fiscal_years fy on fy.id = tc.fiscal_year_id
   where tc.id = NEW.computation_id;

  v_sched := app.statutory_schedule_on('pcb', v_end);
  if v_sched.id is null then
    return NEW;
  end if;

  select * into v_relief
    from public.tax_reliefs r
   where r.schedule_id = v_sched.id and r.code = NEW.relief_code;
  if v_relief.id is null or v_relief.max_amount is null then
    return NEW;
  end if;

  -- Everything claimed under the code on this computation, this claim
  -- as it will stand included.
  select coalesce(sum(rc.amount), 0) + NEW.amount into v_total
    from public.tax_relief_claims rc
   where rc.computation_id = NEW.computation_id
     and rc.relief_code = NEW.relief_code
     and rc.id is distinct from NEW.id;

  if v_total > v_relief.max_amount then
    raise exception
      'LHDN allows up to RM% on % for the year to %; this would claim '
      'RM% under it on this computation.',
      to_char(v_relief.max_amount, 'FM999G999G990D00'),
      NEW.relief_code, v_end,
      to_char(v_total, 'FM999G999G990D00')
      using errcode = '23514';
  end if;
  return NEW;
end $$;

revoke all on function app.a_relief_claimed_within_its_ceiling()
  from public, anon, authenticated;

comment on function app.a_relief_claimed_within_its_ceiling() is
  'On tax_relief_claims: refuses a claim that takes a relief''s total on '
  'a Form B or BE computation above its ceiling in the PCB schedule in '
  'force at the basis period''s end. Uncoded claims and reliefs without '
  'a ceiling are taken as typed. 0836.';

create trigger a_relief_claimed_within_its_ceiling
  before insert or update on public.tax_relief_claims
  for each row execute function app.a_relief_claimed_within_its_ceiling();
