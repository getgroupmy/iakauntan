-- =====================================================================
-- iAkauntan :: 0791 a signature is the database's
--
-- `0069` collects electronic signatures on a resolution, and says what
-- makes one worth anything:
--
--     The evidence. Written by the database at the moment of signing,
--     not supplied by the caller: a signature record the signer can
--     write is not evidence of anything.
--
-- The functions keep that promise -- `corp_sign_document`,
-- `corp_sign_with_link`, the two declines and `corp_request_signatures`
-- write the status, the time, the hash, the address and the login
-- themselves. The tables did not. `corp_signatures_write` and
-- `corp_signature_requests_write` give any member who may write `ALL`
-- on both, so every one of those columns could be set straight through
-- the API. Measured on 10 October 2026, locally, signed in as a member
-- with the accountant's role:
--
--   * Director Two's line set to signed, backdated, with an address and
--     a browser made up -- a signature nobody gave;
--   * the request marked withdrawn, which unlocks the text (`0072`
--     counts signed lines under requests NOT withdrawn), the signed
--     text rewritten, every line's hash and the request's hash set to
--     the new text, the request un-withdrawn -- under Director One's
--     real signature.
--
-- `corp_signature_state` then said both directors had signed and the
-- text was unchanged. Only the audit trail said otherwise.
--
-- Answered "guard the columns", as `0781` did for a document's state.
-- A trigger refuses a client's own statement -- role `authenticated` or
-- `anon`, at the top trigger depth -- that:
--
--   * changes a signature line's evidence (status, time, name, decline
--     reason, hash, address, browser, login), the request or person it
--     belongs to, or its capacity once it is no longer pending;
--   * inserts a line that is not a plain pending one, or deletes one
--     that has been signed or declined;
--   * inserts a request (`corp_request_signatures` raises them), changes
--     a request's document, hash, author or withdrawal, or deletes a
--     request any line of which has been signed or declined.
--
-- A request's due date and note, and a pending line's capacity, stay
-- the company's to edit. The five functions that write these tables are
-- SECURITY DEFINER and run as their owner, so they pass, as everything
-- `0781` let through does. NOT security definer itself: the question is
-- who is running the statement.
--
-- The app and the edge functions write neither table directly.
-- Production held no corporate document, request or signature on 10
-- October, so nothing that exists is refused.
-- =====================================================================

create or replace function app.signature_evidence_is_the_databases()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_col  text;
  v_old  jsonb;
  v_new  jsonb;
  v_what text;
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return coalesce(new, old);
  end if;

  if tg_table_name = 'corp_signatures' then
    if tg_op = 'INSERT' then
      if new.status is distinct from 'pending'
         or new.signed_at is not null or new.signed_name is not null
         or new.decline_reason is not null
         or new.body_sha256_at_signing is not null
         or new.ip_address is not null or new.user_agent is not null
         or new.signed_by is not null then
        raise exception
          'A signature line starts pending and empty. It is signed or '
          'declined by the person it names, and the database writes the '
          'record of that itself.'
          using errcode = '42501';
      end if;
      return new;
    end if;

    if tg_op = 'DELETE' then
      if old.status <> 'pending' then
        raise exception
          'A line that has been % is the record that it was, and is not '
          'deleted.', old.status
          using errcode = '42501';
      end if;
      return old;
    end if;

    v_old := to_jsonb(old);
    v_new := to_jsonb(new);
    foreach v_col in array array[
        'request_id', 'person_id', 'status', 'signed_at', 'signed_name',
        'decline_reason', 'body_sha256_at_signing', 'ip_address',
        'user_agent', 'signed_by'] loop
      if (v_new -> v_col) is distinct from (v_old -> v_col) then
        v_what := case v_col
          when 'request_id' then 'request'
          when 'person_id' then 'person'
          when 'signed_at' then 'time'
          when 'signed_name' then 'name'
          when 'decline_reason' then 'reason for declining'
          when 'body_sha256_at_signing' then 'hash of the text signed'
          when 'ip_address' then 'address'
          when 'user_agent' then 'browser'
          when 'signed_by' then 'login'
          else v_col end;
        raise exception
          'The % on a signature is written by the database when the '
          'person signs or declines, not directly.', v_what
          using errcode = '42501';
      end if;
    end loop;
    if old.status <> 'pending'
       and new.capacity is distinct from old.capacity then
      raise exception
        'The capacity a person % in is part of what they %.',
        old.status, old.status
        using errcode = '42501';
    end if;
    return new;
  end if;

  -- corp_signature_requests
  if tg_op = 'INSERT' then
    raise exception
      'Signatures are requested with corp_request_signatures, which '
      'fixes the text they are asked to sign.'
      using errcode = '42501';
  end if;

  if tg_op = 'DELETE' then
    if exists (select 1 from public.corp_signatures s
                where s.request_id = old.id and s.status <> 'pending') then
      raise exception
        'Somebody has already signed or declined this request, and it is '
        'the record that they did.'
        using errcode = '42501';
    end if;
    return old;
  end if;

  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  foreach v_col in array array[
      'document_id', 'body_sha256', 'requested_by', 'requested_at',
      'is_withdrawn', 'withdrawn_at'] loop
    if (v_new -> v_col) is distinct from (v_old -> v_col) then
      v_what := case v_col
        when 'document_id' then 'document'
        when 'body_sha256' then 'hash of the text circulated'
        when 'requested_by' then 'author'
        when 'requested_at' then 'time'
        when 'is_withdrawn' then 'withdrawal'
        when 'withdrawn_at' then 'time of withdrawal'
        else v_col end;
      raise exception
        'The % on a signature request is the database''s to write, not '
        'a client''s.', v_what
        using errcode = '42501';
    end if;
  end loop;
  return new;
end $$;

revoke all on function app.signature_evidence_is_the_databases() from public, anon, authenticated;

comment on function app.signature_evidence_is_the_databases() is
  'Refuses a client''s own statement that writes the evidence of a '
  'signature -- a line''s status, time, name, decline reason, hash, '
  'address, browser or login, or a request''s text hash, author or '
  'withdrawal -- or that inserts anything but a pending line, inserts a '
  'request, or deletes a line or request somebody has signed or '
  'declined. The signing functions run as their owner and pass. 0791.';

create trigger signature_is_the_databases
  before insert or update or delete on public.corp_signatures
  for each row execute function app.signature_evidence_is_the_databases();

create trigger signature_is_the_databases
  before insert or update or delete on public.corp_signature_requests
  for each row execute function app.signature_evidence_is_the_databases();
