-- The mark it ships with.
--
-- `logo_url` shipped null, and null draws `_FallbackMark` — a shape
-- built out of two rectangles in Dart. That was the right answer for a
-- platform nobody had branded yet, and it stopped being right the day
-- somebody uploaded a logo: the file has been sitting in
-- `logos/landing/logo` since 24 August, and the column that points at
-- it was never saved. So the console had the mark and every screen drew
-- the drawn one.
--
-- The address is the public storage URL for that object, with the cache
-- key it was given. Public because the bucket is — `logos_read` is
-- `using (bucket_id = 'logos')` with no further test, which it has to
-- be: the mark at the top of the landing page is read by people who are
-- not signed in.
--
-- ## The drawn mark stays, and is no longer the default
--
-- `_FallbackMark` is still what `LandingMark` shows when the address
-- will not load, which is the case it was written for. What changes is
-- that it is a fallback rather than the thing a platform gets for not
-- having chosen. Same shape as `0321` and the hero picture: a default
-- that is a real asset, and a drawn stand-in for when the network
-- disagrees.
--
-- Nothing here is a lock. Clearing the field in the console puts the
-- built-in address back, exactly as every other defaulted column on
-- this table behaves, and uploading a logo replaces it.

alter table public.landing_page
  alter column logo_url set default
    'https://ewwcgtnniwqndrzukksm.supabase.co/storage/v1/object/public/'
    'logos/landing/logo?v=1787561059459';

update public.landing_page p
   set logo_url =
    'https://ewwcgtnniwqndrzukksm.supabase.co/storage/v1/object/public/'
    'logos/landing/logo?v=1787561059459'
 where p.id and p.logo_url is null;
