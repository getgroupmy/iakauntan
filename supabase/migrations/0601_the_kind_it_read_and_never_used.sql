-- =====================================================================
-- iAkauntan :: 0601 the kind it read, and never used
--
-- `deposit_history` resolves the deposit's `kind` into a variable on
-- its second line and never looks at it again.
--
--     select n.org_id, n.kind::text into v_org, v_kind
--       from public.deposit_notes n where n.id = p_id;
--     ...
--     if not app.can_read_module(v_org, 'sales')
--        and not app.can_read_module(v_org, 'purchases') then
--       raise exception 'not permitted to read this organization';
--     end if;
--
-- An unused variable is usually nothing. This one is the whole check
-- somebody meant to write, and the guard that replaced it CANNOT FIRE.
--
-- `sales` is a CORE module: `app.has_module` returns true for it before
-- it looks at `org_modules` at all, for every company there is. So
-- `not can_read_module(org, 'sales')` is always false, and
-- `false and anything` is false -- the whole `if` is dead code. Two
-- tells in five lines: a variable read and thrown away, and a refusal
-- that has never once been raised.
--
-- What that leaves open is the other side. `purchases` is NOT core, so
-- a company can have it switched off, or let it expire -- `has_module`
-- checks `expires_at` -- and a SUPPLIER deposit already in the books
-- stays readable through this function afterwards. Reproduced: with
-- Purchases off, `deposit_notes_list` returns nothing,
-- `deposits_held_for` returns nothing, and `deposit_history` hands back
-- the event, its date, its amount and its free-text reason:
--
--     forfeit / 2026-09-16 / 700.00 / Supplier kept the advance
--
-- Its three siblings all make the check it does not:
--
--     and ((n.kind = 'customer'  and app.can_read_module(org, 'sales'))
--       or (n.kind = 'supplier' and app.can_read_module(org, 'purchases')))
--
-- `deposit_notes_list`, `deposits_held_for` and both `pdc_*` functions
-- carry that line. `deposit_history` carries `v_kind` instead.
--
-- The customer half of the fix below is a no-op today, for the same
-- reason the old guard was: `sales` is core. It is written anyway,
-- because the day Sales stops being core is not a day anybody will
-- remember to come back here.
--
-- ---------------------------------------------------------------------
-- Why it refuses the way it does
--
-- The siblings are lists, so filtering a row out is the natural answer
-- and the caller sees nothing. This one takes an id, and there the
-- choice of refusal is the leak.
--
-- Raising 42501 for a deposit the caller may not read, while an id that
-- does not exist raises P0002, tells the caller WHICH UUIDS ARE REAL --
-- one guess at a time, by reading which refusal comes back. `0596` made
-- exactly this point about `link_group_contact`, where the two answers
-- would have told somebody which companies exist.
--
-- So a deposit of a kind this caller has no module for raises the SAME
-- 'No such deposit.' as an id that was never issued. There is nothing
-- to tell apart.
--
-- The org check stays where it is and stays first. It is about the
-- company rather than the row, it is the answer the siblings give, and
-- while `sales` is core it cannot fire -- which is an argument for
-- leaving it, not for deleting it. A defence removed because today's
-- data makes it unreachable is a defence that is missing on the day
-- the data changes.
--
-- ---------------------------------------------------------------------
-- How it was found
--
-- Not by reading it. `docs/api/` publishes one module per function,
-- taken from the first `can_*_module` in the body, and a sweep for
-- functions that check MORE THAN ONE turned up thirteen -- where the
-- published name is at best half the answer. `deposit_history` was on
-- that list because it names `sales` and `purchases`, and reading it to
-- write an honest description is what showed the second one is never
-- really asked.
-- =====================================================================

create or replace function public.deposit_history(p_id uuid)
returns table(happened text, on_date date, amount numeric,
              document text, reason text)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $function$
declare v_org uuid; v_kind text;
begin
  select n.org_id, n.kind::text into v_org, v_kind
    from public.deposit_notes n where n.id = p_id;
  if v_org is null then
    raise exception 'No such deposit.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_org, 'sales')
     and not app.can_read_module(v_org, 'purchases') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  -- The check `v_kind` was read for. A customer deposit belongs to
  -- Sales and a supplier one to Purchases, and having the other module
  -- is not having this one.
  --
  -- Answered as P0002 and not 42501 on purpose: see the header. A
  -- refusal that distinguishes "not yours" from "not there" is a way to
  -- discover which ids are real.
  if not ((v_kind = 'customer' and app.can_read_module(v_org, 'sales'))
       or (v_kind = 'supplier' and app.can_read_module(v_org, 'purchases')))
  then
    raise exception 'No such deposit.' using errcode = 'P0002';
  end if;
  return query
    select 'applied', d.doc_date, a.amount, d.doc_no, null::text
      from public.payment_allocations a
      join public.sales_documents d on d.id = a.invoice_id
     where a.deposit_id = p_id
    union all
    select 'applied', d.doc_date, a.amount, d.doc_no, null::text
      from public.payment_allocations a
      join public.purchase_documents d on d.id = a.bill_id
     where a.deposit_id = p_id
    union all
    select e.kind::text, e.event_date, e.amount, null::text, e.reason
      from public.deposit_events e
     where e.deposit_id = p_id
     order by 2, 1;
end;
$function$;

-- `0165` strips them on create-or-replace in this schema.
revoke all on function public.deposit_history(uuid) from public, anon;
grant execute on function public.deposit_history(uuid) to authenticated;

comment on function public.deposit_history(uuid) is
  'Everything that has happened to one deposit: what it was applied '
  'to, with the document number and date, and every event against it '
  'with its reason. NEEDS THE MODULE THE DEPOSIT''S OWN KIND BELONGS '
  'TO -- `sales` for a customer deposit, `purchases` for a supplier '
  'one -- and having the other is not having this one. A deposit the '
  'caller has no module for answers the same "No such deposit." as an '
  'id that was never issued, so the refusal cannot be used to find out '
  'which ids are real.';
