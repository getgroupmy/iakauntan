-- Make an approved expense claim actually postable.
--
-- `post_expense_claim` has existed since 0032 with no caller —
-- `decide_expense_claim` approves and does not post, and neither did the
-- app — so an approved claim was approved and then nothing happened.
-- Exposing it (this migration's companion change in the Flutter client)
-- runs it for the first time, and the first run finds a rounding bug.
--
-- `app.claim_expense_allocation` splits the approved amount across the
-- expense accounts in proportion to what was claimed against each, and
-- rounds every share to the cent independently. Three accounts and an
-- approved amount of 100.00 gives 33.33 three times: 99.99 against a
-- credit of 100.00. `create_gl_entry_internal` then refuses the whole
-- journal with 23514 "Journal does not balance", and the claim can never
-- be posted at all.
--
-- The residual goes on the largest share, which is where a cent is
-- least visible and where every allocation convention puts it. The
-- alternative — rounding the credit to match the debits — would pay the
-- employee something other than what was approved.

create or replace function app.claim_expense_allocation(p_claim_id uuid)
returns table (account_id uuid, amount numeric)
language sql stable
set search_path = public, pg_temp as $$
  with claim as (
    select c.id, c.org_id, c.approved_amount,
           nullif(sum(l.amount), 0) as line_total
      from public.expense_claims c
      join public.expense_claim_lines l on l.claim_id = c.id
     where c.id = p_claim_id
     group by c.id, c.org_id, c.approved_amount
  ),
  allocated as (
    select coalesce(
             ct.expense_account_id,
             (select a.id from public.accounts a
               where a.org_id = claim.org_id and a.code = '6900'
                 and not a.is_group limit 1)) as account_id,
           round(sum(l.amount) / claim.line_total * claim.approved_amount, 2)
             as amount,
           claim.approved_amount
      from claim
      join public.expense_claim_lines l on l.claim_id = claim.id
      left join public.claim_types ct on ct.id = l.claim_type_id
     group by 1, claim.line_total, claim.approved_amount
  ),
  -- `order by amount desc, account_id` rather than `amount desc` alone:
  -- two accounts carrying the same share would otherwise take the cent
  -- in whatever order the plan happened to produce, and the same claim
  -- would post differently on different days.
  with_residual as (
    select a.account_id,
           a.amount + case
             when row_number() over (order by a.amount desc, a.account_id) = 1
             then a.approved_amount - sum(a.amount) over ()
             else 0
           end as amount
      from allocated a
  )
  select account_id, amount from with_residual where amount <> 0;
$$;
