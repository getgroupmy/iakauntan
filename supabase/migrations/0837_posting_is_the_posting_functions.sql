-- =====================================================================
-- iAkauntan :: 0837 posting is the posting functions'
--
-- A document, receipt, payment or manufacturing order is posted when its
-- posting function writes its journal and links it: `gl_entry_id`, and
-- with it `posted_at` and `posted_by`. Everything that asks "is this in
-- the books?" asks that column -- `0832`'s door ("not posted yet"), the
-- ageing and the customer's open items, and the posting functions
-- themselves, which refuse to post twice. `refuse_reposting` stops a
-- link being changed once it is set, and `0781` keeps a document's
-- status and paid figures to the functions. Nothing stopped a client
-- setting the link on a draft.
--
-- Measured on 12 October 2026, locally, as the owner with the role
-- `authenticated`: a draft receipt given INV-2's journal by an update
-- was accepted; `0832`'s door then applied it to INV-1, which became
-- completed while the receivable did not move, and `post_receipt`
-- refused it as already posted. A draft supplier payment did the same
-- to a bill. A draft invoice given another's journal stayed a draft,
-- showed on the customer's open items while the ledger held nothing,
-- and could never be posted. Draft bills took one the same way, and a
-- manufacturing order has only `refuse_reposting`. Expenses, stock
-- adjustments and claims already refuse this (`0824`, `0813`, `0795`).
--
-- Answered "guard the posting columns": a trigger refuses a client's
-- own statement -- role `authenticated` or `anon`, at the top trigger
-- depth -- that sets or changes `gl_entry_id`, `posted_at` or
-- `posted_by` on sales and purchase documents, receipts, supplier
-- payments and manufacturing orders, or that inserts one already
-- carrying them; on a receipt or supplier payment its status goes with
-- them. Every function that posts, voids or reverses one is a definer
-- and passes. NOT security definer: a definer would always answer "the
-- owner". The app writes none of these columns.
--
-- Production held no draft with a journal, and no journal linked twice,
-- across 165 invoices, 38 bills, 56 receipts, 20 payments and 2 orders
-- on 12 October.
-- =====================================================================

create or replace function app.posting_is_the_posting_functions()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_cols text[] := array['gl_entry_id', 'posted_at', 'posted_by'];
  v_new  jsonb;
  v_old  jsonb;
  v_col  text;
  v_no   text;
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return new;
  end if;

  if tg_table_name in ('receipts', 'purchase_payments') then
    v_cols := array_append(v_cols, 'status');
  end if;

  v_new := to_jsonb(new);
  v_no  := coalesce(v_new ->> 'doc_no', v_new ->> 'receipt_no',
                    v_new ->> 'payment_no', v_new ->> 'order_no');

  if tg_op = 'INSERT' then
    foreach v_col in array v_cols loop
      continue when not (v_new ? v_col);
      if (v_col = 'status' and v_new ->> v_col <> 'draft')
         or (v_col <> 'status' and jsonb_typeof(v_new -> v_col) <> 'null') then
        raise exception
          '% starts as a draft. Its % is set when it is posted, by posting '
          'it, not when it is recorded.',
          v_no, v_col
          using errcode = '42501';
      end if;
    end loop;
    return new;
  end if;

  v_old := to_jsonb(old);
  foreach v_col in array v_cols loop
    continue when not (v_new ? v_col);
    if v_new -> v_col is distinct from v_old -> v_col then
      raise exception
        'The % of % is the posting''s: it is set when it is posted, voided '
        'or reversed, not by hand.',
        v_col, v_no
        using errcode = '42501';
    end if;
  end loop;
  return new;
end $$;

revoke all on function app.posting_is_the_posting_functions()
  from public, anon, authenticated;

comment on function app.posting_is_the_posting_functions() is
  'On sales_documents, purchase_documents, receipts, purchase_payments '
  'and manufacturing_orders: refuses a client''s own statement that sets '
  'or changes gl_entry_id, posted_at or posted_by (and, on a receipt or '
  'supplier payment, its status), or inserts one already carrying them. '
  'The posting functions pass. 0837.';

-- Named to fire after `refuse_reposting` and the guards on a row already
-- posted (`refuse_posted_change`, the settlements' `*_posted_is_posted`):
-- triggers run in name order, and for a posted row their sentences are
-- the better answer. This one is for the draft and the insert.
create trigger the_posting_is_the_posting_functions
  before insert or update on public.sales_documents
  for each row execute function app.posting_is_the_posting_functions();
create trigger the_posting_is_the_posting_functions
  before insert or update on public.purchase_documents
  for each row execute function app.posting_is_the_posting_functions();
create trigger the_posting_is_the_posting_functions
  before insert or update on public.receipts
  for each row execute function app.posting_is_the_posting_functions();
create trigger the_posting_is_the_posting_functions
  before insert or update on public.purchase_payments
  for each row execute function app.posting_is_the_posting_functions();
create trigger the_posting_is_the_posting_functions
  before insert or update on public.manufacturing_orders
  for each row execute function app.posting_is_the_posting_functions();
