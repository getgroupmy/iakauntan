-- =====================================================================
-- iAkauntan :: 0904 what was taken forward is the database's
--
-- `0081` keeps four counters on document lines -- `quantity_invoiced`
-- and `quantity_fulfilled` on a sale, `quantity_billed` and
-- `quantity_received` on a purchase -- and `fulfilment_status` on the
-- header, recomputed by `app.refresh_sales_progress` and
-- `app.refresh_purchase_progress` from the documents raised from each
-- line. `transfer_document` reads them to cap what can still be taken
-- forward, and since `0903` they are what keeps an order received on a
-- note from being billed again from the order.
--
-- They were ordinary columns a client could write.
--
-- Measured on 14 October 2026, locally, as the owner with the role
-- `authenticated`: an order received in full on a note had
-- `quantity_received` set to 0 by hand and was then billed straight
-- from the order for all ten; a quotation already invoiced had
-- `quantity_invoiced` zeroed and was invoiced a second time.
--
-- The app reads these columns and never writes them: a line it saves
-- carries none of them, and a header none.
--
-- Production on 14 October: 182 sales lines and 104 purchase lines,
-- every counter agreeing with the documents raised from it.
--
-- Answered "the database's to write": a client may not change a
-- counter or `fulfilment_status`, nor insert a line or a document with
-- one already set. The refresh functions, `transfer_document` and every
-- other SECURITY DEFINER path run as their owner and are not asked.
--
-- Each trigger names its columns as `column=starting value`, the value
-- as JSON, so one function serves all four tables.
-- =====================================================================

create or replace function app.what_was_taken_forward_is_the_databases()
returns trigger
language plpgsql
set search_path to 'public', 'app', 'pg_temp'
as $$
declare
  v_arg   text;
  v_col   text;
  v_start jsonb;
  v_new   jsonb := to_jsonb(new);
  v_old   jsonb;
begin
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return new;
  end if;
  if tg_op = 'UPDATE' then
    v_old := to_jsonb(old);
  end if;

  foreach v_arg in array tg_argv loop
    v_col   := split_part(v_arg, '=', 1);
    v_start := split_part(v_arg, '=', 2)::jsonb;
    if (tg_op = 'INSERT' and (v_new -> v_col) is distinct from v_start)
       or (tg_op = 'UPDATE' and (v_new -> v_col) is distinct from (v_old -> v_col)) then
      raise exception
        '% is kept by the database from the documents raised from this one, '
        'and is not written by hand. Raise, void or delete those documents '
        'instead.', v_col
        using errcode = '42501';
    end if;
  end loop;
  return new;
end;
$$;

revoke all on function app.what_was_taken_forward_is_the_databases() from public, anon, authenticated;

comment on function app.what_was_taken_forward_is_the_databases() is
  'Refuses a client''s write of the transfer counters on document lines '
  'and fulfilment_status on document headers (trigger arguments: '
  'column=starting value, the value as JSON). The refresh functions keep '
  'them. 0904.';

create trigger what_was_taken_forward_is_the_databases
  before insert or update of quantity_invoiced, quantity_fulfilled
  on public.sales_document_lines
  for each row execute function app.what_was_taken_forward_is_the_databases(
    'quantity_invoiced=0', 'quantity_fulfilled=0');

create trigger what_was_taken_forward_is_the_databases
  before insert or update of quantity_billed, quantity_received
  on public.purchase_document_lines
  for each row execute function app.what_was_taken_forward_is_the_databases(
    'quantity_billed=0', 'quantity_received=0');

create trigger what_was_taken_forward_is_the_databases
  before insert or update of fulfilment_status
  on public.sales_documents
  for each row execute function app.what_was_taken_forward_is_the_databases(
    'fulfilment_status="pending"');

create trigger what_was_taken_forward_is_the_databases
  before insert or update of fulfilment_status
  on public.purchase_documents
  for each row execute function app.what_was_taken_forward_is_the_databases(
    'fulfilment_status="pending"');
