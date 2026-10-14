-- =====================================================================
-- iAkauntan :: 0905 a document's totals are its lines'
--
-- `app.recalc_sales_totals` and `app.recalc_purchase_totals` (`0706`)
-- work a document's `subtotal`, `tax_amount`, `rounding_amount`,
-- `total_amount` and `base_total_amount` out of its lines, and run when
-- a line changes or the rounding method does. Posting reads the header:
-- the receivable or payable is `total_amount`, and the output or input
-- tax is `tax_amount`. `0781` made status, paid and balance the
-- database's; these five were still ordinary columns.
--
-- Measured on 14 October 2026, locally, as the owner with the role
-- `authenticated`: an invoice with one 8% line worked out to tax 80 and
-- a total of 1,080. Set by hand to tax 0 and a total of 1,000, it
-- posted 1210 1,000 / 4100 -1,000 and no output tax at all, the line
-- still saying 80. A bill set to tax 200 and a total of 1,200 posted
-- 1410 200 / 2110 -1,200 against a line that charged 80.
--
-- The app never writes them: a document it saves sends its lines, and
-- the totals follow.
--
-- Production on 14 October: 166 sales and 49 purchase documents, every
-- header's subtotal and tax agreeing with its lines.
--
-- Answered "the totals are the lines'": a client may not change the
-- five, nor insert a document with any of them already set. The
-- recalculation and every function that posts, transfers, imports or
-- rings up a sale run as their owner and are not asked. `discount_amount`
-- is left alone: it is what a client types when no percentage is set.
-- =====================================================================

create or replace function app.document_totals_are_its_lines()
returns trigger
language plpgsql
set search_path to 'public', 'app', 'pg_temp'
as $$
declare
  v_col text;
  v_old jsonb;
  v_new jsonb := to_jsonb(new);
begin
  -- NOT security definer, for 0781's reason: the question is who runs
  -- the statement.
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return new;
  end if;
  if tg_op = 'UPDATE' then
    v_old := to_jsonb(old);
  end if;

  foreach v_col in array array['subtotal', 'tax_amount', 'rounding_amount',
                               'total_amount', 'base_total_amount'] loop
    if tg_op = 'INSERT' and (v_new ->> v_col)::numeric <> 0 then
      raise exception
        'The % of a new document is worked out from its lines as they are '
        'added, and is not written directly (this one said %). Add the '
        'lines, and the % follows.',
        replace(v_col, '_', ' '), v_new ->> v_col, replace(v_col, '_', ' ')
        using errcode = '42501';
    end if;
    if tg_op = 'UPDATE' and (v_new -> v_col) is distinct from (v_old -> v_col) then
      raise exception
        'The % of % is worked out from its lines, and is not written '
        'directly (% -> %). Change the lines, and the % follows.',
        replace(v_col, '_', ' '), new.doc_no,
        v_old ->> v_col, v_new ->> v_col, replace(v_col, '_', ' ')
        using errcode = '42501';
    end if;
  end loop;
  return new;
end;
$$;

revoke all on function app.document_totals_are_its_lines() from public, anon, authenticated;

comment on function app.document_totals_are_its_lines() is
  'Refuses a client''s write of a sales or purchase document''s subtotal, '
  'tax, rounding, total or base total, and a client''s insert of a '
  'document with any of them set. The recalculation from the lines keeps '
  'them; posting reads them. 0905.';

create trigger totals_are_its_lines
  before insert or update of subtotal, tax_amount, rounding_amount,
                             total_amount, base_total_amount
  on public.sales_documents
  for each row execute function app.document_totals_are_its_lines();

create trigger totals_are_its_lines
  before insert or update of subtotal, tax_amount, rounding_amount,
                             total_amount, base_total_amount
  on public.purchase_documents
  for each row execute function app.document_totals_are_its_lines();
