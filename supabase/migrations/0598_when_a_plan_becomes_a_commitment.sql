-- =====================================================================
-- iAkauntan :: 0598 when a plan becomes a commitment
--
-- The thirteenth slice of the undocumented writes: the three that take
-- something drafted and make it real. A vacancy somebody may apply to.
-- A vacancy nobody may apply to any more. A works order the floor is
-- about to issue materials against.
--
-- All three read as status setters and none of them is one.
--
-- ---------------------------------------------------------------------
-- The one that copies a recipe
--
-- `confirm_manufacturing_order` EXPLODES THE BILL OF MATERIALS into the
-- order: every component and every operation, scaled by how many times
-- over the recipe is being made. Until it runs, the order names a
-- product and a quantity and nothing that could be issued against it.
--
-- Two things about that are worth publishing. It DELETES the existing
-- components and operations first, so confirming again replaces the
-- explosion rather than doubling it -- which also means a confirm after
-- somebody has adjusted a component by hand throws that adjustment
-- away. And the scrap arithmetic divides rather than multiplies:
-- needing twenty with one in twenty wasted means issuing twenty-one,
-- not nineteen.
--
-- ---------------------------------------------------------------------
-- The two that will not let a date lie
--
-- Neither vacancy function will accept a day that has not happened, and
-- `close_requisition` will not accept one before the vacancy opened.
-- These are the dates a time-to-hire report is computed from, and a
-- negative one is not an error anybody would see -- it is an average
-- that quietly improves.
--
-- `close_requisition` also refuses to record a vacancy as FILLED. That
-- belongs to `hire_applicant`, which has somebody to attach it to; a
-- requisition marked filled with nobody hired is a headcount that does
-- not reconcile to a payroll.
--
-- And on hold is not closed. A requisition parked while somebody
-- decides is still a vacancy, so it gets no closing date and stays on
-- the open list and in the count.
-- =====================================================================

comment on function public.open_requisition(uuid, date) is
  'Opens a vacancy so it can be applied to, from draft or from on '
  'hold, and clears any closing date a previous hold left behind. '
  'REFUSES ONE WITH NO HIRING MANAGER: applications to a requisition '
  'nobody owns go into a queue nobody is reading, and the refusal is '
  'the only thing standing between a candidate and silence. Refuses an '
  'opening date in the future -- a vacancy cannot have opened on a day '
  'that has not happened, and time-to-hire is measured from this. '
  'Defaults to today in Malaysian time. Needs `can_manage_hr`.';

comment on function public.close_requisition(uuid, app.requisition_status, date) is
  'Stops a vacancy, by cancelling it or putting it on hold. IT CANNOT '
  'RECORD ONE AS FILLED -- that is `hire_applicant`''s to say, because '
  'it has somebody to attach it to, and a requisition marked filled '
  'with nobody hired is a headcount that will not reconcile to a '
  'payroll. ON HOLD IS NOT CLOSED: a requisition parked while somebody '
  'decides is still a vacancy, so it gets no closing date and stays on '
  'the open list and in the count; only a cancellation is dated. '
  'Refuses a date in the future and a date before the vacancy opened, '
  'because a negative time-to-hire is not an error anybody notices -- '
  'it is an average that quietly improves. Needs `can_manage_hr`.';

comment on function public.confirm_manufacturing_order(uuid) is
  'Turns a drafted works order into one the floor can work to, by '
  'EXPLODING ITS BILL OF MATERIALS into the order: every component and '
  'every operation, scaled by how many times over the recipe is being '
  'made. Until this runs the order names a product and a quantity and '
  'nothing that could be issued against it. Scrap is ADDED rather than '
  'deducted -- needing twenty with one in twenty wasted means issuing '
  'twenty-one -- so the quantity required is the line divided by the '
  'remainder, not multiplied by the waste. The existing components and '
  'operations are DELETED first, so confirming again replaces the '
  'explosion rather than doubling it, and any adjustment somebody made '
  'by hand goes with it. Draft only, and the order must have a bill of '
  'materials. Needs `can_post`.';
