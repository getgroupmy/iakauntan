-- A way to post a hand-written journal.
--
-- `create_gl_entry` has been granted to `authenticated` since 0004 and
-- called from nowhere, so there has been no accrual, no prepayment, no
-- adjusting entry and no correction of an opening balance. For an
-- accounting system that is the largest single gap in the app.
--
-- Exposing `create_gl_entry` itself would have been the short way, and
-- it is the wrong one for two reasons:
--
--   1. `p_source app.journal_source` is an enum in the `app` schema,
--      which PostgREST does not expose. The argument is reachable only
--      by making the client name a type it should not know about.
--   2. More seriously, that argument lets a signed-in user post a
--      journal claiming `source = 'payroll'` with any `source_table`
--      and `source_id` they like. Provenance on a ledger line is what
--      the audit trail is *for*; the client has no business asserting
--      it. Every legitimate posting route already goes through
--      `app.create_gl_entry_internal` with the source the route knows.
--
-- So: one function that posts one kind of journal, with the source it
-- always has, and `create_gl_entry` withdrawn from `authenticated`
-- afterwards. Nothing calls it — checked across `app/lib` and
-- `supabase/functions` before revoking.

create or replace function public.post_manual_journal(
  p_org_id uuid,
  p_entry_date date,
  p_lines jsonb,
  p_description text,
  p_reference text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_line  jsonb;
  v_count integer := 0;
  v_bad   integer;
begin
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges to post to the ledger'
      using errcode = '42501';
  end if;

  if coalesce(btrim(p_description), '') = '' then
    raise exception 'A manual journal needs a description'
      using errcode = '23514';
  end if;

  if jsonb_typeof(p_lines) <> 'array' then
    raise exception 'Lines must be an array' using errcode = '22023';
  end if;

  -- Two lines is the floor for a journal: one line cannot balance
  -- against anything, and the internal function would reject it with a
  -- message about debits and credits rather than about the shape of
  -- what was sent.
  if jsonb_array_length(p_lines) < 2 then
    raise exception 'A journal needs at least two lines'
      using errcode = '23514';
  end if;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_count := v_count + 1;

    if nullif(v_line ->> 'account_id', '') is null then
      raise exception 'Line % has no account', v_count using errcode = '23514';
    end if;

    if coalesce((v_line ->> 'debit')::numeric, 0) < 0
       or coalesce((v_line ->> 'credit')::numeric, 0) < 0 then
      raise exception
        'Line % has a negative amount; reverse it with the other column',
        v_count using errcode = '23514';
    end if;

    if coalesce((v_line ->> 'debit')::numeric, 0) > 0
       and coalesce((v_line ->> 'credit')::numeric, 0) > 0 then
      raise exception 'Line % is both a debit and a credit', v_count
        using errcode = '23514';
    end if;
  end loop;

  -- The account must be this organization's and must be one you can
  -- post to. `create_gl_entry_internal` stamps `org_id` from its own
  -- argument and never looks at where the account came from, so without
  -- this a crafted call could hang a line off another organization's
  -- account, or off a header that every report sums over its children.
  select count(*) into v_bad
    from jsonb_array_elements(p_lines) l
    left join public.accounts a
      on a.id = (l ->> 'account_id')::uuid and a.org_id = p_org_id
   where a.id is null or a.is_group or not a.is_active;

  if v_bad > 0 then
    raise exception 'A line names an account that is not an active postable account of this organization'
      using errcode = '23514';
  end if;

  -- Currency is deliberately not an argument. A manual journal is
  -- written in the books' own currency; a foreign entry belongs to the
  -- document that created the exposure, and revaluing it is
  -- `revalue_foreign_balances`, not something to retype by hand.
  return app.create_gl_entry_internal(
    p_org_id      => p_org_id,
    p_entry_date  => p_entry_date,
    p_source      => 'manual'::app.journal_source,
    p_lines       => p_lines,
    p_description => btrim(p_description),
    p_reference   => nullif(btrim(p_reference), ''),
    p_currency    => app.base_currency(p_org_id));
end;
$$;

revoke all on function public.post_manual_journal(uuid, date, jsonb, text, text)
  from public, anon;
grant execute on function public.post_manual_journal(uuid, date, jsonb, text, text)
  to authenticated;

-- Withdrawn: it is reachable only by naming an `app` enum, and it lets
-- the caller forge the provenance of a ledger entry. Every posting
-- route inside the database uses `app.create_gl_entry_internal`
-- directly and is unaffected.
revoke all on function public.create_gl_entry(
  uuid, date, app.journal_source, jsonb, text, text, uuid, text, character, numeric)
  from public, anon, authenticated;

-- The service role keeps it. It bypasses RLS and every grant in this
-- database already, so withholding this one function buys nothing and
-- would silently break an admin path that reached for it.
grant execute on function public.create_gl_entry(
  uuid, date, app.journal_source, jsonb, text, text, uuid, text, character, numeric)
  to service_role;
