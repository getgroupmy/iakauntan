-- =====================================================================
-- iAkauntan :: 0056 a posting path the scheduler can use
--
-- A scheduled job has no auth.uid(), so it cannot pass the can_post
-- check inside create_gl_entry — nor the membership check inside
-- next_document_number, which is where the first attempt actually died.
--
-- Rather than let a runner write gl_entries directly and skip the
-- fiscal period and balance rules with it, both bodies move down into
-- app.*_internal and the public functions become the permission check
-- plus a call. One implementation, two doors.
-- =====================================================================

create or replace function app.next_document_number_internal(
  p_org_id uuid, p_doc_type text)
returns text
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_seq public.number_sequences;
  v_period_key text;
  v_number bigint;
  v_body text;
begin
  insert into public.number_sequences (org_id, doc_type, prefix)
  values (p_org_id, p_doc_type, app.default_doc_prefix(p_doc_type))
  on conflict (org_id, doc_type) do nothing;

  select * into v_seq from public.number_sequences
   where org_id = p_org_id and doc_type = p_doc_type for update;

  v_period_key := case v_seq.reset_policy
    when 'yearly' then to_char(current_date, 'YYYY')
    when 'monthly' then to_char(current_date, 'YYYYMM')
    else null end;

  if v_seq.reset_policy <> 'never' and v_seq.period_key is distinct from v_period_key then
    v_number := 1;
  else
    v_number := v_seq.next_value;
  end if;

  update public.number_sequences
     set next_value = v_number + 1, period_key = v_period_key
   where id = v_seq.id;

  v_body := lpad(v_number::text, v_seq.padding, '0');
  return v_seq.prefix || coalesce(v_period_key || '-', '') || v_body || v_seq.suffix;
end; $$;

create or replace function public.next_document_number(p_org_id uuid, p_doc_type text)
returns text
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id using errcode = '42501';
  end if;
  return app.next_document_number_internal(p_org_id, p_doc_type);
end; $$;

create or replace function app.create_gl_entry_internal(
  p_org_id uuid, p_entry_date date, p_source app.journal_source, p_lines jsonb,
  p_description text default null, p_source_table text default null,
  p_source_id uuid default null, p_reference text default null,
  p_currency character default 'MYR', p_exchange_rate numeric default 1)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_entry_id uuid; v_period_id uuid; v_status text; v_line jsonb;
  v_no integer := 0; v_debit numeric(18,2) := 0; v_credit numeric(18,2) := 0;
begin
  v_period_id := app.period_for_date(p_org_id, p_entry_date);
  if v_period_id is null then
    raise exception
      'No fiscal period covers %. Create the fiscal year before posting to it.',
      p_entry_date using errcode = '23514';
  end if;

  select status into v_status from public.fiscal_periods where id = v_period_id;
  if v_status <> 'open' then
    raise exception 'Fiscal period for % is %', p_entry_date, v_status using errcode = '23514';
  end if;

  insert into public.gl_entries (
    org_id, entry_no, entry_date, fiscal_period_id, source,
    source_table, source_id, description, reference,
    currency, exchange_rate, status, posted_at, posted_by, created_by
  ) values (
    p_org_id, app.next_document_number_internal(p_org_id, 'journal'),
    p_entry_date, v_period_id, p_source, p_source_table, p_source_id,
    p_description, p_reference, p_currency, p_exchange_rate,
    'posted', now(), auth.uid(), auth.uid()
  ) returning id into v_entry_id;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    insert into public.gl_lines (
      org_id, entry_id, line_no, account_id, description, debit, credit,
      currency, exchange_rate, contact_id, item_id, tax_code_id, tax_amount,
      project_code, department_code
    ) values (
      p_org_id, v_entry_id, v_no,
      (v_line ->> 'account_id')::uuid, v_line ->> 'description',
      round(coalesce((v_line ->> 'debit')::numeric, 0), 2),
      round(coalesce((v_line ->> 'credit')::numeric, 0), 2),
      p_currency, p_exchange_rate,
      nullif(v_line ->> 'contact_id', '')::uuid,
      nullif(v_line ->> 'item_id', '')::uuid,
      nullif(v_line ->> 'tax_code_id', '')::uuid,
      round(coalesce((v_line ->> 'tax_amount')::numeric, 0), 2),
      v_line ->> 'project_code', v_line ->> 'department_code');
    v_debit := v_debit + round(coalesce((v_line ->> 'debit')::numeric, 0), 2);
    v_credit := v_credit + round(coalesce((v_line ->> 'credit')::numeric, 0), 2);
  end loop;

  if v_debit <> v_credit then
    raise exception 'Journal does not balance: debits %, credits %', v_debit, v_credit
      using errcode = '23514';
  end if;
  return v_entry_id;
end; $$;

create or replace function public.create_gl_entry(
  p_org_id uuid, p_entry_date date, p_source app.journal_source, p_lines jsonb,
  p_description text default null, p_source_table text default null,
  p_source_id uuid default null, p_reference text default null,
  p_currency character default 'MYR', p_exchange_rate numeric default 1)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges to post to the ledger' using errcode = '42501';
  end if;
  return app.create_gl_entry_internal(
    p_org_id, p_entry_date, p_source, p_lines, p_description,
    p_source_table, p_source_id, p_reference, p_currency, p_exchange_rate);
end; $$;

-- The internal pair is for other definer functions and the scheduler.
-- Reaching them from an API key would skip the permission check.
revoke all on function app.next_document_number_internal(uuid, text)
  from public, anon, authenticated;
revoke all on function app.create_gl_entry_internal(
  uuid, date, app.journal_source, jsonb, text, text, uuid, text, character, numeric)
  from public, anon, authenticated;
