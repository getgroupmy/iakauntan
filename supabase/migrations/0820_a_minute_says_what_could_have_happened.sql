-- =====================================================================
-- iAkauntan :: 0820 a minute says what could have happened
--
-- `corp_resolutions` is a company's minute book: board and members'
-- resolutions, when they were passed and took effect, who was present
-- and how they voted, and whether the minute is signed. The resolution
-- screen refuses four things before it saves -- a written resolution
-- (circulated under s.297 of the Companies Act 2016) recorded as passed
-- at a meeting; one that takes effect before it was passed; one marked
-- signed with no date it was signed; and more votes than people
-- present -- and `resolution_sheet.dart` says of the last, "Nothing in
-- the database checks it". Nothing did, for any of them: the table had
-- no check at all, and took negative votes too.
--
-- Measured on 11 October 2026, locally: every one of the five written
-- straight into the table and accepted.
--
-- Answered "check constraints". Five, named for what they keep, each
-- with its sentence as a comment. The screen still refuses first, in
-- its own words; these are for every other way in. A resolution
-- minuted without a count, or without the people present, is still
-- ordinary and still accepted.
--
-- Production held no resolution on 11 October.
-- =====================================================================

alter table public.corp_resolutions
  add constraint corp_resolutions_written_not_at_meeting_ck
    check (not (kind = 'written' and meeting_held)),
  add constraint corp_resolutions_effective_after_passed_ck
    check (effective_on is null or passed_on is null or effective_on >= passed_on),
  add constraint corp_resolutions_signed_is_dated_ck
    check (not is_signed or signed_on is not null),
  add constraint corp_resolutions_votes_not_negative_ck
    check (coalesce(in_favour, 0) >= 0 and coalesce(against, 0) >= 0
           and coalesce(abstained, 0) >= 0),
  add constraint corp_resolutions_votes_fit_the_present_ck
    check (cardinality(coalesce(present_person_ids, '{}'::uuid[])) = 0
           or coalesce(in_favour, 0) + coalesce(against, 0)
              + coalesce(abstained, 0) <= cardinality(present_person_ids));

comment on constraint corp_resolutions_written_not_at_meeting_ck on public.corp_resolutions is
  'A written resolution is circulated under s.297 rather than passed at a meeting. 0820.';
comment on constraint corp_resolutions_effective_after_passed_ck on public.corp_resolutions is
  'A resolution cannot take effect before it was passed. 0820.';
comment on constraint corp_resolutions_signed_is_dated_ck on public.corp_resolutions is
  'A signed minute says when it was signed. 0820.';
comment on constraint corp_resolutions_votes_not_negative_ck on public.corp_resolutions is
  'Nobody casts fewer than no votes. 0820.';
comment on constraint corp_resolutions_votes_fit_the_present_ck on public.corp_resolutions is
  'For, against and abstained together cannot exceed those present. 0820.';
