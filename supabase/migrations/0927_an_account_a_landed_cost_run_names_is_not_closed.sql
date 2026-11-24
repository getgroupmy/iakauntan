-- =====================================================================
-- iAkauntan :: 0927 an account a landed cost run names is not closed
--
-- `0922` stopped `retire_account` closing an account that a document
-- not yet posted names: a sales or purchase document, an expense, a
-- stock adjustment. A landed cost run is written and posted the same
-- way -- each charge names the account it comes off, and the run
-- credits that account when it posts -- and was not asked. `0922` and
-- `0926` each recorded it as not in them.
--
-- Measured on 24 November 2026, locally, as the owner with the role
-- `authenticated`: a draft run with one charge of 50 on 5491, freight
-- of its own; `retire_account(5491)` answered "closed"; the run then
-- posted 1310 50 and 5491 -50, into an account closed under it, which
-- now carries a balance a closed account is not meant to have.
--
-- Production on 24 November: no landed cost run at all.
--
-- Answered "refuse closing while drafted". `retire_account` refuses an
-- account that a charge of a draft landed cost run names, and says
-- which run, in `0922`'s words. A run posted or cancelled is not
-- counted. Restated from `pg_get_functiondef` with only the lines
-- marked 0927 added; a run drafted before this, of which production
-- has none, is not asked again at posting.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.retire_account(p_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_a       public.accounts;
  v_balance numeric;
  v_bank    text;
  v_named   text;      -- 0921
  v_named_n integer;   -- 0921
begin
  select * into v_a from public.accounts a where a.id = p_id;
  if v_a.id is null then
    raise exception 'No such account.' using errcode = '22023';
  end if;
  if not app.can_post(v_a.org_id) then
    raise exception 'Only somebody who may post the books may change the chart'
      using errcode = '42501';
  end if;
  if v_a.deleted_at is not null then
    raise exception 'Account % is already closed.', v_a.code
      using errcode = '23505';
  end if;

  if exists (select 1 from app.posting_account_codes() c
              where c.code = v_a.code) then
    raise exception
      'Account % is one the ledger posts to by number. It can be renamed '
      'but not removed.', v_a.code
      using errcode = '23514';
  end if;

  if exists (select 1 from public.accounts a
              where a.parent_id = p_id and a.deleted_at is null) then
    raise exception
      'Account % still has accounts under it.', v_a.code
      using errcode = '23514';
  end if;

  -- What it holds (0828). A closed account is left out of the chart,
  -- and an account closed with a balance took that balance with it:
  -- the trial balance came out by it until 0828 put closed accounts
  -- with lines back in. Signed as `report_trial_balance` signs it.
  select coalesce(sum(l.debit - l.credit), 0)
    into v_balance
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
   where l.account_id = p_id and e.status = 'posted';
  v_balance := v_balance
    + case when v_a.account_type in ('asset', 'expense')
           then v_a.opening_balance else -v_a.opening_balance end;
  if v_balance <> 0 then
    raise exception
      'Account % still carries a balance of %. Journal it to another '
      'account first, then close it.',
      v_a.code, to_char(abs(v_balance), 'FM999,999,999,990.00')
        || case when v_balance > 0 then ' debit' else ' credit' end
      using errcode = '23514';
  end if;

  -- And what still posts to it (0828): a bank account's receipts and
  -- payments go to its ledger account whether or not that is open.
  select b.name into v_bank
    from public.bank_accounts b
   where b.account_id = p_id and b.is_active
   order by b.name
   limit 1;
  if v_bank is not null then
    raise exception
      'Account % is the ledger account of the bank account %, which '
      'still posts to it.', v_a.code, v_bank
      using errcode = '23514';
  end if;

  -- And what still names it for postings to come (0921). A setting
  -- that names an account is read every time something posts through
  -- it, whether or not the account is still open: a payroll, an
  -- invoice to a customer, a bill for an item, a claim, a month's
  -- depreciation, a disposal, a recurring journal, a recurring invoice
  -- and a year of deferred revenue were each measured landing in an
  -- account closed under them. Only the settings a posting reads are
  -- asked -- an item's cost of sales account, a tax code's two and a
  -- salary component's are read by none -- and only rows still in use:
  -- not a contact, an item or a payment method that has been removed,
  -- an asset disposed of or written off, a recurring journal or
  -- document switched off or past its end, nor revenue already
  -- recognised or cancelled.
  select count(*),
         string_agg(x.what, ', ' order by x.ord, x.what) filter (where x.rn <= 5)
    into v_named_n, v_named
    from (
      select y.ord, y.what, row_number() over (order by y.ord, y.what) as rn
        from (
          select 1 as ord, 'payroll settings (' || k.line || ')' as what
            from public.payroll_settings s
            cross join lateral (values
              (s.salary_expense_account_id, 'salary expense'),
              (s.epf_expense_account_id,    'employer''s EPF expense'),
              (s.socso_expense_account_id,  'employer''s SOCSO expense'),
              (s.eis_expense_account_id,    'employer''s EIS expense'),
              (s.hrdf_expense_account_id,   'HRD Corp levy expense'),
              (s.salary_payable_account_id, 'net salary payable'),
              (s.epf_payable_account_id,    'EPF payable'),
              (s.socso_payable_account_id,  'SOCSO payable'),
              (s.eis_payable_account_id,    'EIS payable'),
              (s.pcb_payable_account_id,    'PCB payable'),
              (s.zakat_payable_account_id,  'zakat payable')
            ) k(account_id, line)
           where s.org_id = v_a.org_id and k.account_id = p_id
          union all
          select 2, 'contact ' || concat_ws(' ', c.code, c.name) || ' (receivable account)'
            from public.contacts c
           where c.receivable_account_id = p_id and c.deleted_at is null
          union all
          select 2, 'contact ' || concat_ws(' ', c.code, c.name) || ' (payable account)'
            from public.contacts c
           where c.payable_account_id = p_id and c.deleted_at is null
          union all
          select 3, 'item ' || concat_ws(' ', i.code, i.name) || ' (sales account)'
            from public.items i
           where i.sales_account_id = p_id and i.deleted_at is null
          union all
          select 3, 'item ' || concat_ws(' ', i.code, i.name) || ' (purchase account)'
            from public.items i
           where i.purchase_account_id = p_id and i.deleted_at is null
          union all
          select 4, 'claim type ' || concat_ws(' ', t.code, t.name)
            from public.claim_types t
           where t.expense_account_id = p_id
          union all
          select 5, 'fixed asset ' || concat_ws(' ', f.asset_no, f.name) || ' (' || k.line || ')'
            from public.fixed_assets f
            cross join lateral (values
              (f.asset_account_id,       'asset account'),
              (f.accumulated_account_id, 'accumulated depreciation'),
              (f.expense_account_id,     'depreciation expense')
            ) k(account_id, line)
           where k.account_id = p_id
             and f.deleted_at is null
             and f.status in ('active', 'fully_depreciated')
          union all
          select 6, 'payment method ' || m.name || ' (charge account)'
            from public.payment_methods m
           where m.charge_account_id = p_id and m.deleted_at is null
          union all
          -- As `app.run_recurring_journals` chooses what it posts.
          select 7, 'recurring journal ' || j.name
            from public.recurring_journals j
           where j.org_id = v_a.org_id
             and j.is_active
             and (j.end_date is null or j.next_run_date <= j.end_date)
             and exists (
               select 1
                 from jsonb_array_elements(
                        case when jsonb_typeof(j.template -> 'lines') = 'array'
                             then j.template -> 'lines' else '[]'::jsonb end) l
                where l ->> 'account_id' = p_id::text)
          union all
          select 8, 'recurring ' || r.kind || ' document ' || r.name
            from public.recurring_documents r
           where r.org_id = v_a.org_id
             and r.is_active
             and exists (
               select 1
                 from jsonb_array_elements(
                        case when jsonb_typeof(r.template -> 'lines') = 'array'
                             then r.template -> 'lines' else '[]'::jsonb end) l
                where l ->> 'account_id' = p_id::text)
          union all
          -- As `recognise_revenue` chooses what is left to release.
          select 9, 'revenue still to recognise on ' || d.doc_no
            from public.sales_documents d
           where d.org_id = v_a.org_id
             and exists (
               select 1 from public.revenue_schedule_periods s
                where s.document_id = d.id
                  and s.revenue_account_id = p_id
                  and s.gl_entry_id is null
                  and s.amount > s.cancelled_amount)
          union all
          -- 0922: and what is written and has yet to post. A line's
          -- account is fixed when the line is written and read when
          -- the document posts -- or when it is turned into the one
          -- that does, `transfer_document` carrying the account with
          -- the line. Asked of documents not yet posted: one that posts
          -- (an invoice, a bill, a note) until it does; one that only
          -- carries its lines on (a quotation, an order) until all of
          -- it has been carried, or it is cancelled.
          select 10, case when d.doc_type in ('invoice', 'credit_note', 'debit_note', 'refund_note')
                          then 'unposted ' else 'open ' end
                     || replace(d.doc_type::text, '_', ' ') || ' ' || d.doc_no
            from public.sales_documents d
           where d.org_id = v_a.org_id
             and d.deleted_at is null
             and d.status in ('draft', 'pending', 'approved')
             and d.fulfilment_status <> 'cancelled'
             and (d.doc_type in ('invoice', 'credit_note', 'debit_note', 'refund_note')
                  or d.fulfilment_status <> 'fulfilled')
             and exists (select 1 from public.sales_document_lines l
                          where l.document_id = d.id and l.account_id = p_id)
          union all
          select 10, case when d.doc_type in ('bill', 'purchase_credit_note', 'purchase_debit_note')
                          then 'unposted ' else 'open ' end
                     || replace(d.doc_type::text, '_', ' ') || ' ' || d.doc_no
            from public.purchase_documents d
           where d.org_id = v_a.org_id
             and d.deleted_at is null
             and d.status in ('draft', 'pending', 'approved')
             and d.fulfilment_status <> 'cancelled'
             and (d.doc_type in ('bill', 'purchase_credit_note', 'purchase_debit_note')
                  or d.fulfilment_status <> 'fulfilled')
             and exists (select 1 from public.purchase_document_lines l
                          where l.document_id = d.id and l.account_id = p_id)
          union all
          select 11, 'unposted expense ' || e.expense_no
            from public.expenses e
           where e.org_id = v_a.org_id
             and e.deleted_at is null
             and e.status in ('draft', 'pending', 'approved')
             and (e.account_id = p_id
                  or exists (select 1 from public.expense_lines l
                              where l.expense_id = e.id and l.account_id = p_id))
          union all
          select 12, 'unposted stock adjustment ' || s.adjustment_no
            from public.stock_adjustments s
           where s.org_id = v_a.org_id
             and s.account_id = p_id
             and s.status in ('draft', 'pending', 'approved')
          union all
          -- 0927: and a landed cost run not yet posted. Each charge
          -- names the account it comes off, and the run credits it
          -- there when it posts.
          select 13, 'unposted landed cost run ' || r.run_no
            from public.landed_cost_runs r
           where r.org_id = v_a.org_id
             and r.status = 'draft'
             and exists (select 1 from public.landed_cost_charges c
                          where c.run_id = r.id and c.account_id = p_id)
        ) y
    ) x;
  if v_named_n > 0 then
    raise exception
      'Account % is still named by %, and what is posted through that '
      'would go on landing in it after it closed. Name another account '
      'there first, then close it.',
      v_a.code,
      v_named || case when v_named_n > 5
                      then ' and ' || (v_named_n - 5) || ' more' else '' end
      using errcode = '23514';
  end if;

  perform app.record_closure(
    'ledger_account', v_a.id, v_a.org_id, v_a.code || ' ' || v_a.name,
    jsonb_build_object(
      'code', v_a.code,
      'name', v_a.name,
      'account_type', v_a.account_type,
      'account_subtype', v_a.account_subtype,
      'was_active', v_a.is_active,
      'posted_lines', (select count(*) from public.gl_lines l
                        where l.account_id = v_a.id)),
    null, 'self_service', auth.uid());

  update public.accounts
     set is_active = false, deleted_at = now()
   where id = p_id;

  return 'closed';
end $function$;

comment on function public.retire_account(uuid) is
  'Closes a ledger account: switched off, hidden from the chart, and '
  'kept. 0619 took out 0459''s outright delete. Refuses an account the '
  'ledger posts to by number, one with open accounts under it, (0828) '
  'one that still carries a balance or that an active bank account '
  'posts to, (0921) one that payroll settings, a contact, an item, a '
  'claim type, a fixed asset, a payment method, a recurring journal or '
  'document, or revenue still to recognise names for postings to come, '
  '(0922) one that a sales or purchase document, an expense or a stock '
  'adjustment not yet posted still names, and (0927) one that a charge '
  'of a landed cost run not yet posted names.';
