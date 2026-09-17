-- ---------------------------------------------------------------------
-- 0500  The month-end pile
-- ---------------------------------------------------------------------
-- Forty draft invoices on the last day of the month, and the only way
-- to put them in the ledger is to open each one and press Post. The
-- same again to send them. A practice doing this for six client
-- companies spends an afternoon on it, and the afternoon is entirely
-- clicking.
--
-- `docs/gaps-against-akaunting.md` calls this "bulk actions across a
-- list", and it is the last of the four smaller items on that page
-- worth building. (Configurable dashboards is the other one left, and
-- the register now says why it is not being built rather than leaving
-- it sitting there as though it were queued.)
--
-- ### One bad document does not stop the batch
--
-- The whole difficulty is here. Posting forty documents is forty
-- postings, not one: the eleventh may be dated into a closed period,
-- the nineteenth may be for a customer over their credit limit, and
-- somebody pressing Post on forty things needs the other thirty-eight
-- to land and a list of the two that did not.
--
-- So each document is posted inside its own exception block. A block is
-- a savepoint, so a document that raises rolls back its own work and
-- nothing else's, and the batch carries on. What comes back is a row
-- per document saying whether it went and, when it did not, what the
-- database said -- in the words it said them, because "Invoice INV-19
-- is dated 3 Jan 2026, which is in a closed period" is the sentence
-- somebody needs and "2 failed" is not.
--
-- ### Not a way around a guard
--
-- Nothing here posts or sends anything the single-document functions
-- would not. `post_sales_document` checks `can_post`, the period, the
-- credit limit and the rest; `email_document` checks its own. These
-- call those. The only thing added is the loop and the report -- and a
-- cap, because a batch is a request and a request that posts ten
-- thousand documents is a way to hold the database open for a minute.
--
-- ### Mutants
--
-- Run against `supabase/tests/bulk_actions.sql`:
--   * the reason swallowed and replaced with a count -- "in the words
--     the database used", which is the assertion that exists because
--     "1 failed" is not something anybody can act on;
--   * the ceiling removed -- "a batch has a ceiling";
--   * a failure reported as success -- killed by "the good ones land
--     even when one is bad", which counts three where two posted,
--     rather than by "and the bad one is named". The count is what
--     notices first, and both assertions are about the same lie;
--   * the same in the send -- killed by "the ones with an address go",
--     for the same reason;
--   * the savepoint per document dropped, and another company's
--     document posted -- both refused by this migration's own
--     self-check before they can install: it will not accept a batch
--     with no `exception when others` in it, nor one that has lost
--     `app.is_org_member`. "the good ones land even when one is bad"
--     and "a batch cannot reach another company's documents" are what
--     would catch them, and what stops a later migration undoing
--     either.
-- ---------------------------------------------------------------------

-- How many is a batch. Not a magic number in three places: the cap, the
-- message that names it, and the assertion all read this.
create or replace function app.bulk_limit()
returns integer language sql immutable
set search_path = public, app, pg_temp as $$ select 200; $$;

comment on function app.bulk_limit() is
  'The most documents one batch may touch. See 0500.';

create or replace function public.bulk_post_documents(p_ids uuid[])
returns table(id uuid, doc_no text, posted boolean, problem text)
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_id  uuid;
  v_no  text;
  v_org uuid;
begin
  if p_ids is null or array_length(p_ids, 1) is null then
    return;
  end if;
  if array_length(p_ids, 1) > app.bulk_limit() then
    raise exception 'A batch is at most % documents at a time',
      app.bulk_limit() using errcode = '22023';
  end if;

  foreach v_id in array p_ids
  loop
    select d.doc_no, d.org_id into v_no, v_org
      from public.sales_documents d where d.id = v_id;

    -- Whose it is, before anything is attempted. `post_sales_document`
    -- would refuse a document in another company anyway -- this is here
    -- so the answer says so rather than saying whatever the posting
    -- function says about a document the caller cannot see.
    if v_no is null or not app.is_org_member(v_org) then
      id := v_id; doc_no := null; posted := false;
      problem := 'No such document';
      return next;
      continue;
    end if;

    -- Its own block, which is its own savepoint: a document that will
    -- not post rolls back what it started and leaves the rest of the
    -- batch alone. Without this the eleventh failure throws away the
    -- ten that worked.
    begin
      perform public.post_sales_document(v_id);
      id := v_id; doc_no := v_no; posted := true; problem := null;
    exception when others then
      -- What the database actually said. A count of failures is not
      -- something anybody can act on.
      id := v_id; doc_no := v_no; posted := false; problem := sqlerrm;
    end;
    return next;
  end loop;
end;
$$;

comment on function public.bulk_post_documents(uuid[]) is
  'Post many sales documents, one savepoint each, and say per document '
  'what happened. See 0500.';

create or replace function public.bulk_email_documents(
  p_ids uuid[], p_template_code text default 'document_new')
returns table(id uuid, doc_no text, sent boolean, problem text)
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_id  uuid;
  v_no  text;
  v_org uuid;
begin
  if p_ids is null or array_length(p_ids, 1) is null then
    return;
  end if;
  if array_length(p_ids, 1) > app.bulk_limit() then
    raise exception 'A batch is at most % documents at a time',
      app.bulk_limit() using errcode = '22023';
  end if;

  foreach v_id in array p_ids
  loop
    select d.doc_no, d.org_id into v_no, v_org
      from public.sales_documents d where d.id = v_id;

    if v_no is null or not app.is_org_member(v_org) then
      id := v_id; doc_no := null; sent := false;
      problem := 'No such document';
      return next;
      continue;
    end if;

    begin
      perform public.email_document(v_id, null, p_template_code);
      id := v_id; doc_no := v_no; sent := true; problem := null;
    exception when others then
      -- The commonest one by far is a customer with no email address,
      -- and it is worth reading: a batch of forty that sends
      -- thirty-seven and names the three contacts to go and fix is a
      -- useful afternoon.
      id := v_id; doc_no := v_no; sent := false; problem := sqlerrm;
    end;
    return next;
  end loop;
end;
$$;

comment on function public.bulk_email_documents(uuid[], text) is
  'Send many sales documents, one savepoint each, and say per document '
  'what happened. See 0500.';

revoke all on function public.bulk_post_documents(uuid[]) from public, anon;
revoke all on function public.bulk_email_documents(uuid[], text)
  from public, anon;
grant execute on function public.bulk_post_documents(uuid[]) to authenticated;
grant execute on function public.bulk_email_documents(uuid[], text)
  to authenticated;

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
declare
  v_post  text := pg_get_functiondef(
    'public.bulk_post_documents(uuid[])'::regprocedure);
  v_email text := pg_get_functiondef(
    'public.bulk_email_documents(uuid[], text)'::regprocedure);
begin
  -- Through the single-document functions, which is where every guard
  -- lives. A batch that wrote to `sales_documents` itself would be a
  -- way around `can_post`, the period lock and the credit limit all at
  -- once.
  if position('public.post_sales_document' in v_post) = 0
     or position('public.email_document' in v_email) = 0 then
    raise exception '0500: a batch is not going through the guards';
  end if;
  if position('update public.sales_documents' in v_post) > 0 then
    raise exception '0500: a batch is writing to documents directly';
  end if;
  -- The savepoint per document, and the cap.
  if position('exception when others' in v_post) = 0
     or position('exception when others' in v_email) = 0 then
    raise exception '0500: one bad document still ends the batch';
  end if;
  if position('app.bulk_limit()' in v_post) = 0
     or position('app.bulk_limit()' in v_email) = 0 then
    raise exception '0500: a batch has no ceiling';
  end if;
  if position('app.is_org_member' in v_post) = 0
     or position('app.is_org_member' in v_email) = 0 then
    raise exception '0500: a batch does not check whose documents these are';
  end if;
  if has_function_privilege('anon', 'public.bulk_post_documents(uuid[])',
                            'execute') then
    raise exception '0500: a stranger can post a pile';
  end if;
end $do$;
