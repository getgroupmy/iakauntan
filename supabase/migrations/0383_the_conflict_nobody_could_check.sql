-- =====================================================================
-- iAkauntan :: 0383 the conflict nobody could check
--
-- `matters.opposing_party`, `matters.fee_earner` and
-- `matters.agreed_fee` have been columns since `0021`. None of them is
-- written or read by anything.
--
-- ---------------------------------------------------------------------
-- The one that is a rule and not a field
--
-- `opposing_party` is the column a conflict check reads. Rule 3 of the
-- Legal Profession (Practice and Etiquette) Rules 1978 stops an
-- advocate and solicitor accepting instructions where they would be
-- acting against a client's interest, and the commonest way a firm
-- walks into one is not subtlety — it is a second partner opening a
-- file, on a Tuesday, against a company the firm already acts for.
--
-- The check is a query, and until now there was nothing to query. Every
-- matter recorded who the client was; not one recorded who was on the
-- other side, so "do we act for the people this new file is against"
-- had no answer in the data.
--
-- `open_matter` now asks it, in both directions, because a conflict has
-- two shapes and only checking one is checking neither:
--
--   * the proposed opposing party is somebody the firm acts for now;
--   * the proposed client is somebody the firm has acted against.
--
-- The way through is a written note, and it is required rather than
-- offered. A conflict can be waived by informed consent in some
-- circumstances and cannot in others, and that judgement is a
-- solicitor's — but it has to be recorded, because the file is what the
-- Bar Council looks at afterwards. A refusal with no way through would
-- be worse: somebody would leave `opposing_party` empty to open the
-- file, and the column would go back to being what it has been.
--
-- ---------------------------------------------------------------------
-- Matching a name that was typed
--
-- `opposing_party` is free text, and a firm that types "ABC Sdn. Bhd."
-- on one file and "ABC Sdn Bhd" on another has not recorded two
-- different companies. `app.conflict_key` folds case, strips
-- punctuation, collapses spaces and drops the entity suffixes people
-- vary — Sdn Bhd, Berhad, Bhd — so the two match.
--
-- It is deliberately generous, not clever. A conflict check that misses
-- one is worth nothing; one that raises a question a solicitor then
-- clears in ten seconds costs ten seconds. Being asked about the wrong
-- ABC is the cheap failure, and it is the one this errs towards.
--
-- ---------------------------------------------------------------------
-- The other two
--
-- `fee_earner` is who does the work, as against `responsible_solicitor`
-- who supervises it — and time is recorded against a matter by whoever
-- is signed in, so without a fee earner nothing says whose file it is
-- when they are on leave and somebody has to pick it up.
--
-- `agreed_fee` is what a fixed-fee client was told the matter would
-- cost. Billing past it is not refused: fees do get renegotiated and a
-- disbursement is not a fee. It is reported, because a firm that finds
-- out it over-billed an agreed fee when the client complains has found
-- out from the wrong person.
-- =====================================================================

-- ---------------------------------------------------------------------
-- What is already there
-- ---------------------------------------------------------------------
do $$
declare v_n integer;
begin
  select count(*) into v_n from public.matters
   where deleted_at is null and status = 'open' and opposing_party is null;
  if v_n > 0 then
    raise notice
      '0383: % open matter(s) record no opposing party, so no conflict '
      'check can be run against them. Fill them in on the files that '
      'have another side; the check below only sees what is recorded.',
      v_n;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Matching a name somebody typed
-- ---------------------------------------------------------------------
create or replace function app.conflict_key(p_name text)
returns text
language sql
immutable
set search_path = pg_catalog, public, pg_temp
as $$
  select nullif(
    btrim(
      regexp_replace(
        -- The suffixes a Malaysian company name ends in, which people
        -- write four ways each. Removed so "ABC Sdn. Bhd." and "ABC
        -- Sdn Bhd" are one company, which they are.
        --
        -- Matched as whole words (`\m`…`\M`) rather than by the space
        -- in front of them: two suffixes in a row — "Holdings Berhad"
        -- — share one separator, and a pattern that eats it strips the
        -- first and then cannot see the second.
        regexp_replace(
          -- Fold case, then everything that is not a letter, a digit or
          -- a space becomes a space: full stops, commas, ampersands,
          -- the @ in a firm's own file references.
          regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9 ]+', ' ', 'g'),
          --
          -- `and` is in the list for a different reason: the ampersand
          -- became a space one line above, so "Lim, Tan & Partners" and
          -- "Lim Tan and Partners" are the same firm written two ways
          -- and have to fold to the same key.
          '\m(sdn|bhd|berhad|plt|llp|ltd|limited|inc|incorporated|'
          'enterprise|enterprises|holdings?|and)\M', ' ', 'g'),
        '\s+', ' ', 'g')),
    '');
$$;

-- ---------------------------------------------------------------------
-- The check itself
-- ---------------------------------------------------------------------
-- Deliberately without an "exclude this matter" parameter. The obvious
-- place for one is re-checking a file that already exists, and it turns
-- out a matter can never match its own pairing: the first arm asks
-- whether any file's *client* is the proposed opponent, the second
-- whether any file's *opponent* is the proposed client, and its own
-- client and opponent are the two things it is being asked about. A
-- parameter that cannot change an answer is a parameter somebody will
-- one day rely on.
create or replace function public.check_matter_conflict(
  p_org            uuid,
  p_client         uuid    default null,
  p_opposing_party text    default null)
returns table (
  matter_id     uuid,
  matter_no     text,
  matter_name   text,
  status        text,
  direction     text,
  client_name   text,
  other_side    text)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  with me as (
    select app.conflict_key(p_opposing_party) as opposing_key,
           app.conflict_key((select name from public.contacts
                              where id = p_client)) as client_key
  )
  select m.id, m.matter_no, m.name, m.status::text,
         case
           when app.conflict_key(c.name) = (select opposing_key from me)
             then 'we act for the other side'
           else 'we have acted against this client'
         end,
         c.name, m.opposing_party
    from public.matters m
    join public.contacts c on c.id = m.client_id
   where m.org_id = p_org
     and app.can_read_module(p_org, 'legal')
     and m.deleted_at is null
     and (
       -- We act for the people this new file would be against.
       (   (select opposing_key from me) is not null
        and app.conflict_key(c.name) = (select opposing_key from me))
       -- Or we have already acted against the people it would be for.
       or ((select client_key from me) is not null
        and app.conflict_key(m.opposing_party) = (select client_key from me))
     )
   order by m.status, m.opened_date desc;
$$;

-- ---------------------------------------------------------------------
-- Opening a file, having asked
-- ---------------------------------------------------------------------
create or replace function public.open_matter(
  p_org             uuid,
  p_matter_no       text,
  p_name            text,
  p_client          uuid,
  p_opposing_party  text default null,
  p_matter_type     text default null,
  p_fee_earner      uuid default null,
  p_responsible     uuid default null,
  p_agreed_fee      numeric default null,
  p_hourly_rate     numeric default 0,
  p_conflict_note   text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_conflicts integer;
  v_first     text;
  v_matter    uuid;
begin
  if not app.can_write(p_org) then
    raise exception 'not permitted to open a matter' using errcode = '42501';
  end if;
  if not app.has_module(p_org, 'legal') then
    raise exception 'The legal practice module is not enabled.'
      using errcode = '42501';
  end if;
  if p_client is null then
    raise exception 'A matter is opened for a client.' using errcode = '23502';
  end if;
  if btrim(coalesce(p_matter_no, '')) = ''
     or btrim(coalesce(p_name, '')) = '' then
    raise exception 'A matter has a number and a name.'
      using errcode = '23514';
  end if;

  select count(*), min(matter_no) into v_conflicts, v_first
    from public.check_matter_conflict(p_org, p_client, p_opposing_party);

  if v_conflicts > 0
     and btrim(coalesce(p_conflict_note, '')) = '' then
    raise exception
      'This would put the firm on both sides. % open or closed file(s) '
      'touch these parties, starting with %. Rule 3 of the Legal '
      'Profession (Practice and Etiquette) Rules 1978 is the reason to '
      'stop and look. If it has been considered and cleared, write down '
      'why — the file is what is looked at afterwards.',
      v_conflicts, v_first using errcode = '23514';
  end if;

  insert into public.matters
    (org_id, matter_no, name, client_id, opposing_party, matter_type,
     fee_earner, responsible_solicitor, agreed_fee, hourly_rate,
     notes, created_by)
  values (p_org, btrim(p_matter_no), btrim(p_name), p_client,
          nullif(btrim(coalesce(p_opposing_party, '')), ''), p_matter_type,
          coalesce(p_fee_earner, auth.uid()),
          coalesce(p_responsible, auth.uid()),
          p_agreed_fee, coalesce(p_hourly_rate, 0),
          nullif(btrim(coalesce(p_conflict_note, '')), ''), auth.uid())
  returning id into v_matter;

  return v_matter;
end $$;

-- ---------------------------------------------------------------------
-- A file has somebody whose file it is
-- ---------------------------------------------------------------------
create or replace function app.matter_fee_earner_guard()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  -- Judging the change: an open matter that already has no fee earner
  -- stays editable, because a client's phone number should not be
  -- uncorrectable until somebody decides whose file it is.
  if tg_op = 'UPDATE'
     and old.fee_earner is not distinct from new.fee_earner then
    return new;
  end if;
  if new.fee_earner is null and new.status = 'open' then
    raise exception
      'An open file is somebody''s. Name the fee earner: time is '
      'recorded by whoever is signed in, so without one nothing says '
      'whose matter it is when they are away.' using errcode = '23514';
  end if;
  return new;
end $$;

drop trigger if exists matters_fee_earner_ck on public.matters;
create trigger matters_fee_earner_ck
  before insert or update on public.matters
  for each row execute function app.matter_fee_earner_guard();

-- ---------------------------------------------------------------------
-- Billed past what was agreed
-- ---------------------------------------------------------------------
create or replace function public.report_matters_over_agreed_fee(
  p_org uuid)
returns table (
  matter_id   uuid,
  matter_no   text,
  matter_name text,
  client_name text,
  agreed_fee  numeric,
  billed      numeric,
  unbilled    numeric,
  over_by     numeric)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select m.id, m.matter_no, m.name, c.name, m.agreed_fee,
         b.billed, t.unbilled,
         round(b.billed + t.unbilled - m.agreed_fee, 2)
    from public.matters m
    join public.contacts c on c.id = m.client_id
   cross join lateral (
     -- What has gone out on an invoice. Voided ones did not.
     select coalesce(sum(s.total_amount), 0) as billed
       from public.sales_documents s
      where s.matter_id = m.id
        and s.doc_type = 'invoice'
        and s.status not in ('void', 'draft')
   ) b
   cross join lateral (
     -- And what is waiting to. Time already on a bill is in `billed`,
     -- so counting it here as well would report every matter twice
     -- over.
     select coalesce(sum(e.amount), 0) as unbilled
       from public.time_entries e
      where e.matter_id = m.id and e.is_billable and not e.is_billed
   ) t
   where m.org_id = p_org
     and app.can_read_module(p_org, 'legal')
     and m.deleted_at is null
     -- `> 0` and not merely `is not null`: the comparison below already
     -- drops a null agreed fee, and zero is a firm saying it agreed to
     -- act for nothing. Reporting a pro bono file as over its fee is
     -- reporting the firm's own decision back to it.
     and m.agreed_fee > 0
     and round(b.billed + t.unbilled, 2) > m.agreed_fee
   order by (b.billed + t.unbilled - m.agreed_fee) desc;
$$;

-- ---------------------------------------------------------------------
revoke all on function public.check_matter_conflict(uuid, uuid, text)
  from public, anon;
revoke all on function public.open_matter(
  uuid, text, text, uuid, text, text, uuid, uuid, numeric, numeric, text)
  from public, anon;
revoke all on function
  public.report_matters_over_agreed_fee(uuid) from public, anon;

grant execute on function
  public.check_matter_conflict(uuid, uuid, text) to authenticated;
grant execute on function public.open_matter(
  uuid, text, text, uuid, text, text, uuid, uuid, numeric, numeric, text)
  to authenticated;
grant execute on function
  public.report_matters_over_agreed_fee(uuid) to authenticated;

comment on function public.check_matter_conflict(uuid, uuid, text) is
  'Both directions of a professional conflict: files where the firm '
  'acts for the proposed opposing party, and files where it has acted '
  'against the proposed client. `matters.opposing_party` was a column '
  'nothing wrote, so the question had no answer in the data.';
comment on function app.conflict_key(text) is
  'Folds a typed party name for matching: case, punctuation and the '
  'entity suffixes people vary. Deliberately generous — a check that '
  'misses one is worth nothing, and being asked about the wrong ABC '
  'costs ten seconds.';
comment on function public.report_matters_over_agreed_fee(uuid) is
  'Fixed-fee matters where billed plus unbilled time has passed the '
  'agreed fee. Reported rather than refused: fees get renegotiated, '
  'and a firm that hears about it from the client heard from the wrong '
  'person.';
