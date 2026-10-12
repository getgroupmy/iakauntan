-- =====================================================================
-- iAkauntan :: 0826 a company is billed as the platform says
--
-- `app.bill_the_month` raises each company's module subscription for the
-- month just ended, and bills only a company whose `status` is active
-- and that is not `is_demo`. The platform console sets them through `platform_set_org_status` and its
-- siblings, the demo rebuild through its own functions; `firm_id` and
-- `firm_member_role` are set by `attach_company_to_firm`,
-- `detach_company_from_firm` and `hand_company_over`, which is how an
-- accounting firm consents to taking a company on. All of them are
-- definers. But `organizations_update` lets a company's admin write any
-- column -- the settings screen writes the row directly, which is what
-- it is for.
--
-- Measured on 11 October 2026, locally, as the owner with the role
-- `authenticated`: two companies holding the multi-company module the
-- whole of January. One set itself `is_demo`, the other `status`
-- 'trial' with a trial to 2046 -- both accepted -- and the run on 1
-- February billed neither. It was the status that did it. The stored
-- end of a trial is read by nothing since `0548`, which works a trial
-- out from the promotion, and `check_orphan_columns.py` lists that
-- column to be dropped -- so it is not guarded here, and a guard on a
-- column nothing reads would only be one more thing that reached it.
--
-- Answered "guard the platform columns". A trigger refuses a client's
-- own statement -- role `authenticated` or `anon`, at the top trigger
-- depth -- that changes `status`, `is_demo`, `firm_id` or
-- `firm_member_role`, or that creates a company with any
-- of them other than as new. The functions run as their owner and pass.
-- NOT security definer. Everything else the settings screen writes is
-- as before.
--
-- Production held six companies and thirteen demonstration ones, every
-- one active, on 11 October.
-- =====================================================================

create or replace function app.a_company_is_billed_as_the_platform_says()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  c_platform constant text[] := array[
    'status', 'is_demo', 'firm_id', 'firm_member_role'];
  v_old jsonb;
  v_new jsonb;
  v_col text;
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.status is distinct from 'active'
       or new.is_demo
       or new.firm_id is not null
       or new.firm_member_role is distinct from 'accountant' then
      raise exception
        'A company starts active, not a demonstration and with no '
        'accounting firm; the platform and the firm set those.'
        using errcode = '42501';
    end if;
    return new;
  end if;

  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  foreach v_col in array c_platform loop
    if v_new -> v_col is distinct from v_old -> v_col then
      raise exception
        '% of % is the platform''s to set, or the accounting firm''s by '
        'taking the company on -- not the company''s own.',
        v_col, old.name
        using errcode = '42501';
    end if;
  end loop;

  return new;
end $$;

revoke all on function app.a_company_is_billed_as_the_platform_says() from public, anon, authenticated;

comment on function app.a_company_is_billed_as_the_platform_says() is
  'On organizations: refuses a client''s own statement that writes '
  'status, is_demo, firm_id or firm_member_role, or '
  'creates a company with any of them other than as new. The platform, '
  'firm and demo functions pass. 0826.';

create trigger a_company_is_billed_as_the_platform_says
  before insert or update on public.organizations
  for each row execute function app.a_company_is_billed_as_the_platform_says();
