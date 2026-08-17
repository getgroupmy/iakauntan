-- Chasing money, and remembering that you did.
--
-- The two halves that existed were the automatic one and the arithmetic
-- one. `queue_overdue_reminders` emails a customer on the day-offsets a
-- company configures, and `report_ar_aging` says what is owed and how
-- old it is. Between them sat the part a person does: ringing somebody
-- up, being told the cheque goes out on Friday, and needing to know on
-- Saturday that it did not.
--
-- Nothing recorded that. An attempt left no trace, so two people could
-- chase the same customer on the same morning, a promise could be made
-- and forgotten, and the question a credit controller is actually paid
-- to answer — *who said they would pay, and did they* — had no data
-- behind it at all.
--
-- This is deliberately not a new module. Collections is what the sales
-- ledger is *for* when an invoice goes unpaid, so it rides on the same
-- entitlement as the rest of the sales side and needs no separate
-- purchase.

create type app.collection_channel as enum
  ('call', 'email', 'whatsapp', 'sms', 'letter', 'visit', 'meeting');

create type app.collection_outcome as enum (
  'no_answer',      -- rang out, mailbox full, nobody in
  'promised',       -- a date was given; the one outcome that has a diary
  'part_paid',      -- paid something on the spot
  'paid',           -- settled in full
  'disputed',       -- says the invoice is wrong
  'refused',        -- says no
  'unreachable',    -- wrong number, gone away, no forwarding
  'escalated');     -- handed to a solicitor or an agency

create table public.collection_attempts (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organizations(id)
                 on delete cascade,

  -- Always a customer; optionally one document. Most chasing is about
  -- the account rather than one invoice — "you owe us for four of
  -- these" is one call, not four — so `document_id` is nullable and an
  -- attempt against the account is the ordinary case.
  contact_id   uuid not null references public.contacts(id) on delete cascade,
  document_id  uuid references public.sales_documents(id) on delete set null,

  attempted_on date not null default current_date,
  channel      app.collection_channel not null,
  outcome      app.collection_outcome not null,

  -- The promise. Both null unless somebody actually committed to
  -- something, and the trigger below refuses `promised` without a date:
  -- an outcome of "they promised" with no date is a note, not a promise,
  -- and it is the difference between a follow-up list that works and one
  -- that quietly empties itself.
  promise_date   date,
  promise_amount numeric(18, 2) check (promise_amount is null
                                       or promise_amount > 0),

  -- Who owns chasing this from here. Carried on the attempt rather than
  -- on the customer so that handing an account over is a dated event
  -- with a note attached, which is what somebody picking it up needs to
  -- read.
  assigned_to  uuid references auth.users(id) on delete set null,

  notes        text,
  created_by   uuid references auth.users(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index collection_attempts_contact_idx
  on public.collection_attempts (org_id, contact_id, attempted_on desc);

-- The index behind the follow-up list, which is the query that runs
-- every morning.
create index collection_attempts_promise_idx
  on public.collection_attempts (org_id, promise_date)
  where promise_date is not null;

alter table public.collection_attempts
  add constraint collection_attempts_contact_same_org
  foreign key (org_id, contact_id) references public.contacts (org_id, id)
  on delete cascade;

-- `sales_documents` has no (org_id, id) key yet; collections is the
-- first thing to point at a document from a sibling table, so it adds
-- one and uses it. Same rule as everywhere else since 0160: a row may
-- not name another company's document.
alter table public.sales_documents add constraint sales_documents_org_id_id_key
  unique (org_id, id);
alter table public.collection_attempts
  add constraint collection_attempts_document_same_org
  foreign key (org_id, document_id)
  references public.sales_documents (org_id, id) on delete set null;

create or replace function app.collection_attempt_is_coherent()
returns trigger language plpgsql
set search_path = pg_catalog, public, pg_temp as $$
begin
  if new.outcome = 'promised' and new.promise_date is null then
    raise exception
      'An outcome of "promised" needs the date they promised. Without one '
      'it will never appear on anybody''s follow-up list.'
      using errcode = '23514';
  end if;

  -- A promise to have paid last week is not a promise; it is a
  -- typo, and one that would file itself as already broken.
  if new.promise_date is not null
     and new.promise_date < new.attempted_on then
    raise exception
      'They cannot promise to pay on %, which is before the day you spoke '
      'to them (%).', new.promise_date, new.attempted_on
      using errcode = '23514';
  end if;

  -- A promise attached to any other outcome is a contradiction worth
  -- catching: "refused, will pay Friday" means somebody picked the wrong
  -- one of the two.
  if new.promise_date is not null and new.outcome <> 'promised' then
    raise exception
      'A promise date belongs to the "promised" outcome, not to "%".',
      new.outcome using errcode = '23514';
  end if;

  -- A document being chased has to belong to the customer being chased.
  -- The composite key above stops it belonging to another *company*;
  -- this stops it belonging to another customer of the same one, which
  -- is the mistake a picker actually makes.
  if new.document_id is not null
     and not exists (select 1 from public.sales_documents d
                      where d.id = new.document_id
                        and d.contact_id = new.contact_id) then
    raise exception
      'That invoice is not this customer''s.' using errcode = '23514';
  end if;

  new.updated_at := now();
  return new;
end $$;

create trigger attempt_is_coherent
  before insert or update on public.collection_attempts
  for each row execute function app.collection_attempt_is_coherent();

-- ---------------------------------------------------------------------
-- Row level security
--
-- Read by anybody who may read the ledger, written by anybody who may
-- write — a credit controller is not an accountant and should not need
-- posting rights to record a phone call. Deliberately no `has_module`
-- gate: sales is core.
-- ---------------------------------------------------------------------
alter table public.collection_attempts enable row level security;

create policy collection_attempts_select on public.collection_attempts
  for select to authenticated
  using (app.can_read_ledger(org_id) or app.can_write(org_id));
create policy collection_attempts_write on public.collection_attempts
  for all to authenticated
  using (app.can_write(org_id)) with check (app.can_write(org_id));

grant select, insert, update, delete on public.collection_attempts
  to authenticated;

-- ---------------------------------------------------------------------
-- The worklist
--
-- One row per customer who owes something, with what is owed, how old
-- the oldest of it is, and where the chasing got to.
--
-- The money comes from `report_ar_aging` rather than from a second
-- reading of `sales_documents`. That report already knows what
-- "outstanding" means as at a date — allocations whose two ends were
-- both in the ledger by then, void and deleted documents excluded — and
-- a collections screen quoting a different number from the aged
-- receivables is worse than no collections screen.
-- ---------------------------------------------------------------------
create or replace function public.report_collections(
  p_org_id uuid,
  p_as_at date default current_date)
returns table (
  contact_id uuid,
  contact_code text,
  contact_name text,
  outstanding numeric,
  oldest_days integer,
  invoices integer,
  last_attempt_on date,
  last_outcome app.collection_outcome,
  last_notes text,
  promise_date date,
  promise_amount numeric,
  promise_broken boolean,
  assigned_to uuid,
  assigned_name text,
  never_chased boolean)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;
  if not (app.can_read_ledger(p_org_id) or app.can_write(p_org_id)) then
    raise exception 'You may not read the sales ledger'
      using errcode = '42501';
  end if;

  return query
  with owed as (
    select a.contact_id, a.contact_code, a.contact_name,
           sum(a.base_outstanding) as outstanding,
           max(a.days_overdue) as oldest_days,
           count(*)::integer as invoices
      from public.report_ar_aging(p_org_id, p_as_at) a
     where a.doc_kind = 'invoice'
       and a.base_outstanding > 0
     group by 1, 2, 3
  ),
  latest as (
    -- The most recent attempt per customer. `distinct on` rather than a
    -- window function because only one row per customer is wanted and
    -- this is the shape Postgres can answer straight off the index.
    select distinct on (c.contact_id)
           c.contact_id, c.attempted_on, c.outcome, c.notes, c.assigned_to
      from public.collection_attempts c
     where c.org_id = p_org_id and c.attempted_on <= p_as_at
     order by c.contact_id, c.attempted_on desc, c.created_at desc
  ),
  promised as (
    -- The live promise: the furthest-out date anybody has given that has
    -- not yet been superseded by a later attempt. Taking the *latest*
    -- promise rather than the earliest is deliberate — a customer who
    -- rang back to move Friday to the following Tuesday has one promise,
    -- for Tuesday, and chasing them on Friday is chasing a promise they
    -- already renegotiated.
    select distinct on (c.contact_id)
           c.contact_id, c.promise_date, c.promise_amount
      from public.collection_attempts c
     where c.org_id = p_org_id
       and c.promise_date is not null
       and c.attempted_on <= p_as_at
     order by c.contact_id, c.attempted_on desc, c.created_at desc
  )
  select o.contact_id, o.contact_code, o.contact_name,
         o.outstanding, o.oldest_days, o.invoices,
         l.attempted_on, l.outcome, l.notes,
         p.promise_date, p.promise_amount,
         -- Broken: the day came and went and they still owe something.
         -- This row only exists because they owe something, so the
         -- second half of that is already true.
         (p.promise_date is not null and p.promise_date < p_as_at),
         l.assigned_to,
         (select coalesce(pr.full_name, pr.email)
            from public.profiles pr where pr.id = l.assigned_to),
         (l.contact_id is null)
    from owed o
    left join latest l on l.contact_id = o.contact_id
    left join promised p on p.contact_id = o.contact_id
   order by
     -- Broken promises first, then never chased, then oldest debt. A
     -- worklist that opens on the thing most likely to be lost.
     (p.promise_date is not null and p.promise_date < p_as_at) desc,
     (l.contact_id is null) desc,
     o.oldest_days desc;
end $$;

grant execute on function public.report_collections(uuid, date)
  to authenticated;

-- Everything said to one customer, newest first. What somebody reads
-- before picking up the phone.
-- The output column is `attempt_id` and the lookup below is aliased.
-- A `returns table (id uuid, ...)` column shadows every unqualified `id`
-- in the body, so `where id = p_contact_id` binds to the OUT parameter
-- and the function fails at run time with "column reference id is
-- ambiguous". Found by `supabase/tests/collections.sql` on the first
-- run, which is the only reason it is not in production.
create or replace function public.collection_history(
  p_contact_id uuid)
returns table (
  attempt_id uuid,
  attempted_on date,
  channel app.collection_channel,
  outcome app.collection_outcome,
  promise_date date,
  promise_amount numeric,
  notes text,
  doc_no text,
  by_name text,
  assigned_name text)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare v_org uuid;
begin
  select c.org_id into v_org from public.contacts c where c.id = p_contact_id;
  if v_org is null then
    raise exception 'No such customer' using errcode = 'P0002';
  end if;
  if not (app.can_read_ledger(v_org) or app.can_write(v_org)) then
    raise exception 'You may not read the sales ledger'
      using errcode = '42501';
  end if;

  return query
    select a.id, a.attempted_on, a.channel, a.outcome,
           a.promise_date, a.promise_amount, a.notes, d.doc_no,
           coalesce(byp.full_name, byp.email),
           coalesce(asp.full_name, asp.email)
      from public.collection_attempts a
      left join public.sales_documents d on d.id = a.document_id
      left join public.profiles byp on byp.id = a.created_by
      left join public.profiles asp on asp.id = a.assigned_to
     where a.contact_id = p_contact_id and a.org_id = v_org
     order by a.attempted_on desc, a.created_at desc;
end $$;

grant execute on function public.collection_history(uuid) to authenticated;
