-- The icon in the tab.
--
-- `0325` gave `logo_url` the mark that had been sitting unreferenced in
-- storage since August. `app_icon_url` was in exactly the same state
-- and left alone, because nobody had asked: the object is at
-- `logos/landing/app-icon`, the column pointing at it was null, and
-- `applyFavicon` returns early on null — so the browser tab kept the
-- static icon in `web/index.html` and the uploaded one was never used.
--
-- Same shape as `0325`. The address is the public storage URL, with the
-- cache key taken from the object's own `updated_at` rather than
-- invented, so it names the bytes that are actually there.
--
-- ## It is a different column from the logo on purpose
--
-- They happen to be the same image today — both 32,003 bytes — and they
-- are not the same job. A mark on a landing page is read at 36 pixels
-- beside a wordmark; a favicon is read at 16 in a row of other tabs,
-- and the version that survives that is usually cropped tighter and
-- carries no wordmark at all. Defaulting them to the same file is the
-- right starting point and the wrong thing to enforce, so they stay two
-- columns that can drift apart the moment somebody uploads a proper
-- one.
--
-- Clearing the field in the console puts this address back, and the
-- static icon in the web bundle remains the last resort — `0325`'s
-- reasoning about `_FallbackMark`, one layer further out.

alter table public.landing_page
  alter column app_icon_url set default
    'https://ewwcgtnniwqndrzukksm.supabase.co/storage/v1/object/public/'
    'logos/landing/app-icon?v=1787675276405';

update public.landing_page p
   set app_icon_url =
    'https://ewwcgtnniwqndrzukksm.supabase.co/storage/v1/object/public/'
    'logos/landing/app-icon?v=1787675276405'
 where p.id and p.app_icon_url is null;
