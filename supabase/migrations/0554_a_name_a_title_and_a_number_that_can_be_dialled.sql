-- =====================================================================
-- iAkauntan :: 0554 a name, a title, and a number that can be dialled
--
-- Registration asks for a full name, an e-mail and a password, and
-- that is the whole of what this product knows about a person. Two
-- things were asked for: how to address them, and how to ring them.
--
-- ---------------------------------------------------------------------
-- The zero that is not part of the number
--
-- Somebody in Malaysia writes their mobile 012-345 6789. The leading
-- zero is a trunk prefix -- it means "a call inside this country" --
-- and it is not part of the number. With a country code in front, the
-- number is +60 12 345 6789 and the zero is gone. Keep it and you have
-- +600123456789, which is not a number, and nothing says so: the field
-- accepts it, the profile stores it, and a message one day is not
-- delivered.
--
-- The same holds across most of the world, and the countries that do
-- not use a trunk prefix (Italy among them) do not write the zero in
-- the first place, so removing it takes nothing away.
--
-- `app.phone_e164` does the removing, and it does it HERE rather than
-- only in the form. The rule is arithmetic on somebody's phone number
-- and the failure is silent, which is exactly the kind of rule this
-- project keeps in the database: a form is one caller, and the next
-- caller -- an import, an invitation, the console -- would have to
-- remember.
--
-- Every leading zero rather than one. `0012345678` is somebody who
-- typed it twice, and one zero left in front is the same wrong number.
--
-- ---------------------------------------------------------------------
-- How to address somebody
--
-- `salutations` is a table for the same reason `business_types` is one:
-- it is a list that grows, and growing it should not need a release. It
-- is deliberately long. "Mr / Mrs / Miss" is an English-speaking
-- office's list, and this product is used in a country where a letter
-- addressed to a Dato' Sri as "Mr" is an insult -- and by people whose
-- own title is Ir, Ar, Haji, Tengku, Ustaz or Pehin.
--
-- The federal and state honours are all here (Tun, Tan Sri, Datuk
-- Seri, Dato', Datin ...), with the female forms beside them rather
-- than derived, because Toh Puan and Puan Sri are their own titles and
-- not "the wife version" of anything a rule could compute.
--
-- ---------------------------------------------------------------------
-- Read before there is anybody to read it
--
-- The registration form is the one screen in this product with no
-- session behind it, so neither list can be reached by an RLS policy
-- granted to `authenticated`. The pattern this repository already uses
-- for that is a SECURITY DEFINER function granted to `anon` --
-- `landing_page()`, `may_sign_in_here()` -- rather than opening a table
-- to the anonymous role, and `signup_reference()` follows it. The
-- tables stay closed; one function hands out two lists of public facts.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The number
-- ---------------------------------------------------------------------
create or replace function app.phone_e164(p_dial text, p_national text)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_dial     text;
  v_national text;
begin
  -- Everything that is not a digit is decoration: spaces, dashes,
  -- brackets, the plus itself.
  v_dial     := regexp_replace(coalesce(p_dial, ''), '[^0-9]', '', 'g');
  v_national := regexp_replace(coalesce(p_national, ''), '[^0-9]', '', 'g');

  -- The trunk prefix.
  v_national := ltrim(v_national, '0');

  -- A number with no country, or a country with no number, is not a
  -- phone number. Null rather than a shape.
  if v_dial = '' or v_national = '' then
    return null;
  end if;

  -- E.164 allows fifteen digits including the country code. Longer
  -- than that is a typo, and storing it would be storing something
  -- nothing can dial.
  if length(v_dial) + length(v_national) > 15 then
    return null;
  end if;

  return '+' || v_dial || v_national;
end $$;

comment on function app.phone_e164(text, text) is
  'A dialling code and a number as E.164, with the trunk-prefix zero '
  'removed. Null when there is nothing dialable. 0554.';

-- ---------------------------------------------------------------------
-- The title
-- ---------------------------------------------------------------------
create table if not exists public.salutations (
  code       text primary key,
  name       text not null,
  grouping   text not null,
  note       text,
  sort_order integer not null default 500,
  is_active  boolean not null default true
);

comment on table public.salutations is
  'How to address somebody, offered at registration and on a profile. '
  'Long on purpose: a letter addressed to a Dato'' Sri as "Mr" is an '
  'insult. 0554.';

alter table public.salutations enable row level security;

drop policy if exists salutations_read on public.salutations;
create policy salutations_read on public.salutations
  for select to authenticated using (true);

revoke all on table public.salutations from public, anon;
grant select on table public.salutations to authenticated;

insert into public.salutations (code, name, grouping, note, sort_order)
values
  -- The everyday ones
  ('mr',     'Mr',     'Common', null, 10),
  ('mrs',    'Mrs',    'Common', null, 11),
  ('ms',     'Ms',     'Common', null, 12),
  ('miss',   'Miss',   'Common', null, 13),
  ('mx',     'Mx',     'Common', 'Gender neutral', 14),
  ('dr',     'Dr',     'Common', null, 15),
  ('prof',   'Prof',   'Common', null, 16),
  ('profdr', 'Prof Dr', 'Common', null, 17),
  ('emeritus', 'Prof Emeritus', 'Common', null, 18),

  -- Malay forms of address
  ('tuan',   'Tuan',   'Malay', 'Sir', 30),
  ('puan',   'Puan',   'Malay', 'Madam', 31),
  ('encik',  'Encik',  'Malay', 'Mr', 32),
  ('cik',    'Cik',    'Malay', 'Miss', 33),
  ('bapak',  'Bapak',  'Malay', 'Indonesia', 34),
  ('ibu',    'Ibu',    'Malay', 'Indonesia', 35),
  ('awang',  'Awang',  'Malay', 'Brunei and Sarawak', 36),
  ('dayang', 'Dayang', 'Malay', 'Brunei and Sarawak', 37),

  -- Federal and state honours
  ('tun',        'Tun',        'Malaysian honours', 'Federal', 50),
  ('tohpuan',    'Toh Puan',   'Malaysian honours', 'Wife of a Tun', 51),
  ('tansri',     'Tan Sri',    'Malaysian honours', 'Federal', 52),
  ('puansri',    'Puan Sri',   'Malaysian honours', 'Wife of a Tan Sri', 53),
  ('datukseri',  'Datuk Seri', 'Malaysian honours', null, 54),
  ('datoseri',   'Dato'' Seri', 'Malaysian honours', null, 55),
  ('datosri',    'Dato'' Sri',  'Malaysian honours', null, 56),
  ('datinseri',  'Datin Seri', 'Malaysian honours', null, 57),
  ('datinsri',   'Datin Sri',  'Malaysian honours', null, 58),
  ('datukpaduka', 'Datuk Paduka', 'Malaysian honours', null, 59),
  ('datukwira',  'Datuk Wira', 'Malaysian honours', null, 60),
  ('datowira',   'Dato'' Wira', 'Malaysian honours', null, 61),
  ('datukamar',  'Datuk Amar', 'Malaysian honours', 'Sarawak', 62),
  ('datukpatinggi', 'Datuk Patinggi', 'Malaysian honours', 'Sarawak', 63),
  ('datukpanglima', 'Datuk Seri Panglima', 'Malaysian honours', 'Sabah', 64),
  ('datuk',      'Datuk',      'Malaysian honours', null, 65),
  ('dato',       'Dato''',     'Malaysian honours', null, 66),
  ('datin',      'Datin',      'Malaysian honours', null, 67),
  ('pehin',      'Pehin',      'Malaysian honours', 'Brunei', 68),

  -- Royalty
  ('duli',    'Duli Yang Maha Mulia', 'Royal', 'DYMM', 80),
  ('kdymm',   'Kebawah Duli Yang Maha Mulia', 'Royal', 'Brunei', 81),
  ('tuanku',  'Tuanku',  'Royal', null, 82),
  ('sultan',  'Sultan',  'Royal', null, 83),
  ('sultanah', 'Sultanah', 'Royal', null, 84),
  ('raja',    'Raja',    'Royal', null, 85),
  ('tengku',  'Tengku',  'Royal', null, 86),
  ('tunku',   'Tunku',   'Royal', null, 87),
  ('ungku',   'Ungku',   'Royal', null, 88),
  ('megat',   'Megat',   'Royal', null, 89),
  ('nik',     'Nik',     'Royal', null, 90),
  ('wan',     'Wan',     'Royal', null, 91),
  ('yab',     'Yang Amat Berhormat', 'Royal', 'YAB', 92),
  ('yb',      'Yang Berhormat', 'Royal', 'YB', 93),
  ('ybhg',    'Yang Berbahagia', 'Royal', 'YBhg', 94),

  -- Professional
  ('ir',      'Ir',      'Professional', 'Engineer', 110),
  ('ar',      'Ar',      'Professional', 'Architect', 111),
  ('sr',      'Sr',      'Professional', 'Surveyor', 112),
  ('ts',      'Ts',      'Professional', 'Technologist', 113),
  ('cadv',    'Advocate', 'Professional', null, 114),
  ('justice', 'Justice', 'Professional', null, 115),
  ('judge',   'Judge',   'Professional', null, 116),

  -- Religious
  ('haji',    'Haji',    'Religious', null, 130),
  ('hajjah',  'Hajjah',  'Religious', null, 131),
  ('ustaz',   'Ustaz',   'Religious', null, 132),
  ('ustazah', 'Ustazah', 'Religious', null, 133),
  ('syed',    'Syed',    'Religious', null, 134),
  ('sharifah', 'Sharifah', 'Religious', null, 135),
  ('sheikh',  'Sheikh',  'Religious', null, 136),
  ('rev',     'Rev',     'Religious', null, 137),
  ('pastor',  'Pastor',  'Religious', null, 138),
  ('fr',      'Fr',      'Religious', 'Father', 139),
  ('sister',  'Sr (Sister)', 'Religious', null, 140),
  ('rabbi',   'Rabbi',   'Religious', null, 141),
  ('imam',    'Imam',    'Religious', null, 142),
  ('swami',   'Swami',   'Religious', null, 143),
  ('venerable', 'Venerable', 'Religious', 'Buddhist clergy', 144),

  -- Military and police
  ('capt',    'Capt',    'Uniformed', null, 160),
  ('maj',     'Maj',     'Uniformed', null, 161),
  ('ltcol',   'Lt Col',  'Uniformed', null, 162),
  ('col',     'Col',     'Uniformed', null, 163),
  ('brig',    'Brig Gen', 'Uniformed', null, 164),
  ('gen',     'Gen',     'Uniformed', null, 165),
  ('adm',     'Adm',     'Uniformed', null, 166),
  ('cdr',     'Cdr',     'Uniformed', null, 167),
  ('lt',      'Lt',      'Uniformed', null, 168),
  ('sgt',     'Sgt',     'Uniformed', null, 169),
  ('insp',    'Insp',    'Uniformed', null, 170),
  ('dsp',     'DSP',     'Uniformed', null, 171),
  ('acp',     'ACP',     'Uniformed', null, 172),

  -- Elsewhere in the world
  ('sir',     'Sir',     'Around the world', 'United Kingdom', 200),
  ('dame',    'Dame',    'Around the world', 'United Kingdom', 201),
  ('lord',    'Lord',    'Around the world', 'United Kingdom', 202),
  ('lady',    'Lady',    'Around the world', 'United Kingdom', 203),
  ('herr',    'Herr',    'Around the world', 'German', 204),
  ('frau',    'Frau',    'Around the world', 'German', 205),
  ('monsieur', 'Monsieur', 'Around the world', 'French', 206),
  ('madame',  'Madame',  'Around the world', 'French', 207),
  ('mlle',    'Mademoiselle', 'Around the world', 'French', 208),
  ('senor',   'Señor',   'Around the world', 'Spanish', 209),
  ('senora',  'Señora',  'Around the world', 'Spanish', 210),
  ('senorita', 'Señorita', 'Around the world', 'Spanish', 211),
  ('signore', 'Signore', 'Around the world', 'Italian', 212),
  ('signora', 'Signora', 'Around the world', 'Italian', 213),
  ('senhor',  'Senhor',  'Around the world', 'Portuguese', 214),
  ('senhora', 'Senhora', 'Around the world', 'Portuguese', 215),
  ('meneer',  'Meneer',  'Around the world', 'Dutch', 216),
  ('mevrouw', 'Mevrouw', 'Around the world', 'Dutch', 217),
  ('pan',     'Pan',     'Around the world', 'Polish', 218),
  ('pani',    'Pani',    'Around the world', 'Polish', 219),
  ('khun',    'Khun',    'Around the world', 'Thai', 220),
  ('shri',    'Shri',    'Around the world', 'Indian', 221),
  ('smt',     'Smt',     'Around the world', 'Indian', 222),
  ('kumari',  'Kumari',  'Around the world', 'Indian', 223),
  ('thiru',   'Thiru',   'Around the world', 'Tamil', 224),
  ('thirumathi', 'Thirumathi', 'Around the world', 'Tamil', 225),
  ('sardar',  'Sardar',  'Around the world', 'Sikh', 226),
  ('sardarni', 'Sardarni', 'Around the world', 'Sikh', 227)
on conflict (code) do update
  set name       = excluded.name,
      grouping   = excluded.grouping,
      note       = excluded.note,
      sort_order = excluded.sort_order,
      is_active  = true;

-- What a profile is addressed as. The words rather than the code: a
-- title is a label, it goes on a letter, and a screen that had to join
-- to print "Dato'" would be a join on every letter.
alter table public.profiles
  add column if not exists salutation text;

comment on column public.profiles.salutation is
  'How to address this person, from public.salutations. 0554.';

-- ---------------------------------------------------------------------
-- The two lists, before there is a session
-- ---------------------------------------------------------------------
create or replace function public.signup_reference()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'dial_codes', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', c.code, 'name', c.name,
               'alpha2', c.alpha2, 'dial_code', c.dial_code)
             order by c.name), '[]'::jsonb)
        from public.ref_countries c
       where c.is_active
         and coalesce(c.dial_code, '') <> ''),
    'salutations', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', s.code, 'name', s.name,
               'grouping', s.grouping, 'note', s.note)
             order by s.sort_order, s.name), '[]'::jsonb)
        from public.salutations s
       where s.is_active));
$$;

comment on function public.signup_reference() is
  'The dialling codes and salutations the registration form offers, '
  'readable with no session because that form has none. 0554.';

revoke all on function public.signup_reference() from public;
grant execute on function public.signup_reference() to anon, authenticated;

-- ---------------------------------------------------------------------
-- Carrying both onto the profile
--
-- Restated from the built definition rather than from `0001`: this
-- function has been rewritten since, to honour an invitation's expiry,
-- and rebuilding it from the original would silently take that out.
-- ---------------------------------------------------------------------
create or replace function app.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, email, full_name, avatar_url,
                               salutation, phone)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name',
             new.raw_user_meta_data ->> 'name'),
    new.raw_user_meta_data ->> 'avatar_url',
    nullif(trim(coalesce(new.raw_user_meta_data ->> 'salutation', '')), ''),
    -- The form sends the two halves and the database puts them
    -- together, so the trunk-prefix zero is dropped by the same rule
    -- whoever is calling.
    app.phone_e164(new.raw_user_meta_data ->> 'phone_dial',
                   new.raw_user_meta_data ->> 'phone_national')
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
