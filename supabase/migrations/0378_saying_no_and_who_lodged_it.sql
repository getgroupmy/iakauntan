-- =====================================================================
-- iAkauntan :: 0378 saying no, and who lodged it
--
-- Two things a corporate secretarial file has to be able to record and
-- could not.
--
-- ---------------------------------------------------------------------
-- A request that could only be signed
--
-- `app.signature_status` is ('pending', 'signed', 'declined',
-- 'withdrawn') and `corp_signatures.decline_reason` has been a column
-- since `0069`. Nothing has ever produced `declined` — the word appears
-- in the enum and nowhere else in the migrations, the app or the edge
-- functions.
--
-- So a director who will not sign a resolution has no way to say so.
-- The line stays `pending` and looks identical to a director who has
-- not opened the email yet, which is the worst possible reading: the
-- secretary chasing the signature cannot tell "not read" from "read and
-- refused", and the difference is whether to send a reminder or to redo
-- the resolution.
--
-- Withdrawing exists and is not the same thing. Withdrawal is the
-- company taking the request back; declining is the signatory refusing
-- it, and a file that cannot tell those apart cannot show that a
-- director dissented — which is exactly what a dissent is for.
--
-- The reason is required. A refusal with no reason leaves the same
-- phone call to make, and this is the moment the answer is known.
--
-- Declining is offered through both doors signing has: the signed-in
-- one and `0070`'s scoped link. A director who reads the document on a
-- link and will not sign it must be able to say so on the same screen,
-- or they will simply not reply.
--
-- ---------------------------------------------------------------------
-- A lodgement recorded by an update statement
--
-- `corp_filings.lodged_by` and `fee_paid` have been columns since
-- `0062` and neither has ever been written. `corpMarkLodged` in the app
-- is a bare `update` of three fields, which is the second problem: the
-- only check on it — that the lodgement date is not in the future —
-- lives in Dart, and a rule enforced only in Dart is not enforced.
--
-- What that costs. `lodged_by` is who did it: a practice with four
-- people lodging on behalf of a hundred companies, and a filing that
-- turns out to be wrong, has no record of whose it was. `fee_paid` is
-- the SSM fee the practice paid on the client's behalf and recharges —
-- unrecorded, it is never billed, and a fee nobody wrote down is a fee
-- nobody invoices.
--
-- So the update becomes a function with the guards the app was carrying
-- alone: no future date, nothing before the thing being notified
-- happened, and a filing already lodged is not re-lodged over the top
-- of its own reference.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Saying no
-- ---------------------------------------------------------------------
create or replace function public.corp_decline_signature(
  p_signature_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  s        public.corp_signatures;
  r        public.corp_signature_requests;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  select * into s from public.corp_signatures where id = p_signature_id;
  if s.id is null then
    raise exception 'Signature not found' using errcode = 'P0002';
  end if;
  if not app.can_write(s.org_id) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if s.status <> 'pending' then
    raise exception 'This signature is already %', s.status
      using errcode = '22023';
  end if;
  if v_reason is null then
    raise exception
      'Say why. A refusal with no reason leaves the secretary the same '
      'phone call to make, and this is the moment the answer is known.'
      using errcode = '23514';
  end if;

  select * into r from public.corp_signature_requests where id = s.request_id;
  if r.is_withdrawn then
    raise exception 'The signature request has been withdrawn'
      using errcode = '22023';
  end if;

  update public.corp_signatures
     set status         = 'declined',
         decline_reason = v_reason,
         -- The same evidence a signature carries. A refusal is a fact
         -- about the document too, and it is worth as much.
         ip_address     = nullif(split_part(coalesce(
           app.request_header('x-forwarded-for'), ''), ',', 1), '')::inet,
         user_agent     = app.request_header('user-agent'),
         signed_by      = auth.uid()
   where id = p_signature_id;
end $$;

-- The same, on `0070`'s scoped link. Somebody reading the document on a
-- link who will not sign it has to be able to say so on that screen, or
-- they simply do not reply.
create or replace function public.corp_decline_with_link(
  p_token text, p_reason text)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  l        public.corp_signing_links;
  s        public.corp_signatures;
  r        public.corp_signature_requests;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if v_reason is null then
    raise exception 'Say why you are not signing.' using errcode = '23514';
  end if;

  select * into l from public.corp_signing_links
   where token_hash = app.corp_token_hash(p_token);
  if l.id is null then
    raise exception 'This link is not valid' using errcode = '42501';
  end if;
  if l.revoked_at is not null or l.used_at is not null then
    raise exception 'This link has already been used' using errcode = '22023';
  end if;
  if l.expires_at < now() then
    raise exception 'This link has expired' using errcode = '22023';
  end if;

  select * into s from public.corp_signatures where id = l.signature_id;
  if s.status <> 'pending' then
    raise exception 'That line is already %', s.status using errcode = '22023';
  end if;

  select * into r from public.corp_signature_requests where id = s.request_id;
  if r.is_withdrawn then
    raise exception 'The signature request has been withdrawn'
      using errcode = '22023';
  end if;

  update public.corp_signatures
     set status         = 'declined',
         decline_reason = v_reason,
         ip_address     = nullif(split_part(coalesce(
           app.request_header('x-forwarded-for'), ''), ',', 1), '')::inet,
         user_agent     = app.request_header('user-agent'),
         -- Null, as it is for signing through a link: nobody was signed
         -- in, and the link is the attribution.
         signed_by      = null
   where id = s.id;

  -- The link is spent either way. A link that survives a refusal is a
  -- link somebody can come back and sign with after saying no.
  update public.corp_signing_links
     set used_at = now() where id = l.id;

  return 'declined';
end $$;

-- ---------------------------------------------------------------------
-- Recording the lodgement
-- ---------------------------------------------------------------------
create or replace function public.corp_mark_lodged(
  p_filing uuid,
  p_lodged_on date default null,
  p_reference text default null,
  p_fee_paid numeric default null)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  f    public.corp_filings;
  v_on date;
begin
  select * into f from public.corp_filings where id = p_filing;
  if f.id is null then
    raise exception 'No such filing.' using errcode = 'P0002';
  end if;
  if not app.can_write(f.org_id) then
    raise exception 'not permitted to record a lodgement'
      using errcode = '42501';
  end if;
  if f.status in ('lodged', 'approved') then
    raise exception
      'That filing was lodged on %. Recording it again would write over '
      'the reference SSM gave it.', to_char(f.lodged_on, 'DD Mon YYYY')
      using errcode = '23514';
  end if;

  v_on := coalesce(p_lodged_on,
                   (now() at time zone 'Asia/Kuala_Lumpur')::date);
  -- The guard the app was carrying on its own. A lodgement is a thing
  -- that happened; a date in the future is a plan.
  if v_on > (now() at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception
      'A lodgement is something that has happened. That date is in the '
      'future.' using errcode = '23514';
  end if;
  if v_on < f.trigger_date then
    raise exception
      'The filing cannot have been lodged before the event it notifies '
      '(%).', to_char(f.trigger_date, 'DD Mon YYYY') using errcode = '23514';
  end if;
  if p_fee_paid is not null and p_fee_paid < 0 then
    raise exception 'A fee is not negative.' using errcode = '23514';
  end if;

  update public.corp_filings set
    status        = 'lodged',
    lodged_on     = v_on,
    ssm_reference = nullif(btrim(coalesce(p_reference, '')), ''),
    -- Who did it, and what it cost. Neither has ever been written: a
    -- practice with a filing that turns out to be wrong had no record of
    -- whose it was, and a fee nobody wrote down is a fee nobody bills.
    lodged_by     = auth.uid(),
    fee_paid      = p_fee_paid,
    updated_at    = now()
  where id = p_filing;
end $$;

revoke all on function public.corp_decline_signature(uuid, text)
  from public, anon;
revoke all on function public.corp_decline_with_link(text, text) from public;
revoke all on function public.corp_mark_lodged(uuid, date, text, numeric)
  from public, anon;
grant execute on function public.corp_decline_signature(uuid, text)
  to authenticated;
-- Anonymous, like `corp_sign_with_link`: the token is the credential,
-- and somebody refusing to sign has no account here either.
grant execute on function public.corp_decline_with_link(text, text)
  to anon, authenticated;
grant execute on function public.corp_mark_lodged(uuid, date, text, numeric)
  to authenticated;

comment on function public.corp_decline_signature(uuid, text) is
  'Refusing to sign, with the reason. `declined` was in the enum from '
  '0069 and nothing could produce it, so a director who would not sign '
  'looked exactly like one who had not read the email.';
comment on function public.corp_mark_lodged(uuid, date, text, numeric) is
  'Records a lodgement, with who did it and what SSM charged. Replaces a '
  'bare update whose only check — that the date is not in the future — '
  'lived in Dart.';
