-- =====================================================================
-- iAkauntan :: 0928 a landed cost run follows its goods
--
-- A landed cost run puts freight onto stock: its stock movement and
-- its journal are both dated by the run. `upsert_landed_cost_run`
-- takes any date, and `post_landed_cost_run` posts on it.
--
-- Measured on 24 November 2026, locally, as the owner with the role
-- `authenticated`: a hundred tiles billed and received today; a run
-- over that bill dated sixty days ago posted its journal and its
-- movement on that day. The stock card for the day before the goods
-- arrived reads nothing on hand worth RM50, and the freight came off
-- 5400 two months before it was spent.
--
-- Production on 24 November: no landed cost run at all.
--
-- Answered "not before goods arrived", for every writer. A run may not
-- be dated before the latest receipt of the goods on any bill it
-- spreads over: the bill's own receipt, or -- where the bill was raised
-- from a goods received note, which received the stock and leaves the
-- bill none of its own -- the note's. A bill with no receipt found is
-- taken at its own date. Asked when a bill is put on a run -- which
-- `upsert_landed_cost_run` does for every bill on every save, after
-- it has set the run's date -- and again when the run is posted,
-- which catches a date changed by any other writer. Not when the date
-- alone changes: the save sets the date before it puts the bills back,
-- so a run moved earlier with its latest bill taken off would be
-- asked about a bill it no longer spreads over. `0888` and `0893` ask
-- the same of a reversal and of a tax payment.
-- =====================================================================

create or replace function app.landed_cost_goods_arrived(p_bill uuid)
returns date
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  -- When the goods on a bill were on the shelf: its latest receipt, or
  -- its goods received note's, or failing both its own date.
  select coalesce(
           (select max(m.movement_date)
              from public.stock_movements m
             where m.source_table = 'purchase_documents'
               and m.source_id in (d.id, d.parent_id)
               and m.quantity > 0),
           d.doc_date)
    from public.purchase_documents d
   where d.id = p_bill;
$$;

revoke all on function app.landed_cost_goods_arrived(uuid) from public, anon, authenticated;

comment on function app.landed_cost_goods_arrived(uuid) is
  'The date the goods on a bill were on the shelf: its latest receipt, '
  'or that of the goods received note it was raised from, or failing '
  'both its own date. 0928.';

create or replace function app.a_landed_cost_run_follows_its_goods()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_run     public.landed_cost_runs;
  v_doc_no  text;
  v_arrived date;
begin
  -- SECURITY DEFINER because it reads the stock movements, and a writer
  -- who may not read them must not be waved through by reading none.
  if tg_table_name = 'landed_cost_targets' then
    select * into v_run from public.landed_cost_runs r where r.id = new.run_id;
    select d.doc_no, app.landed_cost_goods_arrived(d.id)
      into v_doc_no, v_arrived
      from public.purchase_documents d
     where d.id = new.bill_id and d.org_id = new.org_id;
  else
    -- A run: asked when it is posted.
    if not (new.status = 'posted' and old.status is distinct from 'posted') then
      return new;
    end if;
    v_run := new;
    select d.doc_no, x.arrived
      into v_doc_no, v_arrived
      from public.landed_cost_targets t
      join public.purchase_documents d on d.id = t.bill_id
      cross join lateral (select app.landed_cost_goods_arrived(d.id) as arrived) x
     where t.run_id = new.id
     order by x.arrived desc, d.doc_no
     limit 1;
  end if;

  if v_arrived is not null and v_run.run_date < v_arrived then
    raise exception
      'Landed cost run % is dated %, before the goods on bill % arrived on '
      '%: freight can only go onto stock that is there. Date the run on '
      'or after %.',
      v_run.run_no, v_run.run_date, v_doc_no, v_arrived, v_arrived
      using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function app.a_landed_cost_run_follows_its_goods() from public, anon, authenticated;

comment on function app.a_landed_cost_run_follows_its_goods() is
  'Refuses, for every writer, a landed cost run dated before the goods '
  'on any bill it spreads over arrived: when a bill is put on it, and '
  'when it is posted. 0928.';

create trigger a_landed_cost_run_follows_its_goods
  before insert or update of bill_id, run_id on public.landed_cost_targets
  for each row execute function app.a_landed_cost_run_follows_its_goods();

create trigger a_landed_cost_run_follows_its_goods
  before update of status on public.landed_cost_runs
  for each row execute function app.a_landed_cost_run_follows_its_goods();
