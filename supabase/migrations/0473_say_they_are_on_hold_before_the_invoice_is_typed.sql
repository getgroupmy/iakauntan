-- ---------------------------------------------------------------------
-- 0473  Say they are on hold before the invoice is typed
-- ---------------------------------------------------------------------
-- `app.enforce_credit_limit` refuses to post an invoice to a customer
-- on credit hold, and it refuses first: above the credit-control mode,
-- above the limit arithmetic, above everything. Somebody ticked the box
-- against this customer, and the trigger takes that literally.
--
-- The screen did not. `customer_credit_status` -- the only thing the
-- document editor asks -- returned `control`, `credit_limit`,
-- `outstanding`, `available` and `over_limit`, and no hold at all. The
-- banner then went quiet in three separate ways:
--
--   * `limit <= 0` returned nothing, and a customer on hold usually has
--     no limit set, because the hold *is* the decision;
--   * `control == 'off'` returned nothing, though a hold is refused in
--     every mode;
--   * and even with a limit and a mode, the banner stayed quiet until
--     the balance was within a tenth of the limit.
--
-- So the common case -- on hold, no limit -- was: type the whole
-- invoice, price it, add the lines, press Post, and be told to take the
-- hold off or raise it as a cash sale. Everything before that point was
-- wasted, and the one fact that would have saved it was known before
-- the customer was chosen.
--
-- `credit_hold` is now in what the function returns, beside the name of
-- the contact it belongs to. Reported plainly rather than folded into
-- `over_limit`: a limit is answered by raising it or taking a payment,
-- a hold by whoever put it on taking it off, and a screen that says
-- "over their credit limit" to somebody who has no limit sends them
-- looking in the wrong place.
--
-- ### Mutants
--
-- Two, restated into a built database and run against
-- `supabase/tests/credit_hold_is_visible.sql`:
--
--   * `credit_hold` dropped from the returned object -- killed by "the
--     screen is told about the hold", which reads the key rather than
--     its value, because a key that is absent and a key that is false
--     are the same thing to a client that writes `status['credit_hold']
--     == true` and the difference matters to nobody until the key comes
--     back null;
--   * the hold reported only when a limit is set (`v_hold and v_limit >
--     0`) -- killed by "and told about it when there is no limit at
--     all", which is the case the defect was actually about. Its own
--     assertion: a fix that reports the hold for customers who already
--     had a visible banner fixes nothing.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.customer_credit_status(p_contact_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_org         uuid;
  v_limit       numeric(18, 2);
  v_outstanding numeric(18, 2);
  v_control     text;
  v_hold        boolean;
  v_name        text;
begin
  select c.org_id, coalesce(c.credit_limit, 0),
         coalesce(c.credit_hold, false), c.name
    into v_org, v_limit, v_hold, v_name
    from public.contacts c where c.id = p_contact_id;
  if v_org is null then
    raise exception 'Contact % not found', p_contact_id using errcode = 'P0002';
  end if;
  if not app.is_org_member(v_org) then
    raise exception 'Not a member of organization %', v_org using errcode = '42501';
  end if;

  select credit_control into v_control
    from public.organizations where id = v_org;

  select coalesce(sum(d.balance_amount * coalesce(d.exchange_rate, 1)), 0)
    into v_outstanding
    from public.sales_documents d
   where d.org_id = v_org and d.contact_id = p_contact_id
     and d.gl_entry_id is not null and d.status <> 'void'
     and d.deleted_at is null;

  return jsonb_build_object(
    'control', coalesce(v_control, 'warn'),
    'credit_limit', v_limit,
    'outstanding', round(v_outstanding, 2),
    'available', case when v_limit <= 0 then null
                      else round(v_limit - v_outstanding, 2) end,
    'over_limit', v_limit > 0 and v_outstanding > v_limit,
    -- The hold, which this function did not report and
    -- `app.enforce_credit_limit` refuses on. Reported plainly rather
    -- than folded into `over_limit`: they are different facts with
    -- different answers -- a limit is raised or a payment taken, a hold
    -- is taken off by whoever put it on.
    'credit_hold', v_hold,
    'contact_name', v_name);
end;
$function$;

comment on function public.customer_credit_status(uuid) is
  'What the document editor needs to know before an invoice is typed: '
  'the credit-control mode, the limit, what is outstanding against it, '
  'and whether the customer is on credit hold. The hold is refused by '
  'app.enforce_credit_limit in every mode and at every limit, so it is '
  'reported the same way. See 0473.';

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_src text := pg_get_functiondef(
    to_regprocedure('public.customer_credit_status(uuid)'));
begin
  if position('''credit_hold''' in v_src) = 0 then
    raise exception
      '0473: the screen still cannot find out that a customer is on hold';
  end if;

  -- The refusal is unconditional in the trigger; reporting it
  -- conditionally would put the banner back where it was for exactly
  -- the customers who need it.
  if position('v_hold and' in v_src) <> 0
     or position('and v_hold' in v_src) <> 0 then
    raise exception
      '0473: the hold is reported only under some condition, and the '
      'trigger refuses it under all of them';
  end if;
end
$do$;
