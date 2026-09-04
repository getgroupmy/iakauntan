-- =====================================================================
-- iAkauntan :: the list you keep beside the books
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/todos.sql
--
-- 0526. A to-do belongs to ONE PERSON at ONE COMPANY, and row level
-- security is the ENTIRE guard: no function checks the caller, because
-- a client writes this table straight through PostgREST. So almost
-- every assertion here is a refusal, and each is paired with the write
-- that must still succeed -- N REFUSALS ARE SATISFIED BY A POLICY THAT
-- REFUSES EVERYTHING.
--
-- AND EVERY ONE OF THEM RUNS AS `authenticated`. The suite connects as
-- `postgres`, which is a superuser and BYPASSES row level security
-- altogether: `sign_in_as` sets the JWT claim the policies read and
-- changes nothing about whether the policies are consulted at all. A
-- file that only signs in and selects asserts that the rows exist, not
-- that anybody is stopped from reading them -- which is how this file
-- read on its first run, with every refusal below passing against
-- nothing. `v_role` is asserted so that cannot be true again without
-- something failing.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on
begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_me    uuid := pg_temp.test_user();
  v_them  uuid;
  v_mine  uuid;
  v_other uuid;
  v_todo  uuid;
  v_their uuid;
  v_role  text;
  v_n     integer;
  v_ok    boolean;
  v_txt   text;
begin
  v_mine := pg_temp.test_org('Kedai Senarai Sdn Bhd');
  v_them := pg_temp.another_user('lain@senarai.test');

  -- A company I have nothing to do with. `pg_temp.test_org` always
  -- makes the fixture user the owner, which would make me a member and
  -- prove nothing, so this one names the other person as its creator --
  -- the trigger on `organizations` writes the owner's membership from
  -- exactly that column.
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values ('Syarikat Lain Sdn Bhd',
          'syarikat-lain-' || gen_random_uuid(), 'sdn_bhd', 'MYR', v_them)
  returning id into v_other;
  perform pg_temp.check_eq('the other company is theirs and not mine',
    (select count(*)::numeric from public.org_members
      where org_id = v_other and user_id = v_me), 0);

  -- ==================================================================
  -- 1. My own list, at my own company
  -- ==================================================================
  perform pg_temp.sign_in_as(v_me);
  begin
    set local role authenticated;
    v_role := current_user;
    insert into public.todos (org_id, user_id, title)
    values (v_mine, v_me, 'Kejar invois Ramli')
    returning id into v_todo;
  end;
  reset role;

  perform pg_temp.check_eq('the file runs under row level security',
    v_role, 'authenticated');
  perform pg_temp.check_eq('an item lands on my list',
    (select count(*)::numeric from public.todos where id = v_todo), 1);
  perform pg_temp.check_eq('at normal priority unless it is said otherwise',
    (select priority from public.todos where id = v_todo), 'normal');
  perform pg_temp.check_true('and open until it is done',
    (select done_at is null from public.todos where id = v_todo));

  -- Done is a TIME, not a flag: "what did I clear yesterday" is a
  -- question somebody asks, and a boolean cannot answer it.
  begin
    set local role authenticated;
    update public.todos set done_at = now() where id = v_todo;
  end;
  reset role;
  perform pg_temp.check_true('clearing an item records WHEN',
    (select done_at is not null from public.todos where id = v_todo));

  -- ==================================================================
  -- 2. An item with no words on it
  --
  -- NOT NULL does not refuse an empty string, and a row with no title
  -- is one nobody can act on and nobody can find again.
  -- ==================================================================
  begin
    set local role authenticated;
    begin
      insert into public.todos (org_id, user_id, title)
      values (v_mine, v_me, '   ');
      v_ok := true;
    exception when check_violation then v_ok := false;
    end;
  end;
  reset role;
  perform pg_temp.check_true('an item needs words on it', not v_ok);

  -- ==================================================================
  -- 3. A priority that is not one, and the three that are
  -- ==================================================================
  begin
    set local role authenticated;
    begin
      insert into public.todos (org_id, user_id, title, priority)
      values (v_mine, v_me, 'Sesuatu', 'urgent');
      v_ok := true;
    exception when check_violation then v_ok := false;
    end;
    -- The control: the three that DO exist are accepted, so the refusal
    -- above is not a check that refuses everything.
    insert into public.todos (org_id, user_id, title, priority)
    values (v_mine, v_me, 'Rendah', 'low'),
           (v_mine, v_me, 'Biasa', 'normal'),
           (v_mine, v_me, 'Tinggi', 'high');
  end;
  reset role;
  perform pg_temp.check_true('a priority is one of three', not v_ok);
  perform pg_temp.check_eq('and all three of them are accepted',
    (select count(*)::numeric from public.todos
      where org_id = v_mine and priority in ('low', 'normal', 'high')), 4);

  -- ==================================================================
  -- 4. It is MY list
  --
  -- The whole guard, asked from the other person's session, because a
  -- policy is only a policy when somebody else is asking.
  -- ==================================================================
  perform pg_temp.sign_in_as(v_them);
  begin
    set local role authenticated;
    -- What they MUST be able to do, first.
    insert into public.todos (org_id, user_id, title)
    values (v_other, v_them, 'Senarai saya sendiri')
    returning id into v_their;
    select count(*) into v_n from public.todos where org_id = v_other;
  end;
  reset role;
  perform pg_temp.check_eq('somebody else keeps their own list',
    v_n::numeric, 1);

  perform pg_temp.sign_in_as(v_them);
  begin
    set local role authenticated;
    select count(*) into v_n from public.todos where org_id = v_mine;
  end;
  reset role;
  perform pg_temp.check_eq('and cannot see mine, though it is there',
    v_n::numeric, 0);

  -- Nor file one against my company.
  perform pg_temp.sign_in_as(v_them);
  begin
    set local role authenticated;
    begin
      insert into public.todos (org_id, user_id, title)
      values (v_mine, v_them, 'Masuk campur');
      v_ok := true;
    exception when insufficient_privilege then v_ok := false;
    end;
  end;
  reset role;
  perform pg_temp.check_true('an outsider cannot file against my company',
    not v_ok);

  -- Nor put one on MY list at THEIR company. This is the shape the
  -- `user_id = auth.uid()` half of the check refuses and the
  -- `is_org_member` half does not: without it, anybody could push work
  -- onto anybody's list.
  perform pg_temp.sign_in_as(v_them);
  begin
    set local role authenticated;
    begin
      insert into public.todos (org_id, user_id, title)
      values (v_other, v_me, 'Kerja untuk awak');
      v_ok := true;
    exception when insufficient_privilege then v_ok := false;
    end;
  end;
  reset role;
  perform pg_temp.check_true(
    'nobody can put an item on another person''s list', not v_ok);

  -- I cannot see theirs either. Symmetry: a policy asserted in one
  -- direction only is half asserted.
  perform pg_temp.sign_in_as(v_me);
  begin
    set local role authenticated;
    select count(*) into v_n from public.todos where org_id = v_other;
  end;
  reset role;
  perform pg_temp.check_eq('and I cannot see theirs', v_n::numeric, 0);

  -- ==================================================================
  -- 5. Reaching another person's item by id
  --
  -- The counts above are satisfied by a filter on org_id; this is the
  -- row itself, named, which is what a client would actually send.
  -- ==================================================================
  perform pg_temp.sign_in_as(v_me);
  begin
    set local role authenticated;
    select count(*) into v_n from public.todos where id = v_their;
    perform pg_temp.check_eq('another person''s item cannot be read by id',
      v_n::numeric, 0);

    update public.todos set title = 'Diubah' where id = v_their;
    get diagnostics v_n = row_count;
    perform pg_temp.check_eq('nor updated', v_n::numeric, 0);

    delete from public.todos where id = v_their;
    get diagnostics v_n = row_count;
    perform pg_temp.check_eq('nor deleted', v_n::numeric, 0);

    -- The control for all three: my own item answers to exactly these
    -- statements.
    select id into v_todo from public.todos
     where org_id = v_mine and title = 'Tinggi';
    update public.todos set title = 'Tinggi sekali' where id = v_todo;
    get diagnostics v_n = row_count;
    perform pg_temp.check_eq('but my own item updates', v_n::numeric, 1);
    delete from public.todos where id = v_todo;
    get diagnostics v_n = row_count;
    perform pg_temp.check_eq('and deletes', v_n::numeric, 1);
  end;
  reset role;

  -- And theirs is still there, which is what "refused" has to mean: the
  -- delete must have changed nothing rather than merely reported
  -- nothing.
  perform pg_temp.check_eq('the item it could not delete is still there',
    (select count(*)::numeric from public.todos where id = v_their), 1);

  -- ==================================================================
  -- 6. Handing my own item to somebody else
  --
  -- The UPDATE policy's WITH CHECK. Without it the row I own could be
  -- rewritten to name another user: an item nobody can now reach,
  -- sitting on a list its new owner never sees.
  -- ==================================================================
  perform pg_temp.sign_in_as(v_me);
  begin
    set local role authenticated;
    select id into v_todo from public.todos
     where org_id = v_mine and title = 'Rendah';
    begin
      update public.todos set user_id = v_them where id = v_todo;
      v_ok := true;
    exception when insufficient_privilege then v_ok := false;
    end;
  end;
  reset role;
  perform pg_temp.check_true('an item cannot be handed to somebody else',
    not v_ok);

  perform pg_temp.sign_in_as(v_me);
  begin
    set local role authenticated;
    begin
      update public.todos set org_id = v_other where id = v_todo;
      v_ok := true;
    exception when insufficient_privilege then v_ok := false;
    end;
  end;
  reset role;
  perform pg_temp.check_true('nor moved to another company', not v_ok);

  -- The control: an ordinary edit of the same row, in the same session,
  -- still goes through. Otherwise the two refusals are satisfied by an
  -- UPDATE policy that refuses every update.
  perform pg_temp.sign_in_as(v_me);
  begin
    set local role authenticated;
    update public.todos set title = 'Rendah, tetapi diubah'
     where id = v_todo;
    get diagnostics v_n = row_count;
  end;
  reset role;
  perform pg_temp.check_eq('but the same row still takes an ordinary edit',
    v_n::numeric, 1);

  -- ==================================================================
  -- 7. What the screens read
  --
  -- Open items, soonest first, undated last. The dashboard card shows
  -- the top of exactly this order, so an ordering that put the undated
  -- ones first would fill the card with what is not due.
  -- ==================================================================
  delete from public.todos where org_id = v_mine;
  insert into public.todos (org_id, user_id, title, due_date) values
    (v_mine, v_me, 'Tiada tarikh', null),
    (v_mine, v_me, 'Lusa', app.today() + 2),
    (v_mine, v_me, 'Esok', app.today() + 1),
    (v_mine, v_me, 'Sudah siap', app.today());
  update public.todos set done_at = now()
   where org_id = v_mine and title = 'Sudah siap';

  select string_agg(title, ', ' order by due_date nulls last, created_at)
    into v_txt
    from public.todos
   where org_id = v_mine and user_id = v_me and done_at is null;
  perform pg_temp.check_eq('the open items come back soonest first',
    v_txt, 'Esok, Lusa, Tiada tarikh');
  perform pg_temp.check_eq('and what is done is not among them',
    (select count(*)::numeric from public.todos
      where org_id = v_mine and done_at is null), 3);

  -- ==================================================================
  -- 8. What is overdue
  --
  -- The figure the ticker carries. Today is not overdue; yesterday is.
  -- ==================================================================
  insert into public.todos (org_id, user_id, title, due_date) values
    (v_mine, v_me, 'Semalam', app.today() - 1),
    (v_mine, v_me, 'Hari ini', app.today());
  perform pg_temp.check_eq('an item due yesterday is overdue',
    (select count(*)::numeric from public.todos
      where org_id = v_mine and user_id = v_me and done_at is null
        and due_date < app.today()), 1);
  perform pg_temp.check_eq('and one due today is not',
    (select count(*)::numeric from public.todos
      where org_id = v_mine and user_id = v_me and done_at is null
        and due_date = app.today()), 1);

  raise notice 'ok   the list you keep beside the books';
end $$;

-- ---------------------------------------------------------------------
-- Nobody signed in reads nothing
--
-- Supabase hands `anon` every new table in `public`. Asserted as a
-- privilege rather than by querying, because a table with no rows
-- visible and a table nobody may read look the same from a select.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('anon cannot read the to-do list',
    not has_table_privilege('anon', 'public.todos', 'select'));
  perform pg_temp.check_true('nor write to it',
    not has_table_privilege('anon', 'public.todos', 'insert'));
  perform pg_temp.check_true('and a signed-in user still can',
    has_table_privilege('authenticated', 'public.todos', 'select'));
end $$;

rollback;
