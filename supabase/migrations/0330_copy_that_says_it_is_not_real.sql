-- The front page refuses to publish copy that says it is not real.
--
-- Three testimonials have been live on `iakauntan.com` reading "SAMPLE
-- COPY, NOT A REAL CUSTOMER. … Replace it with a real one", attributed
-- to three named people, beside two figures reading "0 — Sample —
-- replace me". They were typed into the console to see the shape of the
-- band and never taken down, which is the ordinary way this happens and
-- the reason it is worth a guard rather than a reminder.
--
-- It is a worse defect than it looks. A visitor who reads it learns
-- either that the quotes above it are invented too, or that nobody is
-- looking at the front page — and the three people named are real
-- names, with a fabricated quote against each.
--
-- ## Refused at publication, not at storage
--
-- `0317` already refuses a quote with nobody's name against it, because
-- "an unattributed quote is the shape a fabricated one takes". This is
-- the same argument one step along: copy that announces itself as a
-- placeholder may be stored, so the console can hold an example to work
-- from, and may not be switched on.
--
-- That split matters. A rule that refused to store it would send people
-- to write their samples somewhere the platform cannot see, and the
-- next one would go live the same way.
--
-- ## The markers, and why so few
--
-- Only phrases nobody writes by accident in a customer quote. "Sample"
-- alone is a word a real testimonial might use — a laboratory, a
-- surveyor, a company that sends samples — so it is not on the list.
-- What is on it is text that describes itself: a placeholder saying it
-- is one.

create or replace function app.is_placeholder_copy(p_text text)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  -- Deliberately short. Every entry is a phrase that appears in copy
  -- describing itself as unfinished and in no customer's actual words.
  select coalesce(p_text, '') ~* (
    'sample copy'
    '|not a real customer'
    '|replace me'
    '|replace this'
    '|lorem ipsum'
    '|placeholder'
    '|your text here'
    '|todo'
  );
$$;

comment on function app.is_placeholder_copy(text) is
  'Whether a piece of front-page copy announces itself as a placeholder. '
  'Used to refuse publishing it, never to refuse storing it.';

-- ---------------------------------------------------------------------
-- Take down what is live
-- ---------------------------------------------------------------------
-- Switched off rather than deleted: they are somebody's work, they show
-- the shape of the band, and the console is where they are edited into
-- something real. Nothing here is lost.
update public.landing_testimonials
   set is_active = false, updated_at = now()
 where is_active
   and (app.is_placeholder_copy(quote) or app.is_placeholder_copy(author));

update public.landing_stats
   set is_active = false, updated_at = now()
 where is_active
   and (app.is_placeholder_copy(label) or app.is_placeholder_copy(value));

-- ---------------------------------------------------------------------
-- And stop the next one
-- ---------------------------------------------------------------------
create or replace function public.platform_save_landing_testimonial(
  p_id uuid default null,
  p_quote text default null,
  p_author text default null,
  p_company text default null,
  p_avatar_url text default null,
  p_sort_order integer default null,
  p_is_active boolean default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare
  v_id     uuid;
  v_quote  text;
  v_author text;
begin
  if not app.is_platform_admin() then
    raise exception 'The landing page is the whole platform''s front door '
                    'and may only be changed by a platform administrator'
      using errcode = '42501';
  end if;

  -- What this row will read once the save has been applied, which is
  -- what has to be judged: switching an existing sample on sends no
  -- quote at all, and judging only what was sent would let it through.
  select coalesce(nullif(btrim(p_quote), ''), t.quote),
         coalesce(nullif(btrim(p_author), ''), t.author)
    into v_quote, v_author
    from public.landing_testimonials t
   where t.id = p_id;

  v_quote  := coalesce(v_quote, btrim(p_quote));
  v_author := coalesce(v_author, btrim(p_author));

  if coalesce(p_is_active, p_id is null)
     and (app.is_placeholder_copy(v_quote)
          or app.is_placeholder_copy(v_author)) then
    raise exception 'That quote says it is a placeholder. Write what '
                    'somebody actually said, or leave it switched off.'
      using errcode = '23514';
  end if;

  if p_id is null then
    if coalesce(btrim(p_quote), '') = '' then
      raise exception 'A testimonial needs something somebody said'
        using errcode = '23514';
    end if;
    -- An unattributed quote is the shape a fabricated one takes, so the
    -- database asks who said it. It does not — cannot — check that they
    -- did; that is the operator's to stand behind. What it can do is
    -- refuse to store a page element that has nobody's name on it.
    if coalesce(btrim(p_author), '') = '' then
      raise exception 'A quote needs somebody''s name against it'
        using errcode = '23514';
    end if;
    insert into public.landing_testimonials
      (quote, author, company, avatar_url, sort_order, is_active, updated_by)
    values (btrim(p_quote), btrim(p_author), nullif(btrim(p_company), ''),
            nullif(btrim(p_avatar_url), ''),
            coalesce(p_sort_order,
                     (select coalesce(max(sort_order), 0) + 10
                        from public.landing_testimonials)),
            coalesce(p_is_active, true), auth.uid())
    returning id into v_id;
    return v_id;
  end if;

  update public.landing_testimonials t set
    quote      = coalesce(nullif(btrim(p_quote), ''), t.quote),
    author     = coalesce(nullif(btrim(p_author), ''), t.author),
    company    = coalesce(p_company, t.company),
    avatar_url = coalesce(p_avatar_url, t.avatar_url),
    sort_order = coalesce(p_sort_order, t.sort_order),
    is_active  = coalesce(p_is_active, t.is_active),
    updated_by = auth.uid(),
    updated_at = now()
   where t.id = p_id
  returning t.id into v_id;

  if v_id is null then
    raise exception 'No such testimonial' using errcode = 'P0002';
  end if;
  return v_id;
end;
$$;

create or replace function public.platform_save_landing_stat(
  p_id uuid default null,
  p_value text default null,
  p_label text default null,
  p_icon text default null,
  p_sort_order integer default null,
  p_is_active boolean default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare
  v_id    uuid;
  v_value text;
  v_label text;
begin
  if not app.is_platform_admin() then
    raise exception 'The landing page is the whole platform''s front door '
                    'and may only be changed by a platform administrator'
      using errcode = '42501';
  end if;

  select coalesce(nullif(btrim(p_value), ''), s.value),
         coalesce(nullif(btrim(p_label), ''), s.label)
    into v_value, v_label
    from public.landing_stats s
   where s.id = p_id;

  v_value := coalesce(v_value, btrim(p_value));
  v_label := coalesce(v_label, btrim(p_label));

  if coalesce(p_is_active, p_id is null)
     and (app.is_placeholder_copy(v_value)
          or app.is_placeholder_copy(v_label)) then
    raise exception 'That figure says it is a placeholder. Put a real '
                    'number against a real label, or leave it switched off.'
      using errcode = '23514';
  end if;

  if p_id is null then
    if coalesce(btrim(p_value), '') = ''
       or coalesce(btrim(p_label), '') = '' then
      raise exception 'A figure needs both the number and what it counts'
        using errcode = '23514';
    end if;
    insert into public.landing_stats
      (value, label, icon, sort_order, is_active, updated_by)
    values (btrim(p_value), btrim(p_label), p_icon,
            coalesce(p_sort_order,
                     (select coalesce(max(sort_order), 0) + 10
                        from public.landing_stats)),
            coalesce(p_is_active, true), auth.uid())
    returning id into v_id;
    return v_id;
  end if;

  update public.landing_stats s set
    value      = coalesce(nullif(btrim(p_value), ''), s.value),
    label      = coalesce(nullif(btrim(p_label), ''), s.label),
    icon       = coalesce(p_icon, s.icon),
    sort_order = coalesce(p_sort_order, s.sort_order),
    is_active  = coalesce(p_is_active, s.is_active),
    updated_by = auth.uid(),
    updated_at = now()
   where s.id = p_id
  returning s.id into v_id;

  if v_id is null then
    raise exception 'No such figure' using errcode = 'P0002';
  end if;
  return v_id;
end;
$$;

-- `0165`'s event trigger strips grants from anything recreated in
-- `public` or `app`, so both are re-granted here.
revoke all on function public.platform_save_landing_testimonial(
  uuid, text, text, text, text, integer, boolean) from public;
revoke all on function public.platform_save_landing_stat(
  uuid, text, text, text, integer, boolean) from public;
revoke all on function app.is_placeholder_copy(text) from public;

grant execute on function public.platform_save_landing_testimonial(
  uuid, text, text, text, text, integer, boolean) to authenticated;
grant execute on function public.platform_save_landing_stat(
  uuid, text, text, text, integer, boolean) to authenticated;
grant execute on function app.is_placeholder_copy(text) to authenticated;
