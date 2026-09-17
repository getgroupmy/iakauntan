-- =====================================================================
-- iAkauntan :: 0597 the desk, and its clocks
--
-- The twelfth slice of the undocumented writes: the three that run a
-- support desk. All three write a ticket, and in all three the thing a
-- caller cannot see from the signature is WHAT IT DOES TO THE CLOCKS.
--
-- A ticket carries two of them -- time to first response and time to
-- resolution -- and an SLA is a promise made against both. Every one of
-- these three moves one, and two of them can leave one running in a way
-- nobody notices until the breach report.
--
-- ---------------------------------------------------------------------
-- What stops the first-response clock
--
-- `add_ticket_comment` stops it on the first reply THE REQUESTER CAN
-- SEE. An internal note is a conversation between colleagues and
-- answers nobody, so it leaves the clock running -- which is right, and
-- is not what somebody who has just typed a long careful note expects.
--
-- ---------------------------------------------------------------------
-- What can leave the resolution clock running against nobody
--
-- `escalate_ticket` can hand a ticket to a person, and
-- `tickets.assignee_id` points at `auth.users` -- which is
-- platform-wide and carries no company, so NO FOREIGN KEY CAN HOLD
-- THIS ONE. It has to be asked, and it is: the person must be an
-- active member of this company.
--
-- Without that check the ticket goes to somebody at another company who
-- will never see it, because row level security keeps them out, while
-- its resolution clock runs on against a name that cannot answer. The
-- same check `assign_ticket` has always made, in the other function
-- that writes the same column.
--
-- ---------------------------------------------------------------------
-- And the one that does arithmetic on them
--
-- `transition_ticket` looks like a status setter and is the clock
-- itself. Moving into a waiting state PAUSES the resolution clock;
-- moving out of one adds the paused minutes back through
-- `app.sla_advance`, which counts them in working hours rather than
-- wall-clock, so a ticket parked on Friday evening is not three days
-- late on Monday. It refuses a move the state machine does not allow
-- and names the moves that were available instead.
-- =====================================================================

comment on function public.add_ticket_comment(uuid, text, boolean, app.ticket_channel) is
  'Adds a comment to a ticket and returns it. `p_internal` DEFAULTS TO '
  'TRUE, so a caller that says nothing writes a note the requester '
  'cannot see -- the safe default for a field somebody forgot, and the '
  'wrong one if the intention was to reply. It also decides the '
  'clock: the first-response time is stamped by the first comment the '
  'requester CAN see, so an internal note leaves that clock running '
  'however long and careful it was. A first public reply also files a '
  '`first_response` event, so the breach report can show when the '
  'promise was met. Needs the ticketing module.';

comment on function public.escalate_ticket(
  uuid, app.ticket_escalation, uuid, uuid, text) is
  'Raises the escalation level by one and moves the ticket to the team '
  'or the person it is going to, filing an event that records both '
  'levels and the reason. A functional escalation must name a team and '
  'a hierarchic one must name a person -- an escalation with nowhere '
  'to go is a level counter and nothing else. THE PERSON MUST BE AN '
  'ACTIVE MEMBER OF THIS COMPANY, checked here because '
  '`tickets.assignee_id` points at `auth.users`, which is '
  'platform-wide and carries no company, so no foreign key can hold '
  'it: escalating to somebody outside would hand the ticket to a name '
  'that row level security stops from ever seeing it, while the '
  'resolution clock ran on. A `new` ticket becomes `open` on the way '
  'past, because somebody has now looked at it. Needs the ticketing '
  'module.';

comment on function public.transition_ticket(uuid, app.ticket_status, text) is
  'Moves a ticket to another status, and IS THE SLA CLOCK rather than '
  'just a status setter. Moving into a waiting status pauses the '
  'resolution clock; moving out of one adds the paused minutes back '
  'through `app.sla_advance`, which counts in the company''s working '
  'hours rather than wall-clock -- so a ticket parked on Friday '
  'evening is not three days late on Monday. `resolved_at` and '
  '`closed_at` are stamped and CLEARED again by a move back, because a '
  'ticket that was reopened was not resolved. Refuses a move the state '
  'machine does not allow and names the ones that were available '
  'instead; moving to the status it is already in does nothing rather '
  'than failing. Needs the ticketing module.';
