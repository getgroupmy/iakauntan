-- =====================================================================
-- iAkauntan :: 0835 a class of shares stays with its company
--
-- `0833` refuses a share movement in another company's class of shares.
-- The same register can be made to disagree from the class's side:
-- `0067`'s `corp_share_classes_write` lets a client update any column of
-- a class, `entity_id` among them, and `corp_issued_capital` counts a
-- class's allotments under whichever company the class names now while
-- `corp_register_of_members` reads the movements under the company they
-- were recorded in.
--
-- Measured on 12 October 2026, locally, as the owner with the role
-- `authenticated`: Saham's Ordinary class with 100 allotted to A, moved
-- to Lain by an update, was accepted. Saham's register still showed A
-- with 100 and its issued capital nothing; Lain's issued capital showed
-- 100 and its register nobody.
--
-- Answered "fix a class's company": a trigger refuses any change to a
-- class's `entity_id`, from any writer. A class is created for one
-- company and stays there; a class entered under the wrong company is
-- replaced by a new one under the right one. Its code, name, currency,
-- votes, redeemability and rights are as editable as before, and the
-- share class sheet, which sends the class's own `entity_id` back when
-- it amends one, is unaffected. `org_id` needs nothing of its own:
-- `corp_share_classes_entity_same_org` (`0519`) ties it to the company,
-- so it cannot move without `entity_id` moving too.
--
-- No function moves a class, and production held no class under another
-- company on 12 October.
-- =====================================================================

create or replace function app.a_share_class_stays_with_its_company()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  if NEW.entity_id is distinct from OLD.entity_id then
    raise exception
      'Class % stays with the company it was created for. A class of '
      'shares for another company is a new class there.',
      OLD.code using errcode = '23514';
  end if;
  return NEW;
end $$;

revoke all on function app.a_share_class_stays_with_its_company()
  from public, anon, authenticated;

comment on function app.a_share_class_stays_with_its_company() is
  'On corp_share_classes: refuses any change to the company a class of '
  'shares belongs to. 0835.';

create trigger a_share_class_stays_with_its_company
  before update on public.corp_share_classes
  for each row execute function app.a_share_class_stays_with_its_company();
