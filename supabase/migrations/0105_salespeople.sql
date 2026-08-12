-- =====================================================================
-- iAkauntan :: 0105 the salesperson column that nothing ever filled in
--
-- `sales_documents.salesperson_id` has been in the schema since 0005
-- with no screen, no report, and not one row carrying a value on the
-- hosted database. Somebody meant commission or attribution and stopped.
--
-- It did have a foreign key, and finding it changed this migration. The
-- column references **`auth.users(id)`** — so a salesperson had to be
-- somebody with a login, and `auth.users` is global, which means the key
-- permitted one organization's invoice to name another organization's
-- user and no policy on `sales_documents` would have noticed. A
-- constraint that admits the wrong rows is not much better than none.
--
-- ---------------------------------------------------------------------
-- Why a table of its own rather than pointing at people who exist
--
-- Three candidates, and the original is the weakest.
--
-- `auth.users`, as built, only credits people who can sign in, and does
-- not respect the tenant boundary. An agent who sells on commission and
-- never touches the software is exactly the person a small Malaysian
-- business most wants to track, and is precisely who this excludes.
--
-- `employees` is where a salesperson usually lives, and commission
-- eventually has to reach payroll. But HR is an entitlement — an
-- organization without that module has no employee rows at all, and
-- pointing there would make the field permanently empty for them.
--
-- `org_members` is universal within an organization but still only
-- covers people with an account.
--
-- So: a small table of its own, org-scoped, with optional links to an
-- employee and to a member. A salesperson can be an employee, a member,
-- neither, or in time both, and none of that is forced at the moment
-- somebody wants to record who won the order.
--
-- ---------------------------------------------------------------------
-- On the commission rate
--
-- Recorded here and **posted nowhere**. `report_sales_by_person` works
-- out what the rate implies and says so, and no journal is written, no
-- liability is raised, and nothing reaches payroll. Commission that is
-- earned on invoice, on payment, or on margin — net of credit notes or
-- not, on a threshold or not — is a policy decision this migration has
-- no business inventing, and a figure accrued on a guess is worse than
-- no figure at all. The report is a working paper. It says so.
-- =====================================================================

create table if not exists public.salespeople (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organizations (id) on delete cascade,
  code         text not null,
  name         text not null,
  -- Both optional, and both `on delete set null`: an employee who leaves
  -- must not take last year's sales attribution with them. The documents
  -- keep pointing at the salesperson; the salesperson stops pointing at
  -- a personnel record.
  employee_id  uuid references public.employees (id) on delete set null,
  member_id    uuid references public.org_members (id) on delete set null,
  -- A percentage, not a fraction. 2.5 means two and a half per cent,
  -- because that is what somebody types, and the one place it is used
  -- divides by 100 in full view.
  commission_rate numeric(6, 3) check (commission_rate >= 0 and commission_rate <= 100),
  email        text,
  phone        text,
  notes        text,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (org_id, code)
);

create index if not exists salespeople_org_active_idx
  on public.salespeople (org_id, is_active);

alter table public.salespeople enable row level security;

drop policy if exists salespeople_select on public.salespeople;
create policy salespeople_select on public.salespeople
  for select to authenticated using (app.is_org_member(org_id));
drop policy if exists salespeople_insert on public.salespeople;
create policy salespeople_insert on public.salespeople
  for insert to authenticated with check (app.can_write(org_id));
drop policy if exists salespeople_update on public.salespeople;
create policy salespeople_update on public.salespeople
  for update to authenticated
  using (app.can_write(org_id)) with check (app.can_write(org_id));
drop policy if exists salespeople_delete on public.salespeople;
create policy salespeople_delete on public.salespeople
  for delete to authenticated using (app.can_admin(org_id));

-- ---------------------------------------------------------------------
-- Repoint the column
--
-- The original key to `auth.users` goes. Leaving it would not merely be
-- untidy: with both constraints in place a value would have to exist in
-- `auth.users` *and* in `salespeople` at once, which nothing can satisfy
-- — the column would go from unused to unusable, and the failure would
-- arrive as a foreign key violation on saving an invoice.
--
-- Safe to swap outright: every row on the hosted database has this null,
-- so there is nothing to migrate across. Anyone who did populate it
-- against a user id would need those users represented as salespeople
-- first; the count was checked before this ran.
--
-- `on delete set null` rather than restrict — deleting a salesperson
-- should not be blocked by history, and it should not rewrite history
-- either. The invoice keeps its figures and loses its attribution, which
-- is the honest outcome.
--
-- A trigger as well as the key, because a key alone still lets one
-- organization's document be credited to another organization's
-- salesperson — the same hole the `auth.users` key had, and it would be
-- a shame to rebuild it. RLS would hide the row on read and the join
-- would come back empty, which looks like "no salesperson" rather than
-- like the cross-tenant reference it is.
-- ---------------------------------------------------------------------
alter table public.sales_documents
  drop constraint if exists sales_documents_salesperson_id_fkey;
alter table public.sales_documents
  drop constraint if exists sales_documents_salesperson_fk;
alter table public.sales_documents
  add constraint sales_documents_salesperson_fk
  foreign key (salesperson_id) references public.salespeople (id)
  on delete set null;

create or replace function app.check_salesperson_org()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp as $$
begin
  if new.salesperson_id is not null
     and not exists (select 1 from public.salespeople s
                      where s.id = new.salesperson_id
                        and s.org_id = new.org_id) then
    raise exception 'That salesperson belongs to another organization'
      using errcode = '23503';
  end if;
  return new;
end;
$$;

drop trigger if exists sales_documents_salesperson_org on public.sales_documents;
create trigger sales_documents_salesperson_org
  before insert or update of salesperson_id, org_id on public.sales_documents
  for each row execute function app.check_salesperson_org();

-- ---------------------------------------------------------------------
-- What each of them sold
--
-- Invoices less credit notes, which is the only figure worth putting a
-- commission rate against: crediting a sale back out and still paying
-- commission on it is how a business pays twice for one mistake.
--
-- Posted documents only. A draft invoice is not a sale, and a voided one
-- never was.
--
-- Everything is in base currency at each document's own rate, for the
-- same reason the statement is: adding USD 10,000 to RM 5,000 and
-- printing 15,000 is the arithmetic every report here exists to avoid.
-- ---------------------------------------------------------------------
create or replace function public.report_sales_by_person(
  p_org_id uuid,
  p_from date,
  p_to date default current_date)
returns table (
  salesperson_id  uuid,
  code            text,
  name            text,
  is_active       boolean,
  invoiced        numeric,
  credited        numeric,
  net_sales       numeric,
  documents       integer,
  commission_rate numeric,
  commission      numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.can_read_ledger(p_org_id) then
    raise exception 'Not allowed to read the ledger of organization %', p_org_id
      using errcode = '42501';
  end if;

  return query
  with sold as (
    select d.salesperson_id as person,
           sum(case when d.doc_type = 'invoice'
                    then d.total_amount * d.exchange_rate else 0 end) as inv,
           sum(case when d.doc_type in ('credit_note', 'refund_note')
                    then d.total_amount * d.exchange_rate else 0 end) as crd,
           count(*)::integer as docs
      from public.sales_documents d
     where d.org_id = p_org_id
       and d.doc_date between p_from and p_to
       and d.status = 'posted'
       and d.deleted_at is null
       and d.doc_type in ('invoice', 'credit_note', 'refund_note')
     group by d.salesperson_id)
  select s.id, s.code, s.name, s.is_active,
         coalesce(sold.inv, 0),
         coalesce(sold.crd, 0),
         coalesce(sold.inv, 0) - coalesce(sold.crd, 0),
         coalesce(sold.docs, 0),
         s.commission_rate,
         case when s.commission_rate is null then null
              else round((coalesce(sold.inv, 0) - coalesce(sold.crd, 0))
                         * s.commission_rate / 100, 2) end
    from public.salespeople s
    left join sold on sold.person = s.id
   where s.org_id = p_org_id

  union all

  -- The unattributed line, and it is the point of the report rather than
  -- a tidy-up. A business that thinks it is tracking commission needs to
  -- see the sales nobody was credited with, because that is the number
  -- an argument will be about.
  select null::uuid, null, 'Not attributed', true,
         coalesce(sold.inv, 0),
         coalesce(sold.crd, 0),
         coalesce(sold.inv, 0) - coalesce(sold.crd, 0),
         coalesce(sold.docs, 0),
         null::numeric, null::numeric
    from sold
   where sold.person is null

   order by 7 desc nulls last, 3;
end;
$$;

-- ---------------------------------------------------------------------
-- Reachability
--
-- Postgres grants EXECUTE to PUBLIC on a new function, so it has to be
-- taken away before it is given back — the lesson 0080 was written for.
-- ---------------------------------------------------------------------
revoke all on function public.report_sales_by_person(uuid, date, date)
  from public, anon;
grant execute on function public.report_sales_by_person(uuid, date, date)
  to authenticated, service_role;

revoke all on function app.check_salesperson_org() from public, anon, authenticated;
