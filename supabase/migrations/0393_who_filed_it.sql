-- =====================================================================
-- iAkauntan :: who filed it
--
-- `attachments.uploaded_by` has been a column since `0008` and nothing
-- has ever written it. `attachments_repository.dart` inserts the row —
-- org, entity, file name, storage path, mime type, size — and leaves
-- that one out.
--
-- It is the same defect `0388` fixed on `employee_documents`, one table
-- over, and the same question is asked of it: which of the people with
-- an account put this file here. That gets asked when a receipt turns
-- out to be for the wrong claim, when a client's document appears
-- against another client's matter, and when somebody wants to know who
-- had a copy of a passport. `attachments` is the general store — every
-- entity in the system hangs files off it — so it is the table where
-- the answer matters most and the one where it was missing.
--
-- `0388` wrote the rule as a trigger of its own. Writing it a second
-- time here would be two copies of a three-line rule, which is how two
-- copies come to disagree, so this generalises it: one function that
-- works on any table with an `uploaded_by` column, and `0388`'s trigger
-- re-pointed at it. The behaviour is `0388`'s, unchanged and now stated
-- once.
--
--   * set on insert when the caller did not give one, from `auth.uid()`;
--   * frozen on update — the person who filed the copy is not the person
--     who later corrected a typo in its name, and a column that quietly
--     follows the last editor answers a different question from the one
--     it is named for.
--
-- Null stays possible on insert, deliberately. A row written by a
-- scheduler or an edge function has no `auth.uid()`, and a
-- not-null constraint would refuse the write rather than record the
-- truth, which is that nobody in particular filed it.
-- =====================================================================

create or replace function app.set_filed_by()
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

drop trigger if exists attachments_filed_by on public.attachments;
create trigger attachments_filed_by
  before insert or update on public.attachments
  for each row execute function app.set_filed_by();

-- `0388`'s trigger, re-pointed at the shared function so the rule lives
-- in one place. `app.employee_document_filed_by` is left defined rather
-- than dropped: migrations are append-only and something reading the
-- history should find what `0388` said it created.
drop trigger if exists employee_documents_filed_by
  on public.employee_documents;
create trigger employee_documents_filed_by
  before insert or update on public.employee_documents
  for each row execute function app.set_filed_by();
