-- =====================================================================
-- iAkauntan :: 0059 a reversal is a posting like any other
--
-- reverse_gl_entry had the same hole create_gl_entry did: it looked up
-- the period for the reversal date and then used it without checking.
-- So a reversal dated outside every fiscal year, or into a period that
-- had been deliberately closed, posted anyway — which is a neat way to
-- undo a closed month without anyone reopening it.
-- =====================================================================

create or replace function public.reverse_gl_entry(
  p_entry_id uuid, p_date date default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_entry public.gl_entries;
  v_new_id uuid;
  v_period_id uuid;
  v_status text;
  v_on date := coalesce(p_date, current_date);
begin
  select * into v_entry from public.gl_entries where id = p_entry_id;
  if not found then raise exception 'Journal % not found', p_entry_id; end if;
  if not app.can_post(v_entry.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if v_entry.status <> 'posted' then
    raise exception 'Only posted journals can be reversed' using errcode = '22023';
  end if;

  v_period_id := app.period_for_date(v_entry.org_id, v_on);
  if v_period_id is null then
    raise exception
      'No fiscal period covers %. Create the fiscal year before posting to it.',
      v_on using errcode = '23514';
  end if;
  select status into v_status from public.fiscal_periods where id = v_period_id;
  if v_status <> 'open' then
    raise exception 'Fiscal period for % is %', v_on, v_status using errcode = '23514';
  end if;

  insert into public.gl_entries (
    org_id, entry_no, entry_date, fiscal_period_id, source, source_table, source_id,
    description, reference, currency, exchange_rate, status, is_reversal,
    reversed_entry_id, posted_at, posted_by, created_by
  ) values (
    v_entry.org_id, app.next_document_number_internal(v_entry.org_id, 'journal'),
    v_on, v_period_id, v_entry.source,
    v_entry.source_table, v_entry.source_id,
    'Reversal of ' || v_entry.entry_no, v_entry.reference,
    v_entry.currency, v_entry.exchange_rate, 'posted', true, v_entry.id,
    now(), auth.uid(), auth.uid()
  ) returning id into v_new_id;

  insert into public.gl_lines (
    org_id, entry_id, line_no, account_id, description, debit, credit,
    currency, exchange_rate, contact_id, item_id, tax_code_id)
  select org_id, v_new_id, line_no, account_id,
         'Reversal: ' || coalesce(description, ''),
         credit, debit, currency, exchange_rate, contact_id, item_id, tax_code_id
    from public.gl_lines where entry_id = p_entry_id;

  update public.gl_entries set status = 'void' where id = p_entry_id;
  return v_new_id;
end; $$;

revoke all on function public.reverse_gl_entry(uuid, date) from public, anon;
grant execute on function public.reverse_gl_entry(uuid, date)
  to authenticated, service_role;
