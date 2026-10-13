-- =====================================================================
-- iAkauntan :: 0877 only a writer takes a number
--
-- `next_document_number` advances a company's counter -- the invoice,
-- the bill, the receipt -- and every number it gives out is one the
-- sequence will either use or show as a gap. A gap in an invoice
-- sequence is what an auditor and LHDN read as a missing document.
-- Since `0875` it answered staff for every document type and anybody
-- in the company for a claim's or leave's number; staff included the
-- two roles that write nothing: View Only and the auditor.
--
-- Measured on 13 October 2026, locally, with the role `authenticated`:
-- it gave a View Only member INV-2026-00001 and an auditor
-- INV-2026-00002, and the company's next invoice would have been
-- INV-2026-00003.
--
-- Production held 1 auditor and no `viewer` on 13 October.
--
-- Answered "only writers advance counters". It answers `can_write` for
-- every document type; payroll and HR -- `can_run_payroll`, which
-- admits the HR manager as `can_manage_hr` does -- for `employee`,
-- which the app numbers when HR takes somebody on, and `payroll_run`,
-- which `create_payroll_run` numbers as its caller; and anybody in the
-- company for `expense_claim` and `leave_request`, her own claim and
-- leave. Nothing in the app asks for a number for a View Only member or
-- an auditor.
-- =====================================================================

create or replace function public.next_document_number(p_org_id uuid, p_doc_type text)
 returns text
 language plpgsql
 security definer
 set search_path to 'public', 'app', 'pg_temp'
as $function$
begin
  -- 0877. A number is a promise the sequence keeps or shows broken, so
  -- only somebody who writes the document takes one: a writer for any;
  -- payroll and HR for the employee and the payroll run they create;
  -- anybody in the company for her own claim and her own leave.
  if not (app.can_write(p_org_id)
          or (p_doc_type in ('employee', 'payroll_run')
              and app.can_run_payroll(p_org_id))
          or (p_doc_type in ('expense_claim', 'leave_request')
              and app.is_org_member(p_org_id))) then
    raise exception 'Not a member of organization %', p_org_id using errcode = '42501';
  end if;
  return app.next_document_number_internal(p_org_id, p_doc_type);
end; $function$;
