-- =====================================================================
-- iAkauntan :: 0587 what the people file remembers
--
-- Fourteenth slice of the undocumented writes: the nine that write into
-- somebody's employment record. A punch in and a punch out, a checklist
-- on their first day, a self review and the rating it ends in, a permit
-- renewed before it expires, a payroll run called paid, and a
-- verification withdrawn.
--
-- These share something the money functions do not. A wrong invoice can
-- be credited; a wrong entry in a person's record is read later, by
-- somebody deciding about them, with no sign that it was wrong. So
-- almost every refusal here exists to stop a record being written that
-- would MEAN something it should not.
--
-- ---------------------------------------------------------------------
-- The distinction worth the whole migration
--
-- `clock_in` upserts the wrong way round on purpose:
--
--     on conflict (employee_id, work_date) do update
--       set clock_in = coalesce(a.clock_in, excluded.clock_in)
--
-- The EARLIEST punch wins. Every other upsert in this schema takes the
-- newest value; this one keeps the oldest, because a second punch is
-- somebody tapping again at the door, not a correction — and a record
-- that took the later time would quietly make an on-time arrival late.
--
-- `clock_out` then recomputes the day but deliberately not the
-- lateness: clocking out does not make somebody late, and recomputing
-- everything would be the easy way to let it.
--
-- Neither is guessable from the names, and both decide what a
-- disciplinary conversation is later held about.
--
-- Comments only. No behaviour changes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The working day
-- ---------------------------------------------------------------------

comment on function public.clock_in(uuid, app.clock_method, numeric, numeric, text, text, text, uuid) is
  'Starts somebody''s working day and returns the attendance record. '
  'THE EARLIEST PUNCH WINS: a second clock-in on the same day does not '
  'overwrite the first, because tapping again at the door is not a '
  'correction and a record that took the later time would turn an '
  'on-time arrival into a late one. Lateness is worked out here, once, '
  'against the shift rostered for the day and after its grace period. '
  'No shift rostered means no lateness rather than lateness from '
  'midnight. Punching for somebody else needs `can_manage_hr` — it is '
  'an HR action and not a self-service one. The day is Kuala Lumpur''s, '
  'not the server''s.';

comment on function public.clock_out(uuid, app.clock_method, numeric, numeric, text, text, text, uuid) is
  'Closes the day and returns what it came to — worked, scheduled, '
  'overtime split into normal, rest day and holiday, and the lateness '
  'from the morning. RECOMPUTES THE DAY BUT NOT THE LATENESS: clocking '
  'out does not make somebody late, and recomputing everything would be '
  'the easy way to let it. Refuses when there is no clock-in today to '
  'close, rather than inventing one. Clocking out for somebody else '
  'needs `can_manage_hr`. Repeated calls move the clock-out later, '
  'unlike `clock_in` — the last time somebody left is the one that '
  'counts.';

-- ---------------------------------------------------------------------
-- Joining and leaving
-- ---------------------------------------------------------------------

comment on function public.start_onboarding(uuid, uuid, date, text) is
  'Raises an onboarding or offboarding checklist from a template and '
  'returns it, with each task dated from the start by the template''s '
  'own offsets. An onboarding starts on the HIRE DATE, usually in the '
  'future when somebody sets this up; an offboarding starts today. '
  'Refuses a second open checklist of the same kind for the same '
  'person, and refuses a template with no items in it — an empty '
  'checklist looks finished from every angle without anybody having '
  'done anything, which is the worst possible thing for a list of '
  'statutory tasks to look like. A template from another company is '
  'refused rather than ignored. Needs `can_manage_hr`.';

-- ---------------------------------------------------------------------
-- The appraisal, and the three things that stop a rating meaning
-- whatever the reader assumes
-- ---------------------------------------------------------------------

comment on function public.open_appraisal_cycle(uuid) is
  'Creates an appraisal for everybody the cycle covers and returns how '
  'many were made. Membership is decided at the PERIOD END, not today: '
  'somebody who left during the period is not appraised, somebody hired '
  'during it is, on the part of it they were here for. Idempotent — '
  'running it again after a new joiner adds only the missing ones, '
  'which is how a cycle opened early is topped up. Moves a draft cycle '
  'to self-review and leaves a cycle further along where it is. Refuses '
  'a completed cycle. Needs `can_manage_hr`.';

comment on function public.submit_self_appraisal(uuid, numeric, text) is
  'Writes the employee''s own half and moves the appraisal to the '
  'manager. ONLY THE PERSON BEING APPRAISED may call it — not their '
  'manager, not HR — because a self review written by somebody else is '
  'not one. Refuses a second submission and says to ask HR to reopen '
  'it, since the point of the record is what they said at the time. '
  'Refuses a rating with no comment: a number with nothing written '
  'beside it is one the manager has to guess the meaning of.';

comment on function public.finalise_appraisal(uuid, numeric, text) is
  'Settles the final rating and completes the appraisal. Three '
  'refusals, each about a rating meaning what it appears to mean. It '
  'will not finalise before THE MANAGER HAS WRITTEN THEIR HALF — a '
  'final rating over one half of a conversation is just the other half '
  'again. It will not finalise when the goal weights do not come to '
  '100, because the overall rating is a weighted judgement about them '
  'and weights that miss make it mean whatever the reader assumes. And '
  'DEPARTING FROM THE MANAGER''S RATING REQUIRES A NOTE: calibration is '
  'the act of departing, so departing without a word is the one thing '
  'it cannot be, and that difference is the only thing calibration '
  'leaves behind. Refuses an appraisal already completed. HR only.';

-- ---------------------------------------------------------------------
-- Papers that expire
-- ---------------------------------------------------------------------

comment on function public.renew_employee_document(uuid, date, date, text, text) is
  'Files the replacement for a permit, visa or certificate and returns '
  'it, carrying the type, title and notes across unless new ones are '
  'given, and linking it to what it supersedes. Refuses to renew a '
  'document THAT HAS ALREADY BEEN RENEWED — renew the one that replaced '
  'it, not the one it replaced — which is what stops a chain forking '
  'into two current permits. Refuses a renewal expiring on or before '
  'the document it replaces: that is a different document, and treating '
  'it as a renewal would retire the permit that is still the current '
  'one. The issue date defaults to the old expiry, so a chain has no '
  'gap in it. Needs `can_manage_hr`.';

-- ---------------------------------------------------------------------
-- Two that end something
-- ---------------------------------------------------------------------

comment on function public.mark_payroll_paid(uuid) is
  'Records that a posted payroll run has actually been paid out. MOVES '
  'NO MONEY and writes no journal — the posting did that; this is the '
  'note that the transfer left the bank, which is what a statutory '
  'remittance is later recorded against. Only from `posted`: a draft '
  'run marked paid would be a payment of figures that can still change. '
  'Needs `can_run_payroll`.';

comment on function public.unverify_person_identity(uuid) is
  'Withdraws the identity verification on a director, shareholder or '
  'officer — for a document found to be false, or a check done against '
  'the wrong person. Clears the DATE only; the table''s own check '
  'constraint clears the verifier with it, because a verifier with no '
  'date is the same broken record the other way round, and the rule '
  'belongs where every write passes rather than restated here where a '
  'direct UPDATE would miss it. Needs `can_write`, which is lighter '
  'than verifying: withdrawing a claim is the safe direction.';
