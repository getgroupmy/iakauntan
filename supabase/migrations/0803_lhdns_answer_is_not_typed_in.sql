-- =====================================================================
-- iAkauntan :: 0803 LHDN's answer is not typed in
--
-- `sales_documents.einvoice_status` and `purchase_documents.
-- einvoice_status` are copies: `prepare_einvoice` and its siblings write
-- 'pending' and the e-Invoice's id, and `sync_einvoice_status` copies
-- each answer LHDN gives -- submitted, valid, invalid, rejected,
-- cancelled -- from the e-Invoice onto the document. A bill's
-- `requires_self_billed` is set from its supplier's country when it is
-- written, and changed after that through `set_requires_self_billed`,
-- which refuses once LHDN has the self-billed e-Invoice and withdraws
-- one prepared and not sent. The app writes none of the three; the
-- UPDATE policies on both tables let anybody who may write a document
-- write all three. And `void_sales_document` refused an invoice LHDN
-- had accepted by reading the copy.
--
-- Measured on 10 October 2026, locally, as the owner with the role
-- `authenticated`: an invoice whose e-Invoice LHDN had validated (a
-- MyInvois UUID on it), its copied status set to 'pending' by hand, and
-- `void_sales_document` then voided it. The invoice was void and its
-- journal reversed; LHDN still held it as a valid e-Invoice.
--
-- Answered "guard the columns and ask LHDN's copy". A trigger refuses a
-- client's own statement -- role `authenticated` or `anon`, at the top
-- trigger depth -- that writes a document's e-Invoice status or
-- e-Invoice, or a bill's `requires_self_billed`, or creates a document
-- with any of them set. The functions run as their owner and pass, and
-- `sync_einvoice_status` runs one trigger deeper. NOT security definer
-- itself. Named to fire before `suggest_self_billed`, which decides a
-- new bill's obligation from its supplier, so what is asked is what the
-- client sent. And `void_sales_document` refuses whenever an e-Invoice
-- for the document is valid in `einvoice_documents` itself, as `0770`
-- already asks for one LHDN has not yet answered; the rent and strata
-- run voids go through it.
--
-- Production held no e-Invoice, no document marked with one and no bill
-- owing a self-billed one, on 10 October.
-- =====================================================================

create or replace function app.einvoice_state_is_lhdns()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_col text;
  v_old jsonb;
  v_new jsonb;
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return new;
  end if;

  -- `requires_self_billed` is a bill's alone; read through jsonb so one
  -- function serves both tables.
  v_new := to_jsonb(new);

  if tg_op = 'INSERT' then
    if new.einvoice_status is distinct from 'not_applicable'
       or new.einvoice_id is not null then
      raise exception
        'A document is created with no e-Invoice on it (this one said %, '
        'e-Invoice %). One is prepared for it once it is posted, and '
        'LHDN''s answer is copied onto it from there.',
        new.einvoice_status, coalesce(new.einvoice_id::text, 'none')
        using errcode = '42501';
    end if;
    if coalesce((v_new ->> 'requires_self_billed')::boolean, false) then
      raise exception
        'A bill owes a self-billed e-Invoice because its supplier is '
        'abroad, or because somebody said so with set_requires_self_billed '
        '-- not because it was written that way.'
        using errcode = '42501';
    end if;
    return new;
  end if;

  v_old := to_jsonb(old);
  foreach v_col in array array['einvoice_status', 'einvoice_id'] loop
    if (v_new -> v_col) is distinct from (v_old -> v_col) then
      raise exception
        'The e-Invoice % of % is copied from the e-Invoice, which holds '
        'LHDN''s answer, and is not written directly (% -> %). Prepare, '
        'submit or cancel the e-Invoice instead.',
        case v_col when 'einvoice_status' then 'status' else 'id' end,
        new.doc_no,
        coalesce(v_old ->> v_col, 'null'), coalesce(v_new ->> v_col, 'null')
        using errcode = '42501';
    end if;
  end loop;

  if (v_new -> 'requires_self_billed')
       is distinct from (v_old -> 'requires_self_billed') then
    raise exception
      'Whether % owes a self-billed e-Invoice is changed with '
      'set_requires_self_billed (% -> %), which refuses once LHDN has it '
      'and withdraws one prepared and not sent.',
      new.doc_no, v_old ->> 'requires_self_billed',
      v_new ->> 'requires_self_billed'
      using errcode = '42501';
  end if;

  return new;
end $$;

revoke all on function app.einvoice_state_is_lhdns() from public, anon, authenticated;

comment on function app.einvoice_state_is_lhdns() is
  'On sales and purchase documents: refuses a client''s own statement '
  'that writes einvoice_status or einvoice_id, or a bill''s '
  'requires_self_billed, or creates a document with any of them set. '
  'The functions that prepare e-Invoices and copy LHDN''s answer pass. '
  '0803.';

create trigger a_einvoice_state_is_lhdns
  before insert or update on public.sales_documents
  for each row execute function app.einvoice_state_is_lhdns();

create trigger a_einvoice_state_is_lhdns
  before insert or update on public.purchase_documents
  for each row execute function app.einvoice_state_is_lhdns();

create or replace function public.void_sales_document(p_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_doc public.sales_documents;
begin
  select * into v_doc from public.sales_documents where id = p_id;
  if not found then raise exception 'Document % not found', p_id; end if;
  if not app.can_post(v_doc.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if v_doc.paid_amount > 0 then
    raise exception 'Cannot void %: payments have been applied', v_doc.doc_no;
  end if;
  -- 0803. And asked of the e-Invoices themselves, as 0770 asks for one
  -- LHDN has not yet answered: the column above is a copy, and a copy
  -- is only as good as whoever last wrote it.
  if v_doc.einvoice_status = 'valid'
     or exists (select 1 from public.einvoice_documents e
                 where e.org_id = v_doc.org_id
                   and e.source_table = 'sales_documents'
                   and e.source_id = v_doc.id
                   and e.status = 'valid') then
    raise exception 'Cannot void %: cancel the e-Invoice with LHDN first', v_doc.doc_no;
  end if;
  -- 0770. Read from the e-Invoices themselves. One LHDN has and has not
  -- yet answered may come back valid, which is a cancellation of its
  -- own; voiding under it would leave LHDN holding a sale we do not.
  if exists (select 1 from public.einvoice_documents e
              where e.org_id = v_doc.org_id
                and e.source_table = 'sales_documents'
                and e.source_id = v_doc.id
                and e.status = 'submitted') then
    raise exception
      'Cannot void %: its e-Invoice is with LHDN awaiting validation. Wait '
      'for the answer, and if it is accepted, cancel it with LHDN first.',
      v_doc.doc_no
      using errcode = '55006';
  end if;

  if v_doc.gl_entry_id is not null then
    perform public.reverse_gl_entry(v_doc.gl_entry_id, app.today());
  end if;

  -- 0770. What LHDN never accepted is withdrawn. The submit sweep sends
  -- 'draft', 'queued', 'failed' and 'invalid' without looking at the
  -- invoice, so left as it was, an e-Invoice for this sale would still
  -- have gone -- and come back valid for a sale that is void.
  update public.einvoice_documents e
     set status = 'cancelled',
         cancelled_at = now(),
         cancellation_reason = 'Withdrawn before LHDN accepted it: '
           || v_doc.doc_no || ' was voided'
           || coalesce(' (' || nullif(btrim(p_reason), '') || ')', '')
   where e.org_id = v_doc.org_id
     and e.source_table = 'sales_documents'
     and e.source_id = v_doc.id
     and e.status in ('draft', 'queued', 'failed', 'invalid');

  update public.sales_documents
     set status = 'void',
         internal_notes = coalesce(internal_notes || E'\n', '') || 'Voided: ' || coalesce(p_reason, '')
   where id = p_id;
end;
$$;

comment on function public.void_sales_document(uuid, text) is
  'Voids an invoice or other sales document and reverses its journal if '
  'it had one, recording the reason in `internal_notes` where the '
  'customer will not see it. Refuses outright if any payment has been '
  'applied -- a document somebody has paid against is corrected with a '
  'credit note, not erased -- and refuses if the e-Invoice is `valid`, '
  'because LHDN has it and the cancellation belongs there first: asked '
  'of the document''s copy and of the e-Invoices themselves (0803). Needs '
  '`can_post`. Also refuses while the e-Invoice is `submitted` and LHDN '
  'has not answered, and withdraws one LHDN never accepted (`draft`, '
  '`queued`, `failed`, `invalid`) by marking it `cancelled`, so it is '
  'not sent after the sale is gone (0770).';
