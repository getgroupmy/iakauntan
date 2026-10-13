-- =====================================================================
-- iAkauntan :: 0866 a commission rate is the ledger's
--
-- `report_sales_by_person` turns each salesperson's `commission_rate`
-- into the commission their sales imply, and since `0105` it has
-- answered only a member `app.can_read_ledger` admits. The rate itself
-- was read by every member (`salespeople_select` is `is_org_member`)
-- and written by every member who may write (`salespeople_update` is
-- `can_write`) -- a salesman among them, of his own rate.
--
-- Measured on 13 October 2026, locally, as a `sales` member named on a
-- salesperson, with the role `authenticated`: he read his own rate,
-- 2.5%, and a colleague's, 4%; raised his own to 25% and cut hers to
-- nothing; and was refused the report that would have turned 25% into
-- what the company owes him. The Salespeople screen printed that
-- refusal to him as it came, a raw error.
--
-- Production had no salespeople on 13 October.
--
-- Answered "rates are the ledger's":
--
--   * `authenticated` reads every column of `salespeople` but the rate,
--     as `0856` did for an account's balance: the invoice's salesperson
--     picker names people, and needs nothing else.
--   * `salesperson_commission_rates(org)`, a definer, gives the rates to
--     a member `can_read_ledger` admits, and to nobody else.
--   * A trigger refuses a client's own statement that sets a rate on a
--     new salesperson or changes one on an old, unless `can_post`
--     admits the member -- the owner, an admin, an accountant: whoever
--     would pay it. Every other column stays writable by a writer, as
--     before. NOT security definer, as `0822`'s: a definer would always
--     answer "the owner".
-- =====================================================================

revoke select on public.salespeople from authenticated;
grant select (id, org_id, code, name, employee_id, member_id, email,
              phone, notes, is_active, created_at, updated_at)
  on public.salespeople to authenticated;

create or replace function public.salesperson_commission_rates(p_org_id uuid)
returns table (salesperson_id uuid, commission_rate numeric)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select s.id, s.commission_rate
    from public.salespeople s
   where s.org_id = p_org_id
     and app.can_read_ledger(p_org_id)
   order by s.name;
$$;

revoke all on function public.salesperson_commission_rates(uuid)
  from public, anon;
grant execute on function public.salesperson_commission_rates(uuid)
  to authenticated, service_role;

comment on function public.salesperson_commission_rates(uuid) is
  'Each salesperson''s commission rate, for a member who reads the '
  'ledger; nothing for anybody else. The column itself is not '
  'readable by authenticated.';

create or replace function app.commission_rate_is_the_ledgers()
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

  if (tg_op = 'INSERT' and new.commission_rate is not null)
     or (tg_op = 'UPDATE'
         and new.commission_rate is distinct from old.commission_rate) then
    if not app.can_post(new.org_id) then
      raise exception
        'A commission rate is set by whoever would pay it: the owner, an '
        'admin or an accountant.'
        using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

create trigger commission_rate_is_the_ledgers
  before insert or update on public.salespeople
  for each row execute function app.commission_rate_is_the_ledgers();
