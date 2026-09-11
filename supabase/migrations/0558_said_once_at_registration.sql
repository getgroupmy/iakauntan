-- =====================================================================
-- iAkauntan :: 0558 said once, at registration
--
-- Setup asks "what is this for -- myself, or a business" as its first
-- step, and it is the right question. It is asked in the wrong place:
-- registration already collects a name, a title, a number, a country
-- and a state, and then hands somebody to a screen whose first act is
-- to ask one more thing before they can begin.
--
-- So it is asked on the registration form, kept on the profile, and
-- setup starts from the answer instead of asking for it.
--
-- ---------------------------------------------------------------------
-- Two values, and the check says so
--
-- `personal` or `business`. A `text` column with a check constraint
-- rather than an enum, for the reason `business_type` is a text column
-- too: this is a question the product asks a person, not a type the
-- ledger depends on, and a third answer -- if there ever is one --
-- should be a migration that alters a constraint rather than one that
-- rewrites an enum every dependent view mentions.
--
-- Null is the third state and it is not an answer: it is every account
-- that registered before this, and every one created by an invitation.
-- Setup still asks those people, exactly as it does today.
--
-- ---------------------------------------------------------------------
-- Whose answer this is
--
-- The PERSON's, not the company's. `organizations.entity_type` already
-- records what a set of books belongs to -- `individual` for somebody
-- invoicing under their own name -- and that stays the statutory
-- answer, the one `0553`'s trigger reads to file them under NRIC. This
-- column is what they said when they signed up, which is what setup
-- uses to decide which questions to ask them next.
--
-- They can disagree, and that is allowed: an accountant registers for
-- themselves and later opens books for a client company. The profile
-- says what that person is here for; each set of books says what it is.
-- =====================================================================

alter table public.profiles
  add column if not exists use_kind text;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'profiles_use_kind_known') then
    alter table public.profiles
      add constraint profiles_use_kind_known
      check (use_kind is null or use_kind in ('personal', 'business'));
  end if;
end $$;

comment on column public.profiles.use_kind is
  'What somebody said they were here for at registration: personal or '
  'business. Null for an account that registered before the question '
  'existed. The person''s answer, not a company''s entity type. 0558.';

-- ---------------------------------------------------------------------
-- Carried with the rest
--
-- Restated from the built definition again, as `0555` restated `0554`'s
-- and `0554` restated `0001`'s. This function also claims pending
-- invitations, and rebuilding it from anything but what is running
-- would drop that.
-- ---------------------------------------------------------------------
create or replace function app.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, email, full_name, avatar_url,
                               salutation, phone, country_code, state_code,
                               use_kind)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name',
             new.raw_user_meta_data ->> 'name'),
    new.raw_user_meta_data ->> 'avatar_url',
    nullif(trim(coalesce(new.raw_user_meta_data ->> 'salutation', '')), ''),
    -- The form sends the two halves and the database puts them
    -- together, so the trunk-prefix zero is dropped by the same rule
    -- whoever is registering somebody.
    app.phone_e164(new.raw_user_meta_data ->> 'phone_dial',
                   new.raw_user_meta_data ->> 'phone_national'),
    nullif(trim(coalesce(new.raw_user_meta_data ->> 'country_code', '')), ''),
    nullif(trim(coalesce(new.raw_user_meta_data ->> 'state_code', '')), ''),
    -- Anything that is not one of the two answers is no answer at all.
    -- The constraint would refuse it and take the whole registration
    -- with it, and a sign-up that fails because a client sent a word
    -- nobody recognises is a worse outcome than a question asked twice.
    case
      when new.raw_user_meta_data ->> 'use_kind' in ('personal', 'business')
        then new.raw_user_meta_data ->> 'use_kind'
      else null
    end
  )
  on conflict (id) do nothing;

  -- Claim any pending invitations addressed to this e-mail -- but only
  -- ones still in date. accept_invitation has always refused an expired
  -- invitation; this path used to take it anyway. A null expiry is
  -- honoured for rows raised before invite_member set one.
  update public.org_members
     set user_id  = new.id,
         status   = 'active',
         joined_at = now(),
         invite_token = null
   where invited_email = new.email
     and user_id is null
     and status = 'invited'
     and (invite_expires_at is null or invite_expires_at > now());

  return new;
end $$;
