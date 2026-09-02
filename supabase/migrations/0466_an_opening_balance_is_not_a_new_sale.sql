-- ---------------------------------------------------------------------
-- 0466  An opening balance is not a new sale
-- ---------------------------------------------------------------------
-- `import_open_invoices` carries this comment, written when it was
-- built:
--
--   -- Written straight in rather than posted through an update, which
--   -- is also what keeps the credit-limit trigger out of this: it
--   -- fires on a document being posted, and refusing to record debt
--   -- somebody already owes because it exceeds the limit for new
--   -- sales would be backwards.
--
-- The reasoning is right and the mechanism is not there. The insert
-- leaves `gl_entry_id` null and the statement underneath the comment is
-- an `update` that sets it, which is precisely what
-- `app.enforce_credit_limit` fires on. Measured, on a customer with a
-- RM1,000 limit and RM5,000 of history to bring over:
--
--   credit_hold = true
--     -> "Pelanggan Lambat is on credit hold, so OLD-1 cannot be
--         posted. Take the hold off, or raise this as a cash sale."
--
--   credit_control = 'block'
--     -> "Posting OLD-2 would take Pelanggan Lambat to 5000.00 against
--         a credit limit of 1000.00."
--
-- Both are the backwards thing the comment names. The customer on hold
-- is the one whose overdue history you are most likely to be migrating,
-- and "raise this as a cash sale" is not advice about a debt from two
-- years ago. Nothing can be imported for them at all.
--
-- ### The discriminator
--
-- Not the note on the document, and not which function is running.
-- `app.create_gl_entry_internal` is given
-- `'opening_balance'::app.journal_source` for these, so by the time the
-- update sets `gl_entry_id` the entry exists and says what it is. The
-- trigger reads that.
--
-- It is worth being clear about what this does **not** exempt: an
-- invoice raised today for work done today is a new sale whatever
-- anybody types in the notes, and the only way to reach this exemption
-- is to post a journal whose source is `opening_balance` -- which
-- `create_gl_entry` sets from its caller and no screen offers.
--
-- ### The hold, too
--
-- The exemption is placed above the credit-hold check as well as the
-- limit arithmetic, and deliberately. A hold means "sell them nothing
-- more until this is sorted out"; it does not mean "and do not write
-- down what they already owe", which would leave the receivable
-- understated and the customer looking better than they are.
--
-- ### Mutants
--
-- Three, restated into a built database and run against
-- `supabase/tests/opening_balance_credit.sql`. All three die.
--
--   * the exemption removed -- killed by "a customer on credit hold can
--     still have their history brought over", which came back with the
--     measured refusal word for word;
--   * the exemption keyed off `notes like 'Opening balance%'` instead
--     of the journal source -- killed by "a new sale is still held to
--     the limit, whatever the notes say". This is the mutant worth
--     having. A note is typed by whoever raises the document, so that
--     version turns a credit limit into a suggestion for anybody who
--     reads the source or guesses the phrase. The journal source is set
--     by the posting path and no screen offers it;
--   * the exemption moved below the credit-hold check -- killed by the
--     same first assertion. The limit arithmetic would have been
--     exempted and the hold would not, which is most of the defect
--     left in place and the half that refuses everything rather than
--     just the large ones.
-- ---------------------------------------------------------------------

create or replace function app.enforce_credit_limit()
returns trigger
language plpgsql security definer
set search_path = public, app, pg_temp
as $function$
declare
  v_control     text;
  v_limit       numeric(18, 2);
  v_hold        boolean;
  v_outstanding numeric(18, 2);
  v_name        text;
begin
  if new.gl_entry_id is null or old.gl_entry_id is not null then
    return new;
  end if;
  if new.doc_type not in ('invoice', 'debit_note') then
    return new;
  end if;

  -- What this system was handed on the day it took over. A credit limit
  -- is a decision about what to sell somebody next; a debt they already
  -- owe is not something a limit can decline. Refusing it here would
  -- leave the receivable short by exactly the amount that worried
  -- somebody enough to set the limit.
  --
  -- Above the hold as well as the arithmetic: a hold says sell them
  -- nothing more, not pretend they owe nothing.
  if exists (select 1 from public.gl_entries e
              where e.id = new.gl_entry_id
                and e.source = 'opening_balance') then
    return new;
  end if;

  select coalesce(c.credit_limit, 0), coalesce(c.credit_hold, false), c.name
    into v_limit, v_hold, v_name
    from public.contacts c where c.id = new.contact_id;

  -- The hold, first and regardless of the mode. Somebody ticked this
  -- against this customer; the mode is about whether arithmetic may
  -- refuse on the company's behalf, not about whether the company means
  -- what it said.
  if v_hold then
    raise exception
      '% is on credit hold, so % cannot be posted. Take the hold off, '
      'or raise this as a cash sale.',
      v_name, new.doc_no
      using errcode = '23514';
  end if;

  select credit_control into v_control
    from public.organizations where id = new.org_id;
  if coalesce(v_control, 'warn') <> 'block' then
    return new;
  end if;

  if coalesce(v_limit, 0) <= 0 then
    return new;
  end if;

  select coalesce(sum(d.balance_amount * coalesce(d.exchange_rate, 1)), 0)
    into v_outstanding
    from public.sales_documents d
   where d.org_id = new.org_id and d.contact_id = new.contact_id
     and d.gl_entry_id is not null and d.status <> 'void'
     and d.deleted_at is null and d.id <> new.id;

  v_outstanding := v_outstanding
                 + new.balance_amount * coalesce(new.exchange_rate, 1);

  if v_outstanding > v_limit then
    raise exception
      'Posting % would take % to % against a credit limit of %. '
      'Raise the limit, take a payment, or set credit control to warn.',
      new.doc_no, v_name, round(v_outstanding, 2), round(v_limit, 2)
      using errcode = '23514';
  end if;

  return new;
end;
$function$;

comment on function app.enforce_credit_limit() is
  'Refuses a new sale to a customer on hold, or past their limit when '
  'credit control is set to block. Opening balances are exempt: a limit '
  'is a decision about what to sell somebody next, and a debt they '
  'already owe is not something it can decline. See 0057, 0466.';

comment on function public.import_open_invoices(uuid, jsonb, date, boolean) is
  'Brings a customer''s unpaid history over as posted invoices against '
  'opening equity. A comment inside it says the way it posts keeps the '
  'credit-limit trigger out; that was never true — the exemption is in '
  'app.enforce_credit_limit, and it keys off the journal source. See 0466.';

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_src text := pg_get_functiondef(to_regprocedure('app.enforce_credit_limit()'));
begin
  if position('''opening_balance''' in v_src) = 0 then
    raise exception
      '0466: a customer''s history still cannot be brought over past '
      'their limit';
  end if;

  -- Above the hold. Below it, a customer on hold still cannot have
  -- their history imported, which is most of the defect.
  if position('opening_balance' in v_src) > position('is on credit hold' in v_src)
  then
    raise exception
      '0466: the exemption sits below the credit-hold check, so the '
      'customer it matters most for is still refused';
  end if;

  -- And the rest of the rule is still there.
  if position('is on credit hold' in v_src) = 0
     or position('against a credit limit of' in v_src) = 0 then
    raise exception '0466: restating the trigger dropped 0057''s rule';
  end if;
end
$do$;
