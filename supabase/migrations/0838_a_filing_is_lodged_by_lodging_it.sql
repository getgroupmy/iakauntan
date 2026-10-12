-- =====================================================================
-- iAkauntan :: 0838 a filing is lodged by lodging it
--
-- A set of accounts for SSM (`fs_filings`) moves through draft, frozen
-- and lodged by its functions: `fs_freeze` snapshots the statements and
-- stamps `frozen_at`; `fs_unfreeze` refuses a lodged filing -- "cannot
-- be reopened. A correction is a fresh set, not an edit to this one";
-- `fs_lodge` asks for a frozen filing, the MBRS reference and a recorded
-- circulation. `fs_refuse_lodged_edit` keeps a lodged filing's figures,
-- but not its status, and the policy lets a client write every column.
--
-- Measured on 12 October 2026, locally, as the owner with the role
-- `authenticated`: a draft filing set to lodged by hand was accepted --
-- never frozen, nothing snapshotted, no circulation behind it. A lodged
-- filing set back to draft by hand was accepted, its audit opinion
-- rewritten from unmodified to qualified, and lodged again: the record
-- of what went to SSM now says what did not.
--
-- Answered "guard the workflow columns": a trigger refuses a client's
-- own statement -- role `authenticated` or `anon`, at the top trigger
-- depth -- that changes `status`, `frozen_at` or `frozen_by`, or that
-- makes a filing other than as a draft. The three functions are
-- definers and pass. NOT security definer. `lodged_on` and
-- `mbrs_reference` stay open, as the filing screen's own comment
-- intends: "a typo in what mPortal returned is a typo and not a
-- restatement". What the screen edits is as before.
--
-- Production held seven filings on 12 October, every one in a
-- demonstration company.
-- =====================================================================

create or replace function app.a_filing_is_lodged_by_lodging_it()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  c_workflow constant text[] := array['status', 'frozen_at', 'frozen_by'];
  v_new jsonb;
  v_old jsonb;
  v_col text;
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.status <> 'draft' or new.frozen_at is not null
       or new.frozen_by is not null then
      raise exception
        'A set of accounts starts as a draft. It is frozen by freezing it '
        'and lodged by recording the lodgement.'
        using errcode = '42501';
    end if;
    return new;
  end if;

  v_new := to_jsonb(new);
  v_old := to_jsonb(old);
  foreach v_col in array c_workflow loop
    if v_new -> v_col is distinct from v_old -> v_col then
      raise exception
        'The % of these accounts moves when they are frozen, unfrozen or '
        'lodged, not by hand.',
        v_col
        using errcode = '42501';
    end if;
  end loop;
  return new;
end $$;

revoke all on function app.a_filing_is_lodged_by_lodging_it()
  from public, anon, authenticated;

comment on function app.a_filing_is_lodged_by_lodging_it() is
  'On fs_filings: refuses a client''s own statement that changes status, '
  'frozen_at or frozen_by, or makes a filing other than as a draft. '
  'fs_freeze, fs_unfreeze and fs_lodge pass. 0838.';

create trigger a_filing_is_lodged_by_lodging_it
  before insert or update on public.fs_filings
  for each row execute function app.a_filing_is_lodged_by_lodging_it();
