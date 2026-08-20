-- ---------------------------------------------------------------------
-- 0236  The tables nobody was watching
-- ---------------------------------------------------------------------
--
-- 0055 put an audit trigger on thirteen tables and said, correctly, that
-- an audit trail nobody reads because it is mostly invoice lines is the
-- same as no audit trail. Later migrations took it to twenty-five --
-- counted on production, not assumed -- and every one of the twenty-five
-- is standing data: salaries, bank accounts, the chart of accounts, the
-- statutory registers, who is a member, which SLA applies. Not one of
-- them is money.
--
-- Measured before this migration: `sales_documents`, `purchase_documents`,
-- `receipts`, `purchase_payments`, `expenses`, `expense_claims`,
-- `fixed_assets`, `payroll_runs`, `contacts`, `items`, `pos_sales`,
-- `gl_entries` and `gl_lines` each had **zero** audit triggers. An
-- invoice could have its amount changed, a supplier's bank details could
-- be swapped the day before a payment run, and a posted journal could be
-- deleted outright, and the only record of any of it was the row itself
-- afterwards.
--
-- ## What is added, and what is deliberately not
--
-- Headers and money, not lines. An invoice's total is on the invoice; a
-- trail of every line edit while somebody types one is the failure 0055
-- named. The line tables stay out.
--
-- `pos_sales` is the exception that proves the rule and is scoped by
-- column. A till writes to that row several times per sale as items go
-- on, and a per-keystroke trail of a busy warung would bury everything
-- else. What is worth keeping is what happened to a bill *after* it was
-- a bill: voided, reassigned to a different customer, or attached to a
-- different loyalty card. So the trigger fires on those columns and on
-- delete, and not on insert -- the sale itself is already a row, and its
-- invoice and receipt are audited in full.
--
-- ## The ledger is not append-only, and this records that it is not
--
-- `gl_entries` and `gl_lines` carry `for update` and `for delete`
-- policies whose whole condition is `app.can_post(org_id)`. Anybody who
-- may post may also edit or delete a journal that has already been
-- posted, straight through the API. No screen offers it -- the Flutter
-- client only ever selects from those two tables -- but the policy is
-- what decides, not the screen.
--
-- Closing that is a change to what the product allows and belongs to
-- whoever owns that decision, so this migration does not make it. What
-- it does is make the tampering visible: update and delete on both
-- tables are audited from here, insert is not, because an insert *is*
-- the ledger and auditing it would store the books twice.
--
-- ## Secrets never reach the trail
--
-- `einvoice_credentials` holds `client_secret` and
-- `cert_private_key_pem`. Recording that a company's LHDN credentials
-- changed is worth having; recording what they changed *to*, in a table
-- every admin can read, would be handing them out. `audit_diff` now
-- redacts a value whose column name looks like a secret, so the change
-- is recorded and the secret is not -- for the thirteen older tables as
-- well.

-- ---------------------------------------------------------------------
-- Redact, then diff
-- ---------------------------------------------------------------------
-- One list, in one place. The first version of this migration put the
-- redaction inside `audit_diff`, which is only reached on UPDATE -- so
-- inserting a credential stored the secret in full and only *changing*
-- one hid it. The production probe caught it: after inserting a row with
-- `client_secret = 'SUPER-SECRET'` the trail contained the string.
-- Redaction has to be a property of writing a row down, not of one of
-- the three ways of writing it down.
create or replace function app.audit_redact(p_row jsonb)
returns jsonb
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case
           when p_row is null then null
           else coalesce(
             (select jsonb_object_agg(
                       key,
                       case when key ~* '(secret|password|private_key|passphrase|api_key|token|credential)'
                            then to_jsonb('***'::text)
                            else value
                       end)
                from jsonb_each(p_row)),
             '{}'::jsonb)
         end;
$$;

create or replace function app.audit_diff(p_old jsonb, p_new jsonb)
returns jsonb
language sql
immutable
set search_path = public, app, pg_temp
as $$
  select app.audit_redact(
           coalesce(jsonb_object_agg(key, value), '{}'::jsonb))
    from jsonb_each(p_new)
   where key not in ('updated_at', 'created_at')
     and p_old -> key is distinct from value;
$$;

-- ---------------------------------------------------------------------
-- A row that does not name its own company
-- ---------------------------------------------------------------------
--
-- `access_type_modules` is which modules an access type reaches -- the
-- permission table, and one of the few worth auditing above all -- and
-- it has neither `org_id` nor `id`. Left to the generic path its rows
-- would be filed under no organization, where the company they belong to
-- could not read them: an audit row nobody can see is not an audit row.
create or replace function app.write_audit_log()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_old  jsonb := case when TG_OP = 'INSERT' then null else to_jsonb(OLD) end;
  v_new  jsonb := case when TG_OP = 'DELETE' then null else to_jsonb(NEW) end;
  v_row  jsonb := coalesce(v_new, v_old);
  v_org  uuid;
  v_id   uuid;
  v_from jsonb;
  v_to   jsonb;
begin
  if TG_TABLE_NAME = 'organizations' then
    v_org := (v_row ->> 'id')::uuid;
  elsif TG_TABLE_NAME = 'access_type_modules' then
    select t.org_id into v_org
      from public.access_types t
     where t.id = (v_row ->> 'access_type_id')::uuid;
  else
    v_org := nullif(v_row ->> 'org_id', '')::uuid;
  end if;

  begin
    v_id := nullif(v_row ->> 'id', '')::uuid;
  exception when others then
    v_id := null;   -- a table keyed on something other than a uuid
  end;

  -- Keyed on the access type and the module, so the access type is the
  -- record this change is about.
  if v_id is null and TG_TABLE_NAME = 'access_type_modules' then
    v_id := (v_row ->> 'access_type_id')::uuid;
  end if;

  if TG_OP = 'UPDATE' then
    v_to := app.audit_diff(v_old, v_new);
    -- A write that changed nothing is not an event.
    if v_to = '{}'::jsonb then return null; end if;
    v_from := app.audit_diff(v_new, v_old);
  else
    -- Insert and delete keep the whole row, redacted. This is the branch
    -- the first version of 0236 got wrong.
    v_from := app.audit_redact(v_old);
    v_to := app.audit_redact(v_new);
  end if;

  insert into public.audit_logs
    (org_id, user_id, table_name, record_id, action, old_data, new_data,
     ip_address, user_agent)
  values (v_org, auth.uid(), TG_TABLE_NAME, v_id, lower(TG_OP), v_from, v_to,
          nullif(split_part(coalesce(
            app.request_header('x-forwarded-for'), ''), ',', 1), '')::inet,
          app.request_header('user-agent'));

  return null;
end;
$$;

revoke all on function app.write_audit_log() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The money, the people it is paid to, and the permissions
-- ---------------------------------------------------------------------
do $do$
declare
  t       text;
  v_added integer := 0;
begin
  foreach t in array array[
    -- What was invoiced and billed
    'sales_documents', 'purchase_documents',
    -- What was actually paid
    'receipts', 'purchase_payments', 'expenses', 'expense_claims',
    'payroll_runs',
    -- Who it was paid to, and what was sold: a supplier's bank details
    -- changed the day before a payment run is the oldest fraud there is
    'contacts', 'items', 'fixed_assets',
    -- Credentials and permissions
    'einvoice_credentials', 'access_types', 'access_type_modules']
  loop
    if to_regclass('public.' || quote_ident(t)) is null then
      raise exception 'FAIL 0236: public.% does not exist', t;
    end if;
    execute format('drop trigger if exists audit_changes on public.%I', t);
    execute format(
      'create trigger audit_changes after insert or update or delete on public.%I
         for each row execute function app.write_audit_log()', t);
    v_added := v_added + 1;
  end loop;

  if v_added <> 13 then
    raise exception 'FAIL 0236: expected 13 tables, wired %', v_added;
  end if;
end
$do$;

-- A bill after it became a bill. Scoped by column so a till writing a
-- running total does not write an audit row per item.
drop trigger if exists audit_changes on public.pos_sales;
create trigger audit_changes
  after delete or update of status, voided_at, void_reason,
                            contact_id, loyalty_account_id
  on public.pos_sales
  for each row execute function app.write_audit_log();

-- The ledger, changed after the fact. Not insert: an insert is the
-- ledger, and auditing it would keep the books twice.
drop trigger if exists audit_changes on public.gl_entries;
create trigger audit_changes after update or delete on public.gl_entries
  for each row execute function app.write_audit_log();

drop trigger if exists audit_changes on public.gl_lines;
create trigger audit_changes after update or delete on public.gl_lines
  for each row execute function app.write_audit_log();

-- The positive control. A loop that silently wired nothing would leave
-- every statement above looking like it had worked, so this names each
-- of the sixteen and checks the trigger is actually on it -- rather than
-- counting, which a future migration adding a seventeenth would satisfy
-- while one of these sixteen had quietly gone missing.
do $do$
declare
  t       text;
  v_missing text[] := '{}';
begin
  foreach t in array array[
    'sales_documents', 'purchase_documents', 'receipts', 'purchase_payments',
    'expenses', 'expense_claims', 'payroll_runs', 'contacts', 'items',
    'fixed_assets', 'einvoice_credentials', 'access_types',
    'access_type_modules', 'pos_sales', 'gl_entries', 'gl_lines']
  loop
    if not exists (
      select 1 from pg_trigger tg
        join pg_class c on c.oid = tg.tgrelid
        join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = t
         and tg.tgname = 'audit_changes')
    then
      v_missing := v_missing || t;
    end if;
  end loop;

  if array_length(v_missing, 1) is not null then
    raise exception 'FAIL 0236: no audit trigger on %', array_to_string(v_missing, ', ');
  end if;
end
$do$;
