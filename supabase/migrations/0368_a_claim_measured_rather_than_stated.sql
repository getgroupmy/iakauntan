-- =====================================================================
-- iAkauntan :: 0368 a claim measured rather than stated
--
-- `claim_types` says a type may be `is_mileage`, with a `rate_per_unit`
-- and a `unit_label`, and `expense_claim_lines` carries `quantity` and
-- `rate` for exactly that. None of the five has ever been read or
-- written. So a company reimbursing sixty sen a kilometre had to have
-- its people do the multiplication in their heads and type the ringgit,
-- and the claim recorded a figure with no working behind it.
--
-- That is not merely inconvenient. `0364` caps a mileage claim by the
-- ringgit it states, so a typo — 640 for 64 — is caught only if it
-- happens to cross a cap; the distance, which is the thing anybody
-- could check against a map, was never recorded at all. An approver
-- looking at "RM 64.00, client visit" has nothing to approve except the
-- number.
--
-- ---------------------------------------------------------------------
-- The rate is stamped, not looked up later
--
-- `rate` is on the line as well as the type, and the line's copy is the
-- one the arithmetic uses. A company that raises its rate from sixty
-- sen to seventy must not thereby restate every claim anybody filed
-- last year — the amount was agreed at the rate of the day, and a
-- report that re-multiplies is a report that disagrees with the
-- payslip that paid it.
--
-- So the line takes the type's rate when it does not carry one, and
-- keeps it thereafter.
--
-- ---------------------------------------------------------------------
-- And the amount stops being somebody's arithmetic
--
-- For a mileage line the amount is the product, computed here, and what
-- was typed is ignored. There is no honest way to accept both: two
-- numbers that should agree and are stored separately are two numbers
-- that will not, and the one nobody notices is the one that gets paid.
-- =====================================================================

create or replace function app.price_mileage_line()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_type public.claim_types;
begin
  if new.claim_type_id is null then
    return new;
  end if;
  select * into v_type from public.claim_types where id = new.claim_type_id;
  if v_type.id is null or not coalesce(v_type.is_mileage, false) then
    return new;
  end if;

  if coalesce(new.quantity, 0) <= 0 then
    raise exception
      '% is claimed by the %, so say how many.',
      v_type.name, coalesce(nullif(btrim(v_type.unit_label), ''), 'unit')
      using errcode = '23514';
  end if;

  -- The type's rate, once, at the moment the line is written.
  new.rate := coalesce(new.rate, v_type.rate_per_unit);
  if coalesce(new.rate, 0) <= 0 then
    raise exception
      'No rate is set for %. Put one on the claim type before claiming '
      'against it.', v_type.name
      using errcode = '23514';
  end if;

  new.amount := round(new.quantity * new.rate, 2);
  return new;
end $$;

drop trigger if exists price_mileage_line on public.expense_claim_lines;
create trigger price_mileage_line
  before insert or update on public.expense_claim_lines
  for each row execute function app.price_mileage_line();

revoke all on function app.price_mileage_line()
  from public, anon, authenticated;

comment on function app.price_mileage_line() is
  'Prices a mileage claim line as quantity times rate, stamping the '
  'type''s rate onto the line the first time so a later change to the '
  'rate does not restate claims already filed. What was typed as the '
  'amount is ignored: two numbers that should agree and are stored '
  'separately are two numbers that will not.';

comment on column public.claim_types.rate_per_unit is
  'What one unit is reimbursed at — sixty sen a kilometre, and so on. '
  'Copied onto each line as it is written rather than looked up at '
  'report time, so raising it does not restate last year''s claims.';
