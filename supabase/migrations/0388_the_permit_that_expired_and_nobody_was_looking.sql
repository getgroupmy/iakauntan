-- =====================================================================
-- iAkauntan :: the permit that expired and nobody was looking
--
-- `0025` created `employee_documents` with an index on
-- `(org_id, expires_date)` and a comment above it that says what the
-- index is for:
--
--     Work permits and professional certificates expire; this is what a
--     "expiring in the next 60 days" list reads.
--
-- There is no such list. There never has been. The index has been
-- sitting there for the report nobody wrote, and the only way to find a
-- permit about to lapse is to open each employee's record in turn — so
-- a company with sixty staff finds out when the pass is checked at a
-- gate, or when Immigration asks.
--
-- Whose problem that is, is the point. Employing a person whose Pass has
-- expired is an offence by the **employer** under s.55B of the
-- Immigration Act 1959/63, and it is charged per employee. The person
-- whose permit lapsed is not the one prosecuted for it. A reminder list
-- is therefore not a convenience here; it is the only thing standing
-- between an administrative oversight and a conviction.
--
-- Three other things fell out of looking at the table.
--
-- `doc_type` is unconstrained text, while the dialog offers five fixed
-- kinds. Nothing stops a second path writing "Permit", "work_permit" or
-- "wp", and the moment one does, a report that groups by kind is
-- reporting on a subset it cannot name.
--
-- "A document cannot expire before it was issued" is enforced in the
-- dialog and nowhere else — which, in this project, means it is not
-- enforced.
--
-- And `uploaded_by` has never been written. Which of four HR
-- administrators filed the copy is exactly what is asked when the copy
-- turns out to be of the wrong document.
--
-- The last piece is the one that decides whether the list gets read at
-- all. Renewing a permit today means adding a row; the expired one
-- stays, and the expiring list fills with documents that were replaced
-- years ago. A list that is mostly noise is a list nobody opens, which
-- is how the one entry that mattered goes unread. So a renewal has to
-- say what it renews.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The kinds there are
--
-- The five the dialog has always offered, written down where they are
-- enforced. `not valid` is deliberately not used: the table is empty in
-- every deployment, because until now the only writer was that dialog.
-- ---------------------------------------------------------------------
alter table public.employee_documents
  drop constraint if exists employee_documents_kind_ck;
alter table public.employee_documents
  add constraint employee_documents_kind_ck
  check (doc_type in ('identity', 'permit', 'contract', 'certificate',
                      'other'));

-- ---------------------------------------------------------------------
-- A document cannot expire before it was issued
--
-- The rule the dialog has been carrying alone. Either date may be
-- absent — a contract with no end and an identity card with no issue
-- date on the copy are both ordinary — but when both are present the
-- order of them is not a matter of opinion.
-- ---------------------------------------------------------------------
alter table public.employee_documents
  drop constraint if exists employee_documents_dates_ck;
alter table public.employee_documents
  add constraint employee_documents_dates_ck
  check (expires_date is null or issued_date is null
         or expires_date >= issued_date);

-- ---------------------------------------------------------------------
-- What a renewal replaces
--
-- Self-referencing, and unique: two documents cannot both claim to
-- replace the same one, or the question "which is current" has two
-- answers and the report has to pick one arbitrarily.
-- ---------------------------------------------------------------------
alter table public.employee_documents
  add column if not exists supersedes_id uuid
  references public.employee_documents (id) on delete set null;

create unique index if not exists employee_documents_one_successor
  on public.employee_documents (supersedes_id)
  where supersedes_id is not null;

-- ---------------------------------------------------------------------
-- Who filed it
--
-- Derived, not typed — `0380`'s lesson. And written once: the person
-- who filed the copy is not the person who later corrected a typo in
-- its title, and a column that quietly follows the last editor answers
-- a different question from the one it is named for.
-- ---------------------------------------------------------------------
create or replace function app.employee_document_filed_by()
returns trigger language plpgsql
set search_path = pg_catalog, public, app, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    new.uploaded_by := coalesce(new.uploaded_by, auth.uid());
    return new;
  end if;
  new.uploaded_by := old.uploaded_by;
  return new;
end $$;

drop trigger if exists employee_documents_filed_by
  on public.employee_documents;
create trigger employee_documents_filed_by
  before insert or update on public.employee_documents
  for each row execute function app.employee_document_filed_by();

-- ---------------------------------------------------------------------
-- A renewal, and the document it retires
--
-- Everything the old document knows is carried across unless it is
-- given again, because a renewed work permit is the same permit with
-- new dates and retyping the rest is how the kind comes out different
-- from the one it replaces.
-- ---------------------------------------------------------------------
create or replace function public.renew_employee_document(
  p_document uuid,
  p_expires_date date,
  p_issued_date date default null,
  p_title text default null,
  p_notes text default null)
returns uuid
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  v_old public.employee_documents;
  v_new uuid;
begin
  select * into v_old from public.employee_documents where id = p_document;
  if v_old.id is null then
    raise exception 'No such document.' using errcode = 'P0002';
  end if;
  if not app.can_manage_hr(v_old.org_id) then
    raise exception 'not permitted to renew an employee document'
      using errcode = '42501';
  end if;

  if exists (select 1 from public.employee_documents
              where supersedes_id = p_document) then
    raise exception
      'That document has already been renewed. Renew the one that '
      'replaced it, not the one it replaced.'
      using errcode = '23505';
  end if;
  if p_expires_date is null then
    raise exception
      'A renewal has a new expiry date. Without one there is nothing '
      'to renew it to.' using errcode = '23502';
  end if;
  -- The renewal has to run past the document it replaces. A "renewal"
  -- expiring earlier is a different document, and treating it as one
  -- would retire the permit that is still the current one.
  if v_old.expires_date is not null
     and p_expires_date <= v_old.expires_date then
    raise exception
      'A renewal runs past the document it replaces. % already runs to '
      '%.', v_old.title, to_char(v_old.expires_date, 'DD Mon YYYY')
      using errcode = '23514';
  end if;

  insert into public.employee_documents
    (org_id, employee_id, doc_type, title, issued_date, expires_date,
     notes, supersedes_id)
  values (v_old.org_id, v_old.employee_id, v_old.doc_type,
          coalesce(nullif(btrim(coalesce(p_title, '')), ''), v_old.title),
          coalesce(p_issued_date, v_old.expires_date),
          p_expires_date,
          coalesce(nullif(btrim(coalesce(p_notes, '')), ''), v_old.notes),
          p_document)
  returning id into v_new;

  return v_new;
end $$;

-- ---------------------------------------------------------------------
-- The list the index was built for
--
-- Only what is current: a document something else supersedes has been
-- replaced, and leaving it here is what turns the list into noise.
--
-- Only people still on the books, because a leaver's lapsed permit is
-- not the company's offence — `employment_status` in ('resigned',
-- 'terminated', 'retired') is somebody who has gone.
--
-- `consequence` is the column worth having. An expired certificate is a
-- thing to chase; an expired permit on an expatriate or a foreign
-- worker is s.55B of the Immigration Act, charged against the employer
-- per person. Sorting a list by date treats those the same, and they
-- are not the same, so the report says which is which and orders the
-- offence first.
-- ---------------------------------------------------------------------
create or replace function public.report_expiring_documents(
  p_org_id uuid,
  p_within_days integer default 60)
returns table (
  document_id uuid,
  employee_id uuid,
  employee_no text,
  employee_name text,
  doc_type text,
  title text,
  issued_date date,
  expires_date date,
  days_until integer,
  is_expired boolean,
  consequence text)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
begin
  if not app.can_manage_hr(p_org_id) then
    raise exception 'not permitted to read employee documents'
      using errcode = '42501';
  end if;

  return query
    select d.id, e.id, e.employee_no,
           e.full_name,
           d.doc_type, d.title, d.issued_date, d.expires_date,
           (d.expires_date - current_date)::integer,
           d.expires_date < current_date,
           case
             when d.doc_type = 'permit'
              and e.residency_status in ('expatriate', 'foreign_worker')
              and d.expires_date < current_date
               then 'offence'
             when d.doc_type = 'permit'
              and e.residency_status in ('expatriate', 'foreign_worker')
               then 'permit'
             else 'renewal'
           end
      from public.employee_documents d
      join public.employees e on e.id = d.employee_id
     where d.org_id = p_org_id
       and d.expires_date is not null
       and e.employment_status not in ('resigned', 'terminated', 'retired')
       and not exists (select 1 from public.employee_documents s
                        where s.supersedes_id = d.id)
       and d.expires_date <= current_date + coalesce(p_within_days, 60)
     order by
       case
         when d.doc_type = 'permit'
          and e.residency_status in ('expatriate', 'foreign_worker')
          and d.expires_date < current_date then 0
         when d.doc_type = 'permit'
          and e.residency_status in ('expatriate', 'foreign_worker') then 1
         else 2
       end,
       d.expires_date, e.full_name;
end $$;

grant execute on function public.renew_employee_document(
  uuid, date, date, text, text) to authenticated;
grant execute on function public.report_expiring_documents(uuid, integer)
  to authenticated;
