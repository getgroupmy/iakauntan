-- ---------------------------------------------------------------------
-- 0495  What happened to this invoice
-- ---------------------------------------------------------------------
-- `document_activity` has shown a document's timeline since 0082, and
-- it is a timeline of what was *sent*: the emails, the share links and
-- who opened them, the PDFs downloaded. Everything that left the
-- building.
--
-- Nothing about what happened to the document. It was raised, edited,
-- posted, paid, submitted to LHDN and possibly voided, and none of that
-- is on the one screen a person opens when they ask "what happened to
-- this invoice?". They are left reading the audit trail for the whole
-- company and filtering it by eye, which is what
-- `docs/gaps-against-akaunting.md` means when it says the global trail
-- "answers a different question".
--
-- ### What changes
--
-- Three more sources, unioned into the same function so the one screen
-- gets them all in one order:
--
--   * **the document's own changes**, from `audit_logs`. It has been
--     indexed on `(table_name, record_id)` since 0038 precisely so it
--     can be read per record, and nothing ever read it that way. An
--     edit names the fields that moved -- the ten somebody would
--     actually ask about, not the whole row, which is unreadable and
--     carries columns the reader has no business with.
--   * **the money**, from `payment_allocations` and the receipt behind
--     each one. A timeline showing an invoice sent and never showing it
--     paid is the half of the story that annoys people.
--   * **LHDN**, from `einvoice_documents`, keyed the way that table is
--     keyed: `(source_table, source_id)`, which is how a sales document
--     and a self-billed bill reach the same machinery.
--
-- ### What it does not do
--
-- It does not add a table or a trigger. Every event above was already
-- being recorded and none of it was being read, which is the whole
-- shape of this migration: the gap was a query, not a gap in the data.
--
-- ### Mutants
--
-- Run against `supabase/tests/document_history.sql`, each named with
-- the assertion that kills it:
--   * the changes left out -- "the timeline says when it was raised and
--     when it was posted";
--   * the record scope dropped from the audit read -- refused by this
--     migration's own self-check, which will not install a definition
--     that has lost `a.record_id = p_document_id`, so it never reaches
--     the suite. The assertion "and nothing that happened to another
--     document" would have caught it had it got that far;
--   * the table scope dropped -- "and nothing that happened to another
--     kind of record". `record_id` is unique only within a table, so
--     the test files a row against `purchase_documents` under this
--     document's id and expects it to stay off the screen;
--   * the payments left out -- "and when it was paid";
--   * the allocation not joined to its own invoice -- "and not what was
--     paid against another one";
--   * the e-invoice left out -- "and what LHDN said";
--   * the source table dropped from the e-invoice read -- "and not a
--     bill that happens to share the id". Both cycles reach that table:
--     a self-billed e-invoice is raised against a purchase document, so
--     `source_table` is half the key and a read that drops it can put
--     the purchase side on the sales side's screen;
--   * an edit not naming what moved -- "an edit says which fields
--     changed";
--   * the emails 0082 already showed dropped -- "the emails and the
--     links are still there".
--
-- Eight of the nine die in the suite; the ninth is refused before it
-- can be installed, which is noted above rather than claimed as a
-- suite kill.
-- ---------------------------------------------------------------------

-- Restated from the built definition. 0082 wrote it, 0104 and 0413
-- added to it; rebuilding from any one of those would drop the others.
create or replace function public.document_activity(p_document_id uuid)
returns table(at timestamptz, kind text, recipient text, status text,
              detail text, note text)
language sql stable
set search_path = public, app, pg_temp as $$
  select e.queued_at,
         'email'::text,
         e.to_email::text,
         e.status::text,
         (case e.dispatch when 'immediate' then 'sent now' else 'queued' end
          || case when e.attachment_path is not null
                  then ' · PDF attached' else ' · link only' end)::text,
         case
           when e.status = 'sent' and e.sent_at is not null
             then 'delivered to the provider ' ||
                  to_char(e.sent_at at time zone 'Asia/Kuala_Lumpur',
                          'DD Mon YYYY HH24:MI')
           when e.last_error is not null then e.last_error
           else null
         end::text
    from public.email_outbox e
   where e.document_id = p_document_id

  union all

  select l.created_at,
         'share link'::text,
         l.sent_to_email::text,
         case
           when l.revoked_at is not null then 'revoked'
           when l.expires_at < now() then 'expired'
           when l.opened_at is not null then 'opened'
           else 'live'
         end::text,
         case
           when coalesce(l.open_count, 0) = 0 then 'never opened'
           when l.open_count = 1 then 'opened once'
           else 'opened ' || l.open_count || ' times'
         end::text,
         case when l.last_opened_at is not null
              then 'last opened ' ||
                   to_char(l.last_opened_at at time zone 'Asia/Kuala_Lumpur',
                           'DD Mon YYYY HH24:MI')
              else null
         end::text
    from public.document_share_links l
   where l.document_id = p_document_id

  union all

  select d.downloaded_at,
         'pdf'::text,
         null::text,
         'downloaded'::text,
         d.format::text,
         null::text
    from public.document_downloads d
   where d.document_id = p_document_id

  union all

  -- 0495. What happened to the document itself, from the trail 0038
  -- has written since it existed. `audit_logs` is indexed on
  -- (table_name, record_id) precisely so it can be read this way, and
  -- until now nothing did: it answered "who changed what" across the
  -- whole company and never "what happened to this invoice".
  select a.created_at,
         'change'::text,
         coalesce(u.email::text, 'the system'),
         a.action::text,
         -- Read from the status that moved, not from the action.
         -- `audit_logs.action` is the raw `TG_OP`, so posting a
         -- document is recorded as an `update` -- the `post`, `void`
         -- and `submit` actions its check constraint allows are for
         -- explicit callers that were never written. What actually
         -- says an invoice was posted is the status in the diff, and
         -- `audit_diff` puts a column in `new_data` only when it
         -- changed, so this reads as "if the status moved, to what".
         case
           when a.action = 'insert' then 'raised'
           when a.action = 'delete' then 'deleted'
           when a.new_data ->> 'status' = 'posted'
             then 'posted to the ledger'
           when a.new_data ->> 'status' = 'void' then 'voided'
           when a.new_data ->> 'status' = 'rejected' then 'rejected'
           when a.new_data ->> 'status' = 'partial' then 'part paid'
           when a.new_data ->> 'status' = 'completed' then 'settled in full'
           when a.new_data ->> 'status' is not null
             then 'moved to ' || (a.new_data ->> 'status')
           when a.action = 'update' then 'edited'
           else a.action
         end::text,
         -- What actually moved, for an edit. The whole row is not the
         -- point and would be unreadable; the fields somebody would
         -- ask about are.
         case when a.action = 'update' then
           nullif((select string_agg(k, ', ' order by k)
                     from jsonb_object_keys(coalesce(a.new_data, '{}'::jsonb)) k
                    where a.old_data -> k is distinct from a.new_data -> k
                      and k in ('doc_date', 'due_date', 'contact_id',
                                'currency', 'exchange_rate', 'total_amount',
                                'reference', 'subject', 'notes',
                                'terms_conditions')), '')
         end::text
    from public.audit_logs a
    left join auth.users u on u.id = a.user_id
   where a.table_name = 'sales_documents'
     and a.record_id = p_document_id

  union all

  -- The money against it. A timeline that shows the invoice being sent
  -- and never being paid is the half of the story that annoys people.
  select coalesce(al.allocated_at, al.created_at),
         'payment'::text,
         c.name::text,
         'received'::text,
         (r.receipt_no || ' · ' ||
          to_char(al.amount, 'FM999G999G990D00'))::text,
         case when coalesce(al.discount_amount, 0) > 0
              then 'less ' || to_char(al.discount_amount,
                                      'FM999G999G990D00') || ' discount'
              else null end::text
    from public.payment_allocations al
    join public.receipts r on r.id = al.receipt_id
    left join public.contacts c on c.id = r.contact_id
   where al.invoice_id = p_document_id

  union all

  -- And LHDN, for a company that files. `einvoice_documents` keys off
  -- (source_table, source_id), which is how a sales document and a
  -- self-billed bill can both be submitted through the same machinery.
  select coalesce(e.submitted_at, e.created_at),
         'e-invoice'::text,
         e.buyer_name::text,
         e.status::text,
         coalesce(e.myinvois_uuid, e.internal_doc_no)::text,
         coalesce(e.rejection_reason, e.error_message,
                  case when e.validated_at is not null
                       then 'validated ' ||
                            to_char(e.validated_at at time zone
                                    'Asia/Kuala_Lumpur',
                                    'DD Mon YYYY HH24:MI')
                       else null end)::text
    from public.einvoice_documents e
   where e.source_table = 'sales_documents'
     and e.source_id = p_document_id

  order by 1 desc;
$$;

comment on function public.document_activity(uuid) is
  'One document''s whole timeline: what was sent, what changed, what '
  'was paid, and what LHDN said. See 0082, 0495.';

revoke all on function public.document_activity(uuid) from public, anon;
grant execute on function public.document_activity(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
declare v_def text :=
  pg_get_functiondef('public.document_activity(uuid)'::regprocedure);
begin
  -- The three new sources.
  if position('audit_logs' in v_def) = 0
     or position('payment_allocations' in v_def) = 0
     or position('einvoice_documents' in v_def) = 0 then
    raise exception '0495: a source is missing from the timeline';
  end if;
  -- And the ones 0082 and after already had. The restatement is the
  -- whole function, so anything dropped here is silent.
  if position('email_outbox' in v_def) = 0
     or position('document_share_links' in v_def) = 0
     or position('document_downloads' in v_def) = 0 then
    raise exception '0495: the timeline lost something it already showed';
  end if;
  -- The two scopes that keep one document's timeline to one document.
  if position('a.record_id = p_document_id' in v_def) = 0
     or position('e.source_table' in v_def) = 0 then
    raise exception '0495: the timeline is not scoped to this document';
  end if;
  if has_function_privilege('anon', 'public.document_activity(uuid)',
                            'execute') then
    raise exception '0495: a stranger can read a document''s history';
  end if;
end $do$;
