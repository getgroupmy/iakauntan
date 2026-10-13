-- =====================================================================
-- iAkauntan :: 0878 each side writes its own
--
-- The README's table of roles gives Sales and Purchasing "their own
-- documents". Nothing made it so: both roles pass `can_write`, and with
-- no access type `module_access` answers both `write` for sales and for
-- purchases, so either could raise the other side's paper.
--
-- Measured on 13 October 2026, locally, with the role `authenticated`:
-- a `purchaser` raised a sales invoice, and a `sales` member raised a
-- supplier bill.
--
-- Production held no `sales` and no `purchaser` member on 13 October.
--
-- Answered "each writes only its own side". A trigger on each side's
-- documents, their lines and their payments refuses a client's own
-- statement by a member of the other side's role with no access type:
-- a salesperson writes no purchase document, line or supplier payment,
-- a purchaser no sales document, line or receipt. Both still read both
-- sides, and keep everything else. An access type, where the company
-- has given one, decides instead -- that is how a company lets one
-- person do both. NOT security definer, as `0822`'s: a definer would
-- always answer "the owner".
--
-- Client statements only, so a function that crosses sides on purpose
-- keeps its own guard: `settle_pos_stalls` bills the stall owners when
-- a cashier closes the till, `accept_intercompany_bill` books the other
-- company's invoice as a bill. Receipts and supplier payments are
-- recorded through `record_settlement`, which asks `can_post`.
-- =====================================================================

create or replace function app.writes_side(p_org_id uuid, p_side text)
returns boolean
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select not exists (
    select 1 from public.org_members m
     where m.org_id = p_org_id
       and m.user_id = auth.uid()
       and m.access_type_id is null
       and m.role = case p_side
                      when 'sales'     then 'purchaser'::app.member_role
                      when 'purchases' then 'sales'::app.member_role
                    end);
$$;

revoke all on function app.writes_side(uuid, text) from public, anon;
grant execute on function app.writes_side(uuid, text) to authenticated, service_role;

comment on function app.writes_side(uuid, text) is
  'Whether the caller may write this side''s documents (''sales'' or ''purchases''): false only for a member of the other side''s role with no access type (0878).';

create or replace function app.each_side_writes_its_own()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_side text := tg_argv[0];
  v_org  uuid;
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  -- Written out by operation: `new` is not there to read on a delete.
  if tg_op = 'DELETE' then
    v_org := old.org_id;
  else
    v_org := new.org_id;
  end if;

  if not app.writes_side(v_org, v_side) then
    if v_side = 'purchases' then
      raise exception
        'A salesperson does not write purchase documents or supplier '
        'payments. An access type can give them the purchases side.'
        using errcode = '42501';
    else
      raise exception
        'A purchaser does not write sales documents or receipts. An '
        'access type can give them the sales side.'
        using errcode = '42501';
    end if;
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

do $$
declare
  t record;
begin
  for t in
    select * from (values
      ('sales_documents', 'sales'), ('sales_document_lines', 'sales'),
      ('receipts', 'sales'),
      ('purchase_documents', 'purchases'),
      ('purchase_document_lines', 'purchases'),
      ('purchase_payments', 'purchases')) as v(tbl, side)
  loop
    execute format(
      'create trigger each_side_writes_its_own
         before insert or update or delete on public.%I
         for each row execute function app.each_side_writes_its_own(%L)',
      t.tbl, t.side);
  end loop;
end $$;
