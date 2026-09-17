-- =====================================================================
-- iAkauntan :: the six pages around the product
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/site_pages.sql
--
-- `0334` gives the console the pages beside the landing page: the
-- wording on the two auth screens, and Terms, Privacy and Contact.
--
-- Three of the things it does are silent when they break:
--
--   * the gate. Terms, Privacy and Contact only travel once somebody
--     has published them — a privacy policy half written is not one,
--     and a draft leaking is worse than a missing link;
--   * the ungate. The two auth screens always draw, so their wording
--     has to come back whether or not anybody pressed Publish. Gate
--     them by accident and every visitor gets a blank heading over the
--     password box;
--   * the writer. Anybody signed in can call an RPC. These pages are
--     the whole platform's, not one company's.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- Six rows, and the table will not hold a seventh kind
--
-- The slugs are fixed because six screens read them. A row nothing
-- renders is a row somebody spends an afternoon looking for.
--
-- `login` is `0348`: the same form at a company's own address, with
-- its own words over it.
-- ---------------------------------------------------------------------
do $$
declare v_n integer; v_refused boolean := false;
begin
  select count(*) into v_n from public.site_pages;
  perform pg_temp.check_eq('the six pages are there to open', v_n, 6);

  select count(*) into v_n from public.site_pages
   where slug in ('signin', 'signup', 'login', 'terms', 'privacy',
                  'contact');
  perform pg_temp.check_eq('and they are the six the screens read', v_n, 6);

  begin
    insert into public.site_pages (slug) values ('about');
  exception when check_violation then v_refused := true;
  end;
  perform pg_temp.check_true('a seventh slug is refused by the table',
                             v_refused);
end $$;

-- ---------------------------------------------------------------------
-- The login page is a door of its own
--
-- Everything asserted here is about the one thing that separates it
-- from the five that came before: it is a *second* copy of the sign-in
-- wording, for the address a company's own staff arrive at, and it has
-- to behave like the auth pages rather than like the linked ones.
--
-- The seed is the part worth pinning. A company that has copy over its
-- door today must still have it tomorrow, so `0348` copies `signin`
-- into `login` rather than starting it empty — and a migration that
-- quietly stopped doing that would look like nothing at all until an
-- operator noticed their door had gone blank.
-- ---------------------------------------------------------------------
do $$
declare v_n integer; v_title text; v_published boolean;
begin
  select count(*) into v_n from public.site_pages where slug = 'login';
  perform pg_temp.check_eq('there is a login page', v_n, 1);

  -- Ungated, like the other two forms. A door with no heading is what
  -- gating this would produce, on every company address at once.
  select count(*) into v_n from public.site_pages()
   where slug = 'login';
  perform pg_temp.check_eq('a stranger reads it, published or not', v_n, 1);

  select p.is_published into v_published
    from public.site_pages p where p.slug = 'login';
  perform pg_temp.check_true('and it is not published, so the gate is '
                             'genuinely not what let it through',
                             not v_published);
end $$;

-- The seed itself, re-run against a `signin` row that has words in it.
-- The rows in front of the migration were empty, so re-running the
-- statement is the only way to see it carry anything.
do $$
declare v_title text; v_body text;
begin
  update public.site_pages set title = 'Welcome back', body = 'Sign in to'
   where slug = 'signin';
  delete from public.site_pages where slug = 'login';

  insert into public.site_pages (slug, title, body, is_published)
  select 'login', p.title, p.body, p.is_published
    from public.site_pages p
   where p.slug = 'signin'
  on conflict (slug) do nothing;

  select p.title, p.body into v_title, v_body
    from public.site_pages p where p.slug = 'login';

  perform pg_temp.check_eq('a new door opens with the words the old one '
                           'had', v_title, 'Welcome back');
  perform pg_temp.check_eq('body and all', v_body, 'Sign in to');
end $$;

-- And the writer takes it, which is what the console needs.
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_title text;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_save_site_page('login', 'Masuk ke Sinar', null);
  select p.title into v_title
    from public.site_pages p where p.slug = 'login';
  perform pg_temp.check_eq('the console can write the login page',
                           v_title, 'Masuk ke Sinar');
end $$;

-- ---------------------------------------------------------------------
-- A stranger reads the two auth pages, published or not
--
-- This is the half that has no gate, and the reason is the screen: the
-- sign-in form draws for everybody who types the address, so the line
-- above it cannot wait for a publication step nobody would think to
-- take.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_role text; v_titles text[];
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_save_site_page('signin', 'Selamat kembali',
                                         'Masuk untuk teruskan.');
  perform public.platform_save_site_page('signup', 'Buka akaun',
                                         'Percuma untuk bermula.');

  perform pg_temp.sign_out();
  set local role anon;
  v_role := current_user;
  select array_agg(p.title order by p.slug) into v_titles
    from public.site_pages() p where p.slug in ('signin', 'signup');
  reset role;

  perform pg_temp.check_true('the test ran as an anonymous visitor',
                             v_role = 'anon');
  perform pg_temp.check_eq('the sign-in wording reaches a stranger',
                           v_titles[1], 'Selamat kembali');
  perform pg_temp.check_eq('and the sign-up wording', v_titles[2], 'Buka akaun');

  -- And nobody has published anything, which is the point.
  perform pg_temp.check_eq('with neither of them published',
    (select count(*) from public.site_pages
      where slug in ('signin', 'signup') and is_published), 0::bigint);
end $$;

-- ---------------------------------------------------------------------
-- And the three linked pages only once they are published
--
-- A draft privacy policy in the footer is a promise the platform has
-- not made yet.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_before integer; v_after integer; v_body text;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_save_site_page('privacy', 'Dasar Privasi',
                                         'Draf. Belum siap.');

  perform pg_temp.sign_out();
  set local role anon;
  select count(*) into v_before from public.site_pages() p
   where p.slug = 'privacy';
  reset role;
  perform pg_temp.check_eq('a draft policy is not a policy anybody sees',
                           v_before, 0);

  perform pg_temp.sign_in_as(v_admin);
  perform public.platform_save_site_page('privacy', p_is_published => true);

  perform pg_temp.sign_out();
  set local role anon;
  select count(*), max(p.body) into v_after, v_body
    from public.site_pages() p where p.slug = 'privacy';
  reset role;
  perform pg_temp.check_eq('publishing it hands it to the visitor', v_after, 1);
  perform pg_temp.check_eq('with the wording that was written',
                           v_body, 'Draf. Belum siap.');
end $$;

-- ---------------------------------------------------------------------
-- The table itself is shut, so the function is the whole surface
--
-- Same shape as the landing page: a policy-protected table anon can
-- still select from is a table one forgotten policy away from being
-- readable. Ungranted, and the answer is a privilege error rather than
-- an empty set.
-- ---------------------------------------------------------------------
do $$
declare v_shut boolean := false; v_n integer;
begin
  perform pg_temp.sign_out();
  set local role anon;
  begin
    select count(*) into v_n from public.site_pages;
  exception when insufficient_privilege then v_shut := true;
  end;
  reset role;
  perform pg_temp.check_true('the pages table is shut to a stranger', v_shut);
end $$;

-- ---------------------------------------------------------------------
-- Only a platform administrator writes them
--
-- These pages have no org_id. A company owner editing the privacy
-- policy would be editing every other company's, which is the argument
-- the landing page makes about itself.
-- ---------------------------------------------------------------------
do $$
declare
  v_outsider uuid := pg_temp.another_user('not-the-platform@iakauntan.test');
  v_denied boolean := false; v_body text;
begin
  perform pg_temp.check_true('the outsider is not a platform administrator',
    not exists (select 1 from public.platform_admins where user_id = v_outsider));

  perform pg_temp.sign_in_as(v_outsider);
  begin
    perform public.platform_save_site_page('terms', 'Mine now', 'All of it.');
  exception when insufficient_privilege then v_denied := true;
  end;
  perform pg_temp.check_true('somebody else''s owner cannot rewrite the terms',
                             v_denied);

  select p.title into v_body from public.site_pages p where p.slug = 'terms';
  perform pg_temp.check_true('and the page is as it was', v_body is null);
end $$;

-- ---------------------------------------------------------------------
-- A mistyped slug is told which six there are
--
-- The check constraint would refuse it too, with a message about a
-- constraint. An operator wants the list.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_msg text; v_state text;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  begin
    perform public.platform_save_site_page('about', 'Us', 'Hello.');
  exception when others then
    v_msg := sqlerrm; v_state := sqlstate;
  end;

  perform pg_temp.check_eq('a slug nothing renders is refused', v_state, '22023');
  perform pg_temp.check_true('and the refusal names the six',
    v_msg like '%signin%' and v_msg like '%login%'
    and v_msg like '%contact%');
end $$;

-- ---------------------------------------------------------------------
-- An emptied box is a null, and an untouched one is untouched
--
-- Clearing a field asks for the shipped copy back. An empty string is
-- not null, and the screen's `??` renders it — a heading of nothing.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_title text; v_body text; v_published boolean;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_save_site_page('contact', 'Hubungi kami',
                                         'Tingkat 3, Menara ABC.');
  perform public.platform_save_site_page('contact', p_is_published => true);

  -- Publishing did not disturb the wording.
  select p.title, p.body into v_title, v_body
    from public.site_pages p where p.slug = 'contact';
  perform pg_temp.check_eq('a field left out is a field left alone',
                           v_title, 'Hubungi kami');
  perform pg_temp.check_eq('and so is the body', v_body,
                           'Tingkat 3, Menara ABC.');

  perform public.platform_save_site_page('contact', p_title => '   ');
  select p.title, p.is_published into v_title, v_published
    from public.site_pages p where p.slug = 'contact';
  perform pg_temp.check_true('an emptied heading is null, not ""',
                             v_title is null);
  perform pg_temp.check_true('and clearing it did not unpublish the page',
                             v_published);
end $$;

-- ---------------------------------------------------------------------
-- Saving stamps who and when
--
-- The console shows it, and a legal page nobody can date is a legal
-- page nobody can rely on.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_by uuid; v_at timestamptz;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_save_site_page('terms', 'Terma Penggunaan',
                                         'Satu. Dua. Tiga.');
  select p.updated_by, p.updated_at into v_by, v_at
    from public.site_pages p where p.slug = 'terms';

  perform pg_temp.check_eq('the page knows who last wrote it', v_by, v_admin);
  perform pg_temp.check_true('and when',
                             v_at > now() - interval '1 minute');
end $$;

rollback;
