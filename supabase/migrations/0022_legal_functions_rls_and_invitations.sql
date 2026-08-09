-- =====================================================================
-- iAkauntan :: 0022 legal module logic, RLS, and team invitations
-- =====================================================================

-- ---------------------------------------------------------------------
-- Legal module setup: the accounts a firm needs to keep client money
-- separate, plus a designated client bank account.
-- ---------------------------------------------------------------------
create or replace function public.setup_legal_module(p_org_id uuid)
returns void language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_client_bank uuid; v_parent_asset uuid; v_parent_liab uuid;
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if not app.has_module(p_org_id, 'legal') then
    raise exception 'The Legal Firm Accounting module is not enabled for this organization';
  end if;

  select id into v_parent_asset from public.accounts
   where org_id = p_org_id and code = '1100';
  select id into v_parent_liab from public.accounts
   where org_id = p_org_id and code = '2100';

  insert into public.accounts (org_id, code, name, account_type, account_subtype,
                               parent_id, is_system, sort_order)
  values
    (p_org_id, '1150', 'Client Account (Bank)', 'asset', 'bank',
     v_parent_asset, true, 1150),
    (p_org_id, '1250', 'Disbursements Recoverable', 'asset', 'current_asset',
     v_parent_asset, true, 1250),
    (p_org_id, '2300', 'Client Monies Held', 'liability', 'current_liability',
     v_parent_liab, true, 2300)
  on conflict (org_id, code) do nothing;

  select id into v_client_bank from public.accounts
   where org_id = p_org_id and code = '1150';

  insert into public.bank_accounts (
    org_id, account_id, name, account_type, is_client_account, is_active)
  select p_org_id, v_client_bank, 'Client Account', 'current', true, true
   where not exists (
     select 1 from public.bank_accounts
      where org_id = p_org_id and is_client_account);
end;
$$;

comment on function public.setup_legal_module is
  'Creates the client account, client monies liability and disbursement accounts a law firm needs.';

-- ---------------------------------------------------------------------
-- Posting client money
--
-- Client money is a liability, never income: it increases the client
-- bank balance and the firm's obligation to the client in equal measure.
-- ---------------------------------------------------------------------
create or replace function public.post_client_transaction(p_id uuid)
returns uuid language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_txn public.client_account_transactions;
  v_bank_acct uuid; v_liab_acct uuid; v_entry uuid;
  v_entries jsonb; v_amount numeric(18,2);
begin
  select * into v_txn from public.client_account_transactions where id = p_id;
  if not found then raise exception 'Transaction % not found', p_id; end if;
  if not app.can_post(v_txn.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  if v_txn.gl_entry_id is not null then
    raise exception 'Transaction % is already posted', v_txn.transaction_no;
  end if;

  select a.id into v_bank_acct
    from public.bank_accounts b join public.accounts a on a.id = b.account_id
   where b.id = v_txn.bank_account_id and b.is_client_account;

  if v_bank_acct is null then
    select id into v_bank_acct from public.accounts
     where org_id = v_txn.org_id and code = '1150';
  end if;
  if v_bank_acct is null then
    raise exception 'No client account configured. Run setup_legal_module first.';
  end if;

  select id into v_liab_acct from public.accounts
   where org_id = v_txn.org_id and code = '2300';

  v_amount := v_txn.amount;

  -- Money in debits the client bank and credits what we owe the client;
  -- money out does the reverse.
  v_entries := jsonb_build_array(
    jsonb_build_object(
      'account_id', v_bank_acct,
      'description', coalesce(v_txn.description, v_txn.transaction_no),
      'debit', greatest(v_amount, 0), 'credit', greatest(-v_amount, 0)),
    jsonb_build_object(
      'account_id', v_liab_acct,
      'description', 'Client monies held',
      'debit', greatest(-v_amount, 0), 'credit', greatest(v_amount, 0))
  );

  v_entry := public.create_gl_entry(
    v_txn.org_id, v_txn.transaction_date, 'manual'::app.journal_source,
    v_entries, 'Client account ' || v_txn.transaction_no,
    'client_account_transactions', v_txn.id, v_txn.reference,
    v_txn.currency, 1);

  update public.client_account_transactions
     set gl_entry_id = v_entry, status = 'posted',
         posted_at = now(), posted_by = auth.uid()
   where id = p_id;

  if v_txn.bank_account_id is not null then
    update public.bank_accounts
       set current_balance = current_balance + v_amount
     where id = v_txn.bank_account_id;
  end if;

  return v_entry;
end;
$$;

-- Funds held per matter, and what is still unbilled.
create or replace function public.report_matter_summary(p_org_id uuid)
returns table (
  matter_id uuid, matter_no text, matter_name text, client_name text,
  status app.matter_status, client_funds numeric,
  unbilled_time numeric, unbilled_disbursements numeric,
  billed numeric, outstanding numeric)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select m.id, m.matter_no, m.name, c.name, m.status,
         coalesce((select sum(t.amount) from public.client_account_transactions t
                    where t.matter_id = m.id and t.status <> 'void'), 0),
         coalesce((select sum(e.amount) from public.time_entries e
                    where e.matter_id = m.id and e.is_billable and not e.is_billed), 0),
         coalesce((select sum(d.amount + d.tax_amount) from public.disbursements d
                    where d.matter_id = m.id and d.is_billable and not d.is_billed), 0),
         coalesce((select sum(s.total_amount) from public.sales_documents s
                    where s.matter_id = m.id and s.doc_type = 'invoice'
                      and s.status not in ('draft','void') and s.deleted_at is null), 0),
         coalesce((select sum(s.balance_amount) from public.sales_documents s
                    where s.matter_id = m.id and s.doc_type = 'invoice'
                      and s.status not in ('draft','void') and s.deleted_at is null), 0)
    from public.matters m
    join public.contacts c on c.id = m.client_id
   where m.org_id = p_org_id
     and m.deleted_at is null
     and app.is_org_member(p_org_id)
   order by m.matter_no;
$$;

-- ---------------------------------------------------------------------
-- RLS for the legal tables, gated on the module
-- ---------------------------------------------------------------------
do $do$
declare t text;
begin
  foreach t in array array[
    'matters', 'client_account_transactions', 'time_entries', 'disbursements'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy %I on public.%I for select to authenticated
         using (app.is_org_member(org_id))', t || '_select', t);
    execute format(
      'create policy %I on public.%I for insert to authenticated
         with check (app.can_write(org_id) and app.has_module(org_id, ''legal''))',
      t || '_insert', t);
    execute format(
      'create policy %I on public.%I for update to authenticated
         using (app.can_write(org_id) and app.has_module(org_id, ''legal''))
         with check (app.can_write(org_id) and app.has_module(org_id, ''legal''))',
      t || '_update', t);
    execute format(
      'create policy %I on public.%I for delete to authenticated
         using (app.can_post(org_id) and app.has_module(org_id, ''legal''))',
      t || '_delete', t);
  end loop;
end
$do$;

-- ---------------------------------------------------------------------
-- Team invitations
--
-- handle_new_user() already claims pending invitations by e-mail when
-- someone registers, so an invited user simply signs up and lands in the
-- right company with the right role.
-- ---------------------------------------------------------------------
create or replace function public.invite_member(
  p_org_id uuid, p_email text, p_role app.member_role)
returns uuid language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_id uuid; v_existing uuid; v_email citext := lower(trim(p_email))::citext;
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an owner or admin can invite people' using errcode = '42501';
  end if;
  if p_role = 'owner' then
    raise exception 'Ownership is transferred, not invited';
  end if;
  if v_email is null or v_email = '' then
    raise exception 'An email address is required';
  end if;

  -- Already a member? Just adjust their role.
  select m.id into v_existing
    from public.org_members m
    join public.profiles pr on pr.id = m.user_id
   where m.org_id = p_org_id and pr.email = v_email;

  if v_existing is not null then
    update public.org_members set role = p_role where id = v_existing;
    return v_existing;
  end if;

  insert into public.org_members (
    org_id, invited_email, role, status, invited_by,
    invite_token, invite_expires_at)
  values (
    p_org_id, v_email, p_role, 'invited', auth.uid(),
    encode(gen_random_bytes(24), 'hex'), now() + interval '14 days')
  on conflict (org_id, user_id) do nothing
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.accept_invitation(p_token text)
returns uuid language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_member public.org_members;
begin
  if auth.uid() is null then
    raise exception 'Sign in first' using errcode = '42501';
  end if;

  select * into v_member from public.org_members
   where invite_token = p_token and status = 'invited';

  if not found then
    raise exception 'That invitation is not valid';
  end if;
  if v_member.invite_expires_at < now() then
    raise exception 'That invitation has expired. Ask for a new one.';
  end if;

  update public.org_members
     set user_id = auth.uid(), status = 'active', joined_at = now(),
         invite_token = null
   where id = v_member.id;

  return v_member.org_id;
end;
$$;

-- Team list with profile details, readable by any member.
create or replace function public.org_team(p_org_id uuid)
returns table (
  member_id uuid, user_id uuid, email text, full_name text,
  role app.member_role, status app.member_status,
  invited_email text, joined_at timestamptz, created_at timestamptz)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select m.id, m.user_id, coalesce(p.email::text, m.invited_email::text),
         p.full_name, m.role, m.status, m.invited_email::text,
         m.joined_at, m.created_at
    from public.org_members m
    left join public.profiles p on p.id = m.user_id
   where m.org_id = p_org_id
     and app.is_org_member(p_org_id)
   order by m.created_at;
$$;
