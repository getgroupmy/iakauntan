-- =====================================================================
-- iAkauntan :: 0809 a split is what the split function wrote
--
-- `expense_lines` splits one expense across accounts -- the RM500 on
-- the card that was part flights and part entertainment (`0496`). The
-- app writes it only through `set_expense_split`, which refuses a
-- posted or deleted expense, refuses a line with no amount or another
-- company's account, and rewrites the expense's own amount, tax and
-- total from the lines ("the header follows the split").
-- `post_expense` then posts each line and gives the largest whatever
-- is left of the expense. But `expense_lines_write`, an `ALL` policy
-- asking `app.can_write`, let any member who may write insert, update
-- and delete the lines directly, and none of that was asked.
--
-- Measured on 11 October 2026, locally, as the owner with the role
-- `authenticated`: two lines written directly on a RM500 expense,
-- RM100 to 6100 and RM50 to 6200. `post_expense` put RM450 to 6100 --
-- the largest line taking the rest -- while the split on record still
-- said RM100. Lines summing past the expense failed at posting on a
-- bare `gl_lines` check constraint instead; and a posted expense's
-- lines could be changed after the journal was written.
--
-- Answered "read-only to clients", as `0804` and `0806` to `0808`: the
-- grants are revoked and the write policies dropped, the restrictive
-- `module_gate_` ones with them. Reading stays, by
-- `expense_lines_select`. `set_expense_split` is a definer.
--
-- Production held one expense and no split line on 11 October.
-- =====================================================================

revoke insert, update, delete on public.expense_lines from authenticated, anon;
drop policy if exists expense_lines_write on public.expense_lines;
drop policy if exists module_gate_insert on public.expense_lines;
drop policy if exists module_gate_update on public.expense_lines;
drop policy if exists module_gate_delete on public.expense_lines;

comment on table public.expense_lines is
  'One expense split across accounts. WRITTEN ONLY BY FUNCTION -- 0809 '
  'revoked insert, update and delete from clients and dropped the write '
  'policies; set_expense_split writes it, and rewrites the expense''s '
  'totals from it, before post_expense posts it.';
