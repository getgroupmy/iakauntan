-- =====================================================================
-- 0764 :: a posted receipt says what was received; a bank transfer is
--         written only by its functions
--
-- Answered on 8 October: "freeze posted rows" and "close it".
--
-- 1. RECEIPTS AND SUPPLIER PAYMENTS
--
-- `receipts` and `purchase_payments` are writable by anybody with
-- `can_write`, and have to stay so: the app inserts each one as a draft
-- before it is posted. The only guard on a POSTED row was
-- `refuse_reposting` (0403), which protects the link to the journal and
-- nothing else. Reproduced under row level security: a posted RM1,000
-- receipt was rewritten to RM50,000 with RM50,000 unapplied, while its
-- journal still said RM1,000 -- a credit that could then clear RM50,000
-- of invoices nobody paid.
--
-- After posting, the one thing that legitimately changes is
-- `unapplied_amount`, which `app.apply_allocation` recomputes from the
-- amount whenever money is set against a document. The posting
-- functions write everything else IN the statement that sets
-- `gl_entry_id`, when the old row has none. The app never updates or
-- deletes either table. So once a row has a journal, every other column
-- is frozen and a client cannot delete it; a draft is untouched. The
-- platform's own teardown of a whole company -- the demo rebuild, a
-- company deleted with everything under it -- runs as the table's owner
-- and still removes posted rows with their journals: the full suite
-- caught that the first draft, refusing every delete, broke
-- `demo_rebuild.sql` and `demo_practice.sql`.
--
-- 2. BANK TRANSFERS
--
-- `bank_transfers` carried one write policy for every command, asking
-- only `can_post`, with the same single guard -- so a posted transfer's
-- amounts or accounts could be rewritten under its journal, or the row
-- deleted. The app only reads it; `create_bank_transfer`,
-- `post_bank_transfer` and `void_bank_transfer` are SECURITY DEFINER.
-- 0761's shape: the grant and the write policy go.
-- =====================================================================

create or replace function app.refuse_posted_settlement_change()
returns trigger
language plpgsql
set search_path = pg_catalog, public, app, pg_temp
as $$
begin
  if old.gl_entry_id is null then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  -- A DELETE is refused to a CLIENT -- the door this closes. The
  -- platform's own SECURITY DEFINER code runs as the table's owner and
  -- removes whole companies (the demo teardown and rebuild, a company
  -- deleted outright and everything cascading from it), journals and
  -- all; refusing those would leave nothing deletable. An UPDATE is
  -- frozen for everybody: nothing legitimate rewrites a posted row.
  if tg_op = 'DELETE' and current_user not in ('authenticated', 'anon') then
    return old;
  end if;

  if tg_op = 'DELETE' then
    raise exception
      'This % is posted, so it stays. Deleting it would leave its journal '
      'in the ledger with nothing behind it. Reverse the posting instead.',
      case when tg_table_name = 'receipts' then 'receipt' else 'payment' end
      using errcode = '42501';
  end if;

  -- Everything but what allocating recomputes.
  if (to_jsonb(new) - 'unapplied_amount' - 'updated_at')
     is distinct from (to_jsonb(old) - 'unapplied_amount' - 'updated_at') then
    raise exception
      'This % is posted as journal %, and what it says has to keep '
      'agreeing with that journal. Reverse the posting and record it '
      'again rather than changing it.',
      case when tg_table_name = 'receipts' then 'receipt' else 'payment' end,
      old.gl_entry_id
      using errcode = '42501';
  end if;
  return new;
end $$;

revoke all on function app.refuse_posted_settlement_change()
  from public, anon, authenticated;

comment on function app.refuse_posted_settlement_change() is
  'Freezes a posted receipt or supplier payment (0764): once it has a '
  'journal, only `unapplied_amount` -- which `apply_allocation` recomputes '
  '-- may change, and a client cannot delete it. The platform''s own '
  'teardown of a whole company still can. Drafts are untouched.';

drop trigger if exists receipts_posted_is_posted on public.receipts;
create trigger receipts_posted_is_posted
  before update or delete on public.receipts
  for each row execute function app.refuse_posted_settlement_change();

drop trigger if exists purchase_payments_posted_is_posted
  on public.purchase_payments;
create trigger purchase_payments_posted_is_posted
  before update or delete on public.purchase_payments
  for each row execute function app.refuse_posted_settlement_change();

revoke insert, update, delete on public.bank_transfers from authenticated;
drop policy if exists bank_transfers_write on public.bank_transfers;

comment on table public.bank_transfers is
  'Money moved between the company''s own accounts. WRITTEN ONLY BY '
  'FUNCTION -- `create_bank_transfer`, `post_bank_transfer`, '
  '`void_bank_transfer`. 0764 revoked insert, update and delete from '
  '`authenticated` and dropped the write policy: a posted transfer could '
  'be rewritten under its journal, or deleted.';
