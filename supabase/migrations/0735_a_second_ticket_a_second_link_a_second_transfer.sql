-- ---------------------------------------------------------------------
-- 0735  A second ticket, a second link, a second transfer
--
-- The next tranche out of the census's 56, and like `0734` every one was
-- MEASURED rather than read. Called twice against a built database:
--
--     create_ticket         -> 2 tickets
--     escalate_ticket       -> escalation_level 2, from one press
--     share_ticket          -> 2 share links, 2 live tokens
--     share_document        -> the same, for a sales document
--     report_feedback       -> 2 reports
--     create_bank_transfer  -> 2 transfers
--
-- Six functions, four shapes of harm:
--
-- | | |
-- | --- | --- |
-- | `create_ticket`, `report_feedback` | a second record with a fresh number, so the queue has two of the same thing and somebody closes one |
-- | `escalate_ticket` | not a duplicate ROW but a duplicate STEP: it adds one to `escalation_level`, so a retry escalates past the person it was meant to reach |
-- | `share_ticket`, `share_document` | a second live token. The first is not revoked, so a retry doubles the number of links that will open somebody's invoice until they expire |
-- | `create_bank_transfer` | a second transfer, drawn on `next_document_number`, waiting to be posted |
--
-- `escalate_ticket` is the one worth pausing on, because it is the first
-- in this programme whose damage is not a row. Everything else here
-- leaves two of something a person can see and delete. An escalation
-- level is a single integer, and nothing on the ticket says it was
-- incremented twice.
--
-- ## Two more were measured and came out
--
-- `attach_feedback_file` was in this tranche until the block meant to
-- demonstrate the duplicate raised a unique violation:
-- `feedback_attachments_storage_path_key` is on `storage_path`, which
-- comes straight from the caller. It is a `unique:` verdict now.
--
-- `open_tax_estimate` ran twice and left ONE row, which is neither a
-- refusal nor a duplicate: it looks for the live estimate first and
-- returns it. Its own comment says so — "Pressing the button again means
-- 'show me it' rather than 'make a second'" — and that is a third shape
-- the census had no name for, so it has one now: `existing:`, checked
-- the same way as `state:`, against the text.
--
-- ## Where the organization comes from
--
-- `create_ticket` and `report_feedback` take one. The rest resolve it
-- before claiming the key, so `0475`'s membership guard applies:
--
--     escalate_ticket, share_ticket    public.tickets
--     share_document                   public.sales_documents
--     create_bank_transfer             public.bank_accounts (the FROM side)
--
-- `report_feedback`'s `p_org_id` is itself optional — feedback can be
-- sent from a screen that belongs to no company — so a null one claims
-- no key and calls straight through. That is not a hole: with no
-- company there is nothing for a key to be scoped to, and
-- `idempotency_keys.org_id` is `not null` by design.
--
-- ## The defaults that are not null
--
-- Checked, because `0733` was caught by exactly this.
-- `create_bank_transfer` defaults `p_transfer_date` to `current_date`
-- and `p_bank_charges` to `0`; `create_ticket` defaults `p_channel` to
-- `'web'`; `report_feedback` defaults `p_kind` to `'bug'`. A wrapper
-- cannot have defaults, so a caller that sent nothing for those would
-- now send null and get a not-null violation instead of the default.
-- Every one of those four is already sent unconditionally by
-- `repository.dart`, and the only arguments it omits are ones whose
-- default IS null. `share_*`'s `p_valid_days` is the one case where null
-- and omitted differ, and both functions already
-- `coalesce(p_valid_days, 30)` inside, so null is safe there too.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- create_ticket
-- ---------------------------------------------------------------------
create or replace function public.create_ticket(
  p_org_id uuid, p_subject text, p_description text, p_category text,
  p_priority app.ticket_priority, p_type app.ticket_type,
  p_channel app.ticket_channel, p_requester_user_id uuid,
  p_requester_contact_id uuid, p_asset_id uuid, p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_seen jsonb; v_id uuid;
begin
  v_seen := app.idempotency_begin(p_org_id, p_idempotency_key,
    'create_ticket',
    jsonb_build_object('subject', p_subject, 'description', p_description,
                       'category', p_category, 'priority', p_priority::text,
                       'type', p_type::text, 'channel', p_channel::text,
                       'requester_user_id', p_requester_user_id,
                       'requester_contact_id', p_requester_contact_id,
                       'asset_id', p_asset_id));
  if v_seen is not null then
    return nullif(v_seen ->> 'id', '')::uuid;
  end if;

  v_id := public.create_ticket(p_org_id, p_subject, p_description, p_category,
    p_priority, p_type, p_channel, p_requester_user_id,
    p_requester_contact_id, p_asset_id);
  perform app.idempotency_end(p_org_id, p_idempotency_key,
                              jsonb_build_object('id', v_id));
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- escalate_ticket
--
-- Returns void, so there is nothing to replay except the refusal to do
-- it twice -- which is the whole point here, because what it would do
-- twice is add one to a number.
-- ---------------------------------------------------------------------
create or replace function public.escalate_ticket(
  p_ticket uuid, p_kind app.ticket_escalation, p_to_team uuid,
  p_to_user uuid, p_reason text, p_idempotency_key text)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_seen jsonb;
begin
  select t.org_id into v_org from public.tickets t where t.id = p_ticket;

  if v_org is not null then
    v_seen := app.idempotency_begin(v_org, p_idempotency_key,
      'escalate_ticket',
      jsonb_build_object('ticket', p_ticket, 'kind', p_kind::text,
                         'to_team', p_to_team, 'to_user', p_to_user,
                         'reason', p_reason));
    if v_seen is not null then
      return;
    end if;
  end if;

  perform public.escalate_ticket(p_ticket, p_kind, p_to_team, p_to_user,
                                 p_reason);
  if v_org is not null then
    perform app.idempotency_end(v_org, p_idempotency_key, 'null'::jsonb);
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- share_ticket
-- ---------------------------------------------------------------------
create or replace function public.share_ticket(
  p_ticket uuid, p_valid_days integer, p_email text, p_idempotency_key text)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_seen jsonb; v_url text;
begin
  select t.org_id into v_org from public.tickets t where t.id = p_ticket;

  if v_org is not null then
    v_seen := app.idempotency_begin(v_org, p_idempotency_key, 'share_ticket',
      jsonb_build_object('ticket', p_ticket, 'valid_days', p_valid_days,
                         'email', p_email));
    if v_seen is not null then
      -- The SAME link, which is the point: a second token would be a
      -- second way into somebody's ticket, live until it expires.
      return v_seen ->> 'url';
    end if;
  end if;

  v_url := public.share_ticket(p_ticket, p_valid_days, p_email);
  if v_org is not null then
    perform app.idempotency_end(v_org, p_idempotency_key,
                                jsonb_build_object('url', v_url));
  end if;
  return v_url;
end;
$$;

-- ---------------------------------------------------------------------
-- share_document
-- ---------------------------------------------------------------------
create or replace function public.share_document(
  p_document_id uuid, p_valid_days integer, p_email text,
  p_idempotency_key text)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_seen jsonb; v_url text;
begin
  select d.org_id into v_org
    from public.sales_documents d where d.id = p_document_id;

  if v_org is not null then
    v_seen := app.idempotency_begin(v_org, p_idempotency_key,
      'share_document',
      jsonb_build_object('document_id', p_document_id,
                         'valid_days', p_valid_days, 'email', p_email));
    if v_seen is not null then
      return v_seen ->> 'url';
    end if;
  end if;

  v_url := public.share_document(p_document_id, p_valid_days, p_email);
  if v_org is not null then
    perform app.idempotency_end(v_org, p_idempotency_key,
                                jsonb_build_object('url', v_url));
  end if;
  return v_url;
end;
$$;

-- ---------------------------------------------------------------------
-- report_feedback
-- ---------------------------------------------------------------------
create or replace function public.report_feedback(
  p_title text, p_kind app.feedback_kind, p_body text, p_screen text,
  p_app_version text, p_severity smallint, p_org_id uuid,
  p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_seen jsonb; v_id uuid;
begin
  -- No company, no key: feedback can be sent from a screen that belongs
  -- to none, and `idempotency_keys.org_id` is not null by design.
  if p_org_id is not null then
    v_seen := app.idempotency_begin(p_org_id, p_idempotency_key,
      'report_feedback',
      jsonb_build_object('title', p_title, 'kind', p_kind::text,
                         'body', p_body, 'screen', p_screen,
                         'app_version', p_app_version,
                         'severity', p_severity));
    if v_seen is not null then
      return nullif(v_seen ->> 'id', '')::uuid;
    end if;
  end if;

  v_id := public.report_feedback(p_title, p_kind, p_body, p_screen,
                                 p_app_version, p_severity, p_org_id);
  if p_org_id is not null then
    perform app.idempotency_end(p_org_id, p_idempotency_key,
                                jsonb_build_object('id', v_id));
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- create_bank_transfer
-- ---------------------------------------------------------------------
create or replace function public.create_bank_transfer(
  p_from_account_id uuid, p_to_account_id uuid, p_amount_sent numeric,
  p_transfer_date date, p_amount_received numeric, p_bank_charges numeric,
  p_reference text, p_notes text, p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_seen jsonb; v_id uuid;
begin
  select b.org_id into v_org
    from public.bank_accounts b where b.id = p_from_account_id;

  if v_org is not null then
    v_seen := app.idempotency_begin(v_org, p_idempotency_key,
      'create_bank_transfer',
      jsonb_build_object('from', p_from_account_id, 'to', p_to_account_id,
                         'amount_sent', p_amount_sent,
                         'transfer_date', p_transfer_date,
                         'amount_received', p_amount_received,
                         'bank_charges', p_bank_charges,
                         'reference', p_reference, 'notes', p_notes));
    if v_seen is not null then
      return nullif(v_seen ->> 'id', '')::uuid;
    end if;
  end if;

  v_id := public.create_bank_transfer(p_from_account_id, p_to_account_id,
    p_amount_sent, p_transfer_date, p_amount_received, p_bank_charges,
    p_reference, p_notes);
  if v_org is not null then
    perform app.idempotency_end(v_org, p_idempotency_key,
                                jsonb_build_object('id', v_id));
  end if;
  return v_id;
end;
$$;

-- 0165's event trigger strips PUBLIC and anon from every new function;
-- these are new signatures and arrive with no grant at all.
grant execute on function public.create_ticket(
  uuid, text, text, text, app.ticket_priority, app.ticket_type,
  app.ticket_channel, uuid, uuid, uuid, text) to authenticated;
grant execute on function public.escalate_ticket(
  uuid, app.ticket_escalation, uuid, uuid, text, text) to authenticated;
grant execute on function public.share_ticket(uuid, integer, text, text)
  to authenticated;
grant execute on function public.share_document(uuid, integer, text, text)
  to authenticated;
grant execute on function public.report_feedback(
  text, app.feedback_kind, text, text, text, smallint, uuid, text)
  to authenticated;
grant execute on function public.create_bank_transfer(
  uuid, uuid, numeric, date, numeric, numeric, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- What each one refuses, for `docs/api/`
-- ---------------------------------------------------------------------
comment on function public.create_ticket(
  uuid, text, text, text, app.ticket_priority, app.ticket_type,
  app.ticket_channel, uuid, uuid, uuid, text) is
  'Raises one ticket per idempotency key -- measured: without one, two '
  'identical calls raise two, each with its own number, and somebody '
  'closes one of them. The key is required and has no default, which is '
  'what makes PostgREST choose this overload rather than the '
  'unprotected one, so every parameter must be named. Refuses a key '
  'already used for different arguments (22023), a key still in flight '
  '(55006), and a caller who is not a member of the organization.';

comment on function public.escalate_ticket(
  uuid, app.ticket_escalation, uuid, uuid, text, text) is
  'Escalates a ticket once per idempotency key. What a retry duplicates '
  'here is not a row but a STEP: escalate_ticket adds one to '
  'escalation_level, so without a key a dropped connection escalates '
  'past the person it was meant to reach, and nothing on the ticket '
  'says it happened twice. Refuses a key already used for different '
  'arguments (22023) and a caller who is not a member of the ticket''s '
  'organization.';

comment on function public.share_ticket(uuid, integer, text, text) is
  'Mints one share link per idempotency key and returns THE SAME URL on '
  'a replay. Without a key a retry mints a second live token and does '
  'not revoke the first, so the number of ways into somebody''s ticket '
  'doubles until they expire. p_valid_days is coalesced to 30 inside, '
  'so null is safe. Refuses a key already used for different arguments '
  '(22023) and a caller who is not a member of the ticket''s '
  'organization.';

comment on function public.share_document(uuid, integer, text, text) is
  'As share_ticket, for a sales document: one link per idempotency key, '
  'the same URL on a replay, and without a key a second live token that '
  'will open the invoice until it expires.';

comment on function public.report_feedback(
  text, app.feedback_kind, text, text, text, smallint, uuid, text) is
  'Files one feedback report per idempotency key -- measured: without '
  'one, two identical calls file two. The key is scoped to p_org_id, '
  'and feedback sent from a screen belonging to no company passes a '
  'null one and claims no key, because idempotency_keys.org_id is not '
  'null by design.';

comment on function public.create_bank_transfer(
  uuid, uuid, numeric, date, numeric, numeric, text, text, text) is
  'Draws up one bank transfer per idempotency key -- measured: without '
  'one, two identical calls draw up two, each taking the next transfer '
  'number, both waiting to be posted. The organization comes from the '
  'account the money leaves. Refuses a key already used for different '
  'arguments (22023), a key still in flight (55006), and a caller who '
  'is not a member of that organization.';
