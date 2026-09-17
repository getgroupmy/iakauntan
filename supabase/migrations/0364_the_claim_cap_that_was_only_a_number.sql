-- =====================================================================
-- iAkauntan :: 0364 the claim cap that was only a number
--
-- `claim_types` carries `per_claim_cap`, `monthly_cap` and `annual_cap`.
-- The HR setup screen offers the first two and prints "up to RM 200"
-- beside the type. No SQL has ever read any of the three.
--
-- That is the worst shape a dead column can take, and worse than the
-- ones the earlier passes found. `credit_hold` did nothing and nothing
-- said otherwise; this is a screen that shows a limit next to a claim
-- type, so somebody configures it believing claims above it will be
-- stopped, and none is. The company finds out when it reads the ledger
-- rather than when somebody claims.
--
-- ---------------------------------------------------------------------
-- Where it fires, which took two goes
--
-- The obvious place is the claim becoming `submitted`. That alone is
-- useless here, and the reason is worth recording: `createClaim`
-- inserts the claim row as `submitted` **and then** inserts its lines,
-- so a trigger on the claim sees a claim with nothing on it and passes.
-- The first version of this migration did exactly that and every test
-- went green.
--
-- So the check hangs off the lines as well, and both triggers call the
-- same function. The line trigger is `after` rather than `before`
-- because a multi-row insert has to have finished for the total to be
-- the total; each row before the last sees a smaller figure, which can
-- only under-report and never refuse something it should not.
--
-- A draft is still left alone. Refusing the third line of five while
-- somebody is typing would stop them entering the fourth, which might
-- be a different type entirely.
--
-- ---------------------------------------------------------------------
-- What counts towards the monthly and annual figures
--
-- Every other claim by the same employee for the same type, in the same
-- calendar month or year as this claim's date, that has not been
-- rejected or cancelled and is not still a draft. A draft is not a
-- request and a rejected claim is not money. The claim being submitted
-- is excluded from the query and added on afterwards, so re-submitting
-- one does not count it twice.
--
-- The window is the calendar month and year of `claim_date`, which is
-- when the money was spent rather than when the form was filled in.
-- Somebody submitting January's petrol in February has spent January's
-- allowance.
--
-- ---------------------------------------------------------------------
-- `requires_receipt` is deliberately not enforced here
--
-- The receipt is an `attachments` row against the claim, not against
-- the line, so "this type needs a receipt" and "this claim has one"
-- are questions at different grains: one attachment on a five-line
-- claim satisfies it, or does not, and which is a policy decision
-- rather than a bug to fix in passing. Left alone, and written down.
-- =====================================================================

create or replace function app.assert_claim_caps(p_claim uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  r         record;
  v_already numeric;
  new       public.expense_claims;
begin
  select * into new from public.expense_claims where id = p_claim;
  if new.id is null or new.status <> 'submitted' then
    return;
  end if;

  for r in
    select ct.id, ct.name,
           ct.per_claim_cap, ct.monthly_cap, ct.annual_cap,
           sum(l.amount) as claimed
      from public.expense_claim_lines l
      join public.claim_types ct on ct.id = l.claim_type_id
     where l.claim_id = new.id
     group by ct.id, ct.name, ct.per_claim_cap, ct.monthly_cap, ct.annual_cap
  loop
    if coalesce(r.per_claim_cap, 0) > 0 and r.claimed > r.per_claim_cap then
      raise exception
        '% on this claim comes to %, and % is capped at % per claim.',
        r.name, to_char(r.claimed, 'FM999999990.00'), r.name,
        to_char(r.per_claim_cap, 'FM999999990.00')
        using errcode = '23514';
    end if;

    if coalesce(r.monthly_cap, 0) > 0 then
      select coalesce(sum(l.amount), 0) into v_already
        from public.expense_claim_lines l
        join public.expense_claims c on c.id = l.claim_id
       where c.employee_id = new.employee_id
         and c.id <> new.id
         and c.status in ('submitted', 'approved')
         and l.claim_type_id = r.id
         and date_trunc('month', c.claim_date)
             = date_trunc('month', new.claim_date);
      if v_already + r.claimed > r.monthly_cap then
        raise exception
          '% for % is capped at % a month, and this would take it to %.',
          r.name, to_char(new.claim_date, 'Mon YYYY'),
          to_char(r.monthly_cap, 'FM999999990.00'),
          to_char(v_already + r.claimed, 'FM999999990.00')
          using errcode = '23514';
      end if;
    end if;

    if coalesce(r.annual_cap, 0) > 0 then
      select coalesce(sum(l.amount), 0) into v_already
        from public.expense_claim_lines l
        join public.expense_claims c on c.id = l.claim_id
       where c.employee_id = new.employee_id
         and c.id <> new.id
         and c.status in ('submitted', 'approved')
         and l.claim_type_id = r.id
         and date_trunc('year', c.claim_date)
             = date_trunc('year', new.claim_date);
      if v_already + r.claimed > r.annual_cap then
        raise exception
          '% for % is capped at % for the year, and this would take it '
          'to %.',
          r.name, to_char(new.claim_date, 'YYYY'),
          to_char(r.annual_cap, 'FM999999990.00'),
          to_char(v_already + r.claimed, 'FM999999990.00')
          using errcode = '23514';
      end if;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- The two ways a claim comes to be over its cap
-- ---------------------------------------------------------------------
create or replace function app.claim_caps_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
begin
  if tg_table_name = 'expense_claims' then
    -- The transition into submitted, and only that. An approval that
    -- touches the row again must not re-litigate a cap the company has
    -- already accepted.
    if new.status = 'submitted'
       and (tg_op = 'INSERT' or old.status is distinct from 'submitted') then
      perform app.assert_claim_caps(new.id);
    end if;
  else
    perform app.assert_claim_caps(new.claim_id);
  end if;
  return new;
end $$;

drop trigger if exists enforce_claim_caps on public.expense_claims;
create trigger enforce_claim_caps
  after insert or update on public.expense_claims
  for each row execute function app.claim_caps_trigger();

drop trigger if exists enforce_claim_caps on public.expense_claim_lines;
create trigger enforce_claim_caps
  after insert or update on public.expense_claim_lines
  for each row execute function app.claim_caps_trigger();

revoke all on function app.assert_claim_caps(uuid) from public, anon, authenticated;
revoke all on function app.claim_caps_trigger() from public, anon, authenticated;

comment on function app.assert_claim_caps(uuid) is
  'Refuses a claim over its type''s per-claim, monthly or annual cap, '
  'on the transition into submitted. The window is the calendar month '
  'and year of claim_date — when the money was spent, not when the '
  'form was filled in.';
