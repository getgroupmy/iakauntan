-- =====================================================================
-- iAkauntan :: a manufacturing order names its own company's branch
--
-- 0131 gave five tables a `branch_id` and a trigger to go with it,
-- because a document that names another company's branch is invisible on
-- every branch screen and quietly wrong in every report by branch.
-- 0133 added a sixth `branch_id`, on `manufacturing_orders`, and did not
-- add the trigger.
--
-- Nothing announced it. The column has a foreign key to `branches`, so
-- it refuses a branch that does not exist — it just does not care whose
-- it is, and a foreign key that points at the right table looks exactly
-- like a constraint that works.
--
-- Found the way the others were: by asserting the refusal *and* the two
-- things that must still be accepted. An order with no branch at all is
-- the ordinary case, and an order naming its own company's branch is the
-- point of the feature; a guard that broke either would be worse than
-- the gap it closed.
-- =====================================================================

create trigger branch_belongs_to_org
  before insert or update of branch_id, org_id on public.manufacturing_orders
  for each row execute function app.branch_belongs_to_org();
