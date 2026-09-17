-- =====================================================================
-- iAkauntan :: 0628 the bill that arrived twice
--
-- Paying a supplier's invoice twice is the most expensive routine
-- mistake in accounts payable, and nothing in this product has ever
-- looked for it. `0406` swept every `_no` column for missing unique
-- indexes and deliberately left `supplier_doc_no` alone, with the right
-- reason:
--
--   "Two suppliers may perfectly well send invoices numbered `INV-1`,
--    and a unique index there would refuse the second one."
--
-- True, and it answers a different question from the one that matters.
-- The DUPLICATE is not "two suppliers used the same number". It is
-- "THIS supplier's invoice number 4471 is on the books twice" -- and
-- `(org_id, contact_id, supplier_doc_no)` is a key 0406 never
-- considered, because it was sweeping columns rather than pairs.
--
-- ---------------------------------------------------------------------
-- It warns. It does not refuse.
--
-- The same line `0625` drew, and for a sharper reason: there are real
-- documents that would trip any rule written here.
--
--   * A supplier who re-issues an invoice under the same number after
--     correcting it, and expects the first to be discarded.
--   * A bill entered, voided and entered again -- which is why a void
--     is excluded rather than counted.
--   * Two genuine deliveries on one day for the same standing charge,
--     which the amount-and-date test below will flag and which are not
--     duplicates at all.
--
-- A hard constraint would refuse all three at the moment somebody is
-- trying to get a day's work done, and the workaround people find for a
-- constraint that is wrong a tenth of the time is to type the number
-- differently -- which destroys the only field this check runs on. So
-- it returns rows, the screen says so, and a person decides.
--
-- ---------------------------------------------------------------------
-- Two ways a bill arrives twice, and both are needed
--
-- **By number.** The ordinary case, and the reliable one. Compared on
-- `app.supplier_doc_key`, which strips everything that is not a letter
-- or a digit and upper-cases the rest: `INV-4471`, `inv 4471` and
-- `INV4471` are one invoice typed by three people, and a check that
-- called them three invoices would be a check that never fires.
--
-- **By amount and date.** For the document that has no number on it at
-- all, which is most till receipts and a good share of what the scanner
-- reads. Weaker on purpose and reported as a different reason, because
-- a supplier billing the same amount on the same day twice is
-- occasionally real.
--
-- The same PARTY, not merely the same contact row: `0477` links a
-- company's records through `party_id`, so a supplier filed twice is
-- one supplier here. A duplicate check that missed the duplicate
-- because the supplier itself was duplicated would be the joke version
-- of this migration.
-- =====================================================================

create or replace function app.supplier_doc_key(p_no text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select nullif(upper(regexp_replace(coalesce(p_no, ''), '[^a-zA-Z0-9]',
                                     '', 'g')), '');
$$;

comment on function app.supplier_doc_key(text) is
  'A supplier document number with the punctuation and case taken out, '
  'so INV-4471 and inv 4471 are one number. See 0628.';

revoke all on function app.supplier_doc_key(text) from public, anon;
grant execute on function app.supplier_doc_key(text)
  to authenticated, service_role;

create or replace function public.duplicate_purchase_documents(
  p_contact_id      uuid,
  p_doc_type        text default 'bill',
  p_supplier_doc_no text default null,
  p_doc_date        date default null,
  p_total_amount    numeric default null,
  p_exclude_id      uuid default null)
returns table (
  id uuid,
  doc_no text,
  doc_date date,
  supplier_doc_no text,
  total_amount numeric,
  currency text,
  status text,
  reason text)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  with me as (select c.* from public.contacts c where c.id = p_contact_id)
  select d.id, d.doc_no, d.doc_date, d.supplier_doc_no, d.total_amount,
         d.currency::text, d.status::text,
         case
           when app.supplier_doc_key(p_supplier_doc_no) is not null
            and app.supplier_doc_key(d.supplier_doc_no)
                = app.supplier_doc_key(p_supplier_doc_no)
           then 'same number'
           else 'same amount on the same day'
         end
    from public.purchase_documents d
   cross join me
   where d.org_id = me.org_id
     and app.is_org_member(me.org_id)
     and d.deleted_at is null
     -- A void or a rejected document is withdrawn. Counting one would
     -- mean that entering a bill, voiding it and entering it again --
     -- the ordinary way a mistake is corrected -- produced a warning
     -- about the mistake somebody had just fixed.
     and d.status not in ('void', 'rejected')
     and d.doc_type::text = p_doc_type
     and (p_exclude_id is null or d.id <> p_exclude_id)
     and d.contact_id in (
       select c2.id from public.contacts c2
        where c2.org_id = me.org_id
          and (c2.id = me.id
               or (me.party_id is not null and c2.party_id = me.party_id)))
     and (
       (app.supplier_doc_key(p_supplier_doc_no) is not null
        and app.supplier_doc_key(d.supplier_doc_no)
            = app.supplier_doc_key(p_supplier_doc_no))
       or (p_doc_date is not null
           and p_total_amount is not null
           and p_total_amount <> 0
           and d.doc_date = p_doc_date
           and d.total_amount = p_total_amount)
     )
   order by d.doc_date desc, d.doc_no;
$$;

comment on function public.duplicate_purchase_documents(
  uuid, text, text, date, numeric, uuid) is
  'Purchase documents already on the books that look like the one being '
  'entered -- by the supplier''s own number, or by amount and date where '
  'there is no number. Warns; refuses nothing. See 0628.';

revoke all on function public.duplicate_purchase_documents(
  uuid, text, text, date, numeric, uuid) from public, anon;
grant execute on function public.duplicate_purchase_documents(
  uuid, text, text, date, numeric, uuid) to authenticated, service_role;

-- The index the check runs on. Not unique, for the reason in the
-- header: this finds duplicates, it does not forbid them.
create index if not exists purchase_documents_supplier_doc_key_idx
  on public.purchase_documents (org_id, contact_id,
                                app.supplier_doc_key(supplier_doc_no))
  where supplier_doc_no is not null and deleted_at is null;
