-- =====================================================================
-- 0757 :: a conversation with yourself is refused in any company
--
-- Answered on 7 October: "refuse it plainly".
--
-- `chat_start_direct` (0135) refused a conversation with yourself only
-- when both sides named the same company. Somebody who belongs to two
-- linked companies could pick themselves under the other one: the check
-- let it through, and the insert then failed on `chat_participants`'
-- primary key -- a conversation holds a person once -- with a raw
-- "duplicate key" error instead of a sentence. Nothing was created and
-- nothing leaked; the person was shown something nobody could read.
--
-- Now yourself is yourself in any company, refused with the sentence
-- that was already there. Nothing else changes.
-- =====================================================================

create or replace function public.chat_start_direct(
  p_my_org uuid, p_other_user uuid, p_other_org uuid)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_me uuid := auth.uid();
  v_id uuid;
begin
  if v_me is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;
  -- Whatever company either side is named under: a conversation holds a
  -- person once (`chat_participants` is keyed on the pair), so yourself
  -- under your other company is still yourself. 0757.
  if v_me = p_other_user then
    raise exception 'You cannot start a conversation with yourself'
      using errcode = '22023';
  end if;
  if not app.chat_enabled(p_my_org, v_me) then
    raise exception 'Chat is not switched on for you in this company'
      using errcode = '42501';
  end if;
  if not app.chat_enabled(p_other_org, p_other_user) then
    raise exception 'Chat is not switched on for that person'
      using errcode = '42501';
  end if;
  if not app.chat_orgs_linked(p_my_org, p_other_org) then
    raise exception 'These companies are not linked for chat'
      using errcode = '42501';
  end if;

  -- Exactly these two people, and no third.
  select c.id into v_id
    from public.chat_conversations c
   where c.is_direct
     and exists (select 1 from public.chat_participants p
                  where p.conversation_id = c.id and p.user_id = v_me
                    and p.org_id = p_my_org)
     and exists (select 1 from public.chat_participants p
                  where p.conversation_id = c.id and p.user_id = p_other_user
                    and p.org_id = p_other_org)
     and (select count(*) from public.chat_participants p
           where p.conversation_id = c.id) = 2
   limit 1;
  if v_id is not null then
    return v_id;
  end if;

  insert into public.chat_conversations (is_direct, created_by)
  values (true, v_me) returning id into v_id;

  insert into public.chat_participants (conversation_id, user_id, org_id)
  values (v_id, v_me, p_my_org), (v_id, p_other_user, p_other_org);

  return v_id;
end; $$;
