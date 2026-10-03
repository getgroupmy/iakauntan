-- ---------------------------------------------------------------------
-- 0733  The writes that still doubled
--
-- `0307` protected four writes with idempotency keys and `docs/mcp-server.md`
-- recorded the position as "**4 of 482**" volatile functions — a number
-- that reads as a 478-function backlog. It is not one, and this migration
-- is the answer to what the backlog actually is.
--
-- ## The 478 was the wrong denominator, and so was my first count of it
--
-- Measured against the schema rather than remembered, and the first
-- measurement here was WRONG in a way worth recording because it is the
-- same mistake `docs/handoff.md` has a section about. A `grep -oE` for
-- `callRpc\(\s*'([a-z0-9_]+)'` over `repository.dart` found 192
-- functions. grep matches within a line; a quarter of this file's call
-- sites put the function name on the line AFTER `await callRpc(`. The
-- real number is **577**, and the 385 it missed include
-- `email_receipt`, every `import_*`, and most of `create_*`.
--
-- A count built that way says nothing about what it did not look at,
-- and had it stood, this migration's header would have asserted a
-- five-function backlog in a schema that has a much larger one.
--
-- What is true, of the 490 `public` VOLATILE functions `authenticated`
-- may execute:
--
-- | | |
-- | --- | --- |
-- | named anywhere in `repository.dart` | 577 functions, of which **340 are volatile writes** |
-- | of those 340, never insert anything | **146** — `retire_*`, `delete_*`, `mark_*`, `reopen_*`, `set_*`. A second call writes the state the first one did |
-- | insert, and refuse a repeat BY NAME | **53** — "Adjustment % is already posted", "That contra is already void.", "That transfer is already %." This is `0307`'s argument for leaving the `post_*(p_id uuid)` family alone, holding in 53 more places |
-- | insert with no such refusal | **141** |
--
-- The 141 are **not** 141 defects, and this migration does not pretend
-- to have read them all. Of them, 52 contain an `on conflict` and 81 a
-- `where not exists` or a create-versus-update branch somewhere in the
-- call graph — signals, not verdicts, because an `on conflict` on some
-- other insert says nothing about the one that creates the record. Some
-- are meant to repeat: calling `add_pos_sale_line` twice is two lines
-- on the bill and that is the feature.
--
-- So the honest statement of position is: **four are fixed here, and the
-- rest is an enumerated backlog rather than a number in a document.**
-- `scripts/check_write_idempotency.py` is the other half of this
-- commit and the part that outlasts it. It asks the database the same
-- question on every run, holds the verdict for every function already
-- decided, and fails if the undecided count goes UP. A new
-- client-reachable write that inserts and refuses nothing cannot arrive
-- quietly any more.
--
-- ## The four, and what a retry costs today
--
-- | | |
-- | --- | --- |
-- | `email_document` | queues a SECOND message to the customer. The side effect leaves the building and cannot be reversed by a journal. |
-- | `email_receipt` | the same, for a receipt. Found only by the corrected count above, which is the argument for having corrected it. |
-- | `bulk_email_documents` | the same, times a batch. |
-- | `assign_ticket` | a second `ticket_events` row, so the history says the ticket was assigned twice. No money moves; the audit trail is what people read. |
--
-- ## Two more were in this list and are not, because the assertions said so
--
-- `save_payment_method` and `create_layout_from_builtin` both end in an
-- unconditional `insert` when no id is passed, and both were written up
-- here as duplicating on a retry. Then the block asserting the duplicate
-- raised `duplicate key value violates unique constraint
-- "payment_methods_name_key"` — a UNIQUE INDEX on
-- `(org_id, lower(name)) where deleted_at is null`, which is not in the
-- table definition and does not show in `pg_constraint`.
-- `report_layouts` has the same arrangement on `(org_id, kind,
-- lower(name))`.
--
-- So the second tap is refused by the index, both belong with the 53
-- that are already guarded, and wrapping them would have bought the
-- thing `0307` declined to conflate with a correctness fix: a retry that
-- returns the original answer instead of an error.
--
-- They came out, and the sequence is the argument for insisting the
-- FIRST assertion in each block be the unguarded double itself. Read
-- from the function bodies alone, both looked like defects.
--
-- ## Where the organization comes from
--
-- `app.idempotency_begin` scopes a key to one company, and three of
-- these five take no `p_org_id` at all. The wrapper resolves it from the
-- thing being written — the document, the ticket — BEFORE claiming the
-- key, which is also what makes `0475`'s membership guard apply: a
-- stranger replaying a guessed key is refused there rather than being
-- handed somebody else's answer.
--
-- Where that lookup finds nothing, the wrapper claims no key and calls
-- straight through, so the inner function raises its own "Document not
-- found" rather than this one inventing a worse message. `bulk_email_documents`
-- takes the organization of the FIRST id for scoping only; the
-- fingerprint still covers the whole array, so a replayed array returns
-- the first answer and a different array under the same key is refused.
--
-- ## No defaults, again
--
-- `0307`'s header explains why and it has not changed: PostgREST picks
-- between overloads by matching parameter names, so the key must be
-- required or a body that omits it matches both and every existing
-- caller breaks. The consequence is the dangerous half —
-- `check_idempotent_calls.py` exists because a wrapper with no defaults
-- silently resolves to the unprotected original when a caller omits one
-- merely-optional argument. `email_document` has six defaults and
-- `save_payment_method` ten; the client call sites in this commit name
-- every parameter and pass explicit nulls.
--
-- ## `bulk_email_documents` returns rows
--
-- The first of these wrappers to return a table rather than an id. The
-- stored result is `jsonb_agg` of the rows and a replay re-emits them
-- through `jsonb_to_recordset`, so the retry gets the same four columns
-- and not an empty set. A wrapper that returned nothing on replay would
-- pass any test that only checked "it did not send twice".
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- email_document
-- ---------------------------------------------------------------------
create or replace function public.email_document(
  p_document_id uuid, p_to text, p_template_code text, p_share_days integer,
  p_dispatch text, p_attachment_path text, p_attachment_name text,
  p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_seen jsonb; v_id uuid;
begin
  select d.org_id into v_org
    from public.sales_documents d where d.id = p_document_id;

  -- No document found: no organization to scope a key to, so no key is
  -- claimed and the inner function raises its own "Document not found".
  -- Written as a skipped claim rather than a second call to the inner
  -- function, so the argument-passing below exists in ONE place.
  if v_org is not null then
    v_seen := app.idempotency_begin(v_org, p_idempotency_key, 'email_document',
      jsonb_build_object('document_id', p_document_id, 'to', p_to,
                         'template_code', p_template_code,
                         'share_days', p_share_days, 'dispatch', p_dispatch,
                         'attachment_path', p_attachment_path,
                         'attachment_name', p_attachment_name));
    if v_seen is not null then
      return nullif(v_seen ->> 'id', '')::uuid;
    end if;
  end if;

  -- Named notation, and `p_share_days` OMITTED when the caller sent
  -- none. The wrapper has no defaults — it cannot, see the header — so a
  -- client that wants the ordinary share window has to send something,
  -- and the only honest something is null. Passing that null through
  -- positionally would issue a share token with no expiry; omitting the
  -- argument lets the inner function's own `default 30` apply, which
  -- keeps the number in exactly one place.
  if p_share_days is null then
    v_id := public.email_document(
      p_document_id := p_document_id, p_to := p_to,
      p_template_code := p_template_code, p_dispatch := p_dispatch,
      p_attachment_path := p_attachment_path,
      p_attachment_name := p_attachment_name);
  else
    v_id := public.email_document(p_document_id, p_to, p_template_code,
      p_share_days, p_dispatch, p_attachment_path, p_attachment_name);
  end if;
  if v_org is not null then
    perform app.idempotency_end(v_org, p_idempotency_key,
                                jsonb_build_object('id', v_id));
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- bulk_email_documents
-- ---------------------------------------------------------------------
create or replace function public.bulk_email_documents(
  p_ids uuid[], p_template_code text, p_idempotency_key text)
returns table (id uuid, doc_no text, sent boolean, problem text)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_seen jsonb; v_rows jsonb;
begin
  select d.org_id into v_org
    from public.sales_documents d
   where d.id = (p_ids)[1];

  if v_org is null then
    return query select * from public.bulk_email_documents(p_ids, p_template_code);
    return;
  end if;

  v_seen := app.idempotency_begin(v_org, p_idempotency_key,
    'bulk_email_documents',
    jsonb_build_object('ids', to_jsonb(p_ids),
                       'template_code', p_template_code));
  if v_seen is not null then
    -- The rows as they were, not an empty set.
    return query
      select (r ->> 'id')::uuid, r ->> 'doc_no', (r ->> 'sent')::boolean,
             r ->> 'problem'
        from jsonb_array_elements(coalesce(v_seen -> 'rows', '[]'::jsonb)) r;
    return;
  end if;

  select coalesce(jsonb_agg(to_jsonb(b)), '[]'::jsonb) into v_rows
    from public.bulk_email_documents(p_ids, p_template_code) b;

  perform app.idempotency_end(v_org, p_idempotency_key,
                              jsonb_build_object('rows', v_rows));

  return query
    select (r ->> 'id')::uuid, r ->> 'doc_no', (r ->> 'sent')::boolean,
           r ->> 'problem'
      from jsonb_array_elements(v_rows) r;
end;
$$;

-- ---------------------------------------------------------------------
-- assign_ticket
-- ---------------------------------------------------------------------
create or replace function public.assign_ticket(
  p_ticket uuid, p_user uuid, p_idempotency_key text)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_seen jsonb;
begin
  select t.org_id into v_org from public.tickets t where t.id = p_ticket;

  if v_org is null then
    perform public.assign_ticket(p_ticket, p_user);
    return;
  end if;

  v_seen := app.idempotency_begin(v_org, p_idempotency_key, 'assign_ticket',
    jsonb_build_object('ticket', p_ticket, 'user', p_user));
  if v_seen is not null then
    return;
  end if;

  perform public.assign_ticket(p_ticket, p_user);
  perform app.idempotency_end(v_org, p_idempotency_key, 'null'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------
-- email_receipt
--
-- `email_document`'s sibling, and the one the first count missed. Same
-- shape, except that a receipt carries no share token -- see 0110 -- so
-- there is no `p_share_days` and no omitted-argument branch.
-- ---------------------------------------------------------------------
create or replace function public.email_receipt(
  p_receipt_id uuid, p_to text, p_template_code text, p_dispatch text,
  p_attachment_path text, p_attachment_name text, p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_seen jsonb; v_id uuid;
begin
  select r.org_id into v_org from public.receipts r where r.id = p_receipt_id;

  if v_org is not null then
    v_seen := app.idempotency_begin(v_org, p_idempotency_key, 'email_receipt',
      jsonb_build_object('receipt_id', p_receipt_id, 'to', p_to,
                         'template_code', p_template_code,
                         'dispatch', p_dispatch,
                         'attachment_path', p_attachment_path,
                         'attachment_name', p_attachment_name));
    if v_seen is not null then
      return nullif(v_seen ->> 'id', '')::uuid;
    end if;
  end if;

  v_id := public.email_receipt(p_receipt_id, p_to, p_template_code,
    p_dispatch, p_attachment_path, p_attachment_name);
  if v_org is not null then
    perform app.idempotency_end(v_org, p_idempotency_key,
                                jsonb_build_object('id', v_id));
  end if;
  return v_id;
end;
$$;

-- 0165's event trigger strips PUBLIC and anon from every new function;
-- a grant to `authenticated` survives a replace, but these are new
-- signatures and arrive with none.
grant execute on function public.email_document(
  uuid, text, text, integer, text, text, text, text) to authenticated;
grant execute on function public.bulk_email_documents(
  uuid[], text, text) to authenticated;
grant execute on function public.assign_ticket(uuid, uuid, text)
  to authenticated;
grant execute on function public.email_receipt(
  uuid, text, text, text, text, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- What each one refuses, for `docs/api/`
--
-- `check_undocumented_writes.py` fails a write a signed-in user can
-- reach that carries no comment, and it is right to: a published
-- description that prints a name and an argument list has said nothing
-- about what the function will not do, and for a write the refusals are
-- the rule.
-- ---------------------------------------------------------------------
comment on function public.email_document(
  uuid, text, text, integer, text, text, text, text) is
  'Queues one message about a sales document, at most once per '
  'idempotency key. The key is required and has no default: that is '
  'what makes PostgREST choose this overload rather than the '
  'unprotected one, so a caller must name EVERY parameter. Send '
  'p_share_days as null for the ordinary share window -- the argument '
  'is then omitted and the inner function''s own default applies. '
  'Refuses: a key already used for different arguments (22023); a key '
  'still in flight (55006); a caller who is not a member of the '
  'document''s organization. A replay returns the first message id and '
  'queues nothing.';

comment on function public.email_receipt(
  uuid, text, text, text, text, text, text) is
  'Queues one message about a receipt, at most once per idempotency '
  'key. As email_document, except that a receipt carries no share link '
  '(see 0110) so there is no share window. Refuses: a key already used '
  'for different arguments (22023); a key still in flight (55006); a '
  'caller who is not a member of the receipt''s organization.';

comment on function public.bulk_email_documents(uuid[], text, text) is
  'Queues one message per document and reports a row for each: id, '
  'doc_no, whether it was sent, and the problem if it was not. At most '
  'once per idempotency key, and a REPLAY RETURNS THE SAME ROWS rather '
  'than an empty set. The key is scoped to the organization of the '
  'first id; the fingerprint covers the whole array, so the same array '
  'replays and a different one under the same key is refused (22023).';

comment on function public.assign_ticket(uuid, uuid, text) is
  'Assigns a ticket, or unassigns it when p_user is null, and writes one '
  'line of the ticket''s history per idempotency key -- without a key a '
  'repeated call says it twice. Refuses: somebody who is not an active '
  'member of the organization; somebody not on the team the ticket is '
  'with; a key already used for different arguments (22023).';
