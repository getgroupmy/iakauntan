-- =====================================================================
-- iAkauntan :: 0403 the column that says "this was already posted"
--
-- `0402` froze the posted sales and purchase document, and the sharpest
-- thing it found was not an amount. It was this:
--
--     update sales_documents set gl_entry_id = null where id = ...
--     select post_sales_document(<the same invoice>)
--     -> a second journal
--
-- because `post_sales_document_internal`'s whole defence against
-- posting the same document twice is
--
--     if v_doc.gl_entry_id is not null then
--       raise exception 'Document % is already posted'
--
-- a fact stored in a column the client may write. `0402` shut that for
-- two tables. This migration asks how many others there are.
--
-- ---------------------------------------------------------------------
-- Eleven, and they all guard the same way
--
-- Asked of the catalogue rather than remembered: eleven posting
-- routines refuse a second posting by reading `gl_entry_id` —
--
--     app.post_sales_document_internal     public.post_expense
--     app.post_purchase_document_internal  public.post_expense_claim
--     app.post_receipt_internal            public.post_purchase_payment
--     public.post_bank_transfer            public.post_stock_adjustment
--     public.post_client_transaction       public.post_withholding
--     public.void_sales_document
--
-- and every table they read it from grants UPDATE to `authenticated`.
--
-- Measured on `expenses`, deliberately not a document, as an
-- `accountant` under `set local role authenticated`: an RM100 expense
-- posted, `gl_entry_id` set to null by hand, `post_expense` called
-- again. Two entries, RM200 charged to the profit and loss for RM100 of
-- petrol.
--
-- So this is not a fact about invoices. It is a fact about the column,
-- and it holds wherever the column does.
--
-- ---------------------------------------------------------------------
-- One rule, and a narrow one
--
-- `gl_entry_id`, once it has a value, may not be given a different one
-- or taken away. That is all. Nothing else on any of these rows is
-- touched — `0402` is what a full freeze looks like and it took a
-- named column list per table to write safely, which is why it covers
-- two tables and this covers twenty.
--
-- Setting it for the first time is untouched, because that is what
-- posting is. Every posting routine above writes `null -> <entry>` and
-- none of them writes anything else, so none of them can trip this.
--
-- What it costs an honest caller: nothing. What it costs the second
-- posting: the whole of it.
--
-- ---------------------------------------------------------------------
-- `bank_transactions` is not in the list, and the reason is the point
--
-- On every other table `gl_entry_id` records "this row was posted, and
-- here is its journal". On `bank_transactions` it means something else
-- entirely: which existing journal this statement line was *matched*
-- to. `match_bank_transaction` sets it and
-- `unmatch_bank_transaction` clears it —
--
--     update public.bank_transactions
--        set matched_table = null, matched_id = null, gl_entry_id = null,
--            is_reconciled = false, ...
--
-- which is an ordinary correction: a bank line matched to the wrong
-- journal has to be unmatched. Freezing it there would break
-- reconciliation, and the column would have been frozen on the strength
-- of its name rather than its meaning.
--
-- The exclusion is asserted below, so it is a decision on the record
-- rather than a table that quietly fell out of a loop.
--
-- ---------------------------------------------------------------------
-- Where the tables come from
--
-- The catalogue, not a list. A list written today is a list that does
-- not cover the table added next year, and this is exactly the kind of
-- rule that is only worth anything if it is everywhere.
-- `posted_link_is_immutable.sql` asks the same question of the
-- catalogue and fails if any table carrying the column has no trigger.
-- =====================================================================

create or replace function app.refuse_reposting()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  -- Only a value being changed or removed. `null -> something` is a
  -- posting and is what every posting routine in the schema does.
  if old.gl_entry_id is not null
     and new.gl_entry_id is distinct from old.gl_entry_id then
    raise exception
      'This % was posted as journal %, and the link to it cannot be '
      'changed. Clearing it would let the same thing be posted again, '
      'and the company would carry it twice — the posting routines '
      'refuse a second posting by reading this column and nothing '
      'else. Undo the posting the supported way: reverse or void it, '
      'which leaves the original standing (`0102`), or raise a credit '
      'note.',
      replace(tg_table_name, '_', ' '), old.gl_entry_id
      using errcode = '42501';
  end if;
  return new;
end $$;

comment on function app.refuse_reposting() is
  'Eleven posting routines refuse a second posting by reading '
  '`gl_entry_id`. Measured before `0403`: an accountant could clear it '
  'by hand and call the posting routine again — RM200 charged to the '
  'profit and loss for RM100 of petrol.';

revoke all on function app.refuse_reposting() from public, anon, authenticated;

do $do$
declare
  r record;
  v_n int := 0;
  -- See the header. `gl_entry_id` on `bank_transactions` is a match
  -- pointer, not a posting record, and unmatching a bank line is an
  -- ordinary correction.
  v_skip constant text[] := array['bank_transactions'];
begin
  for r in
    select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      join pg_attribute a on a.attrelid = c.oid
     where n.nspname = 'public' and c.relkind = 'r'
       and a.attname = 'gl_entry_id' and a.attnum > 0 and not a.attisdropped
       and c.relname <> all (v_skip)
     order by 1
  loop
    execute format(
      'create trigger refuse_reposting before update on public.%I '
      'for each row execute function app.refuse_reposting()', r.relname);
    v_n := v_n + 1;
  end loop;

  if v_n < 15 then
    raise exception
      'FAIL 0403: only % tables in public carry gl_entry_id, which is '
      'too few to be the schema this migration was written against',
      v_n;
  end if;
  raise notice '0403: the posted link is immutable on % tables', v_n;
end
$do$;

-- ---------------------------------------------------------------------
-- And every one of them is covered
-- ---------------------------------------------------------------------
do $do$
declare v_missing text;
begin
  select string_agg(c.relname, ', ' order by c.relname) into v_missing
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid
   where n.nspname = 'public' and c.relkind = 'r'
     and a.attname = 'gl_entry_id' and a.attnum > 0 and not a.attisdropped
     and c.relname <> 'bank_transactions'
     and not exists (select 1 from pg_trigger t
                      where t.tgrelid = c.oid
                        and t.tgname = 'refuse_reposting');
  if v_missing is not null then
    raise exception
      'FAIL 0403: % carries gl_entry_id and has no trigger on it',
      v_missing;
  end if;

  -- The exclusion, asserted rather than assumed. If `bank_transactions`
  -- ever stops being the odd one out, this is where somebody finds out.
  if exists (select 1 from pg_trigger t
              where t.tgrelid = 'public.bank_transactions'::regclass
                and t.tgname = 'refuse_reposting') then
    raise exception
      'FAIL 0403: bank_transactions was covered, and unmatching a bank '
      'line would now be refused';
  end if;
end
$do$;
