-- =====================================================================
-- iAkauntan :: 0582 what happens if you run it twice
--
-- Twelfth slice of the undocumented writes: the eleven that do a lot at
-- once. Depreciation, recurring invoices and journals, rent, strata
-- charges, a pay period, a holiday calendar, an item import, a
-- conversion run.
--
-- Every one of these is called from a button somebody presses when they
-- are not sure whether they pressed it already, or from a scheduler
-- that may fire twice. So there is exactly one question worth
-- publishing about all of them, and it is the same question:
--
--     WHAT HAPPENS IF YOU RUN IT TWICE?
--
-- The answers are not the same, they are not guessable from the names,
-- and two of them are expensive.
--
-- ---------------------------------------------------------------------
-- The distinction worth the whole migration
--
-- `run_depreciation` is SELF-LIMITING. It works out what accumulated
-- depreciation each asset SHOULD stand at on the date, and charges the
-- difference. Run it twice on the same date and the difference is zero,
-- every asset is skipped, and it deletes its own empty run and returns
-- null. Running it again is free.
--
-- `raise_rent_invoices` and `raise_strata_charges` are NOT. Neither
-- looks for a run already covering the period. Call either twice and
-- every tenant in the building is invoiced twice, and the invoices are
-- POSTED, not drafted -- `post_sales_document_internal` runs on each
-- one before the loop moves on. There is no unique constraint standing
-- behind this and no refusal to catch it.
--
-- That is the single most expensive confusion available in this slice,
-- and the two families look identical from the outside: a verb, an
-- organization or a site, a date. Nothing said which was which.
--
-- The honest fix is a uniqueness rule on the run, and that is a change
-- rather than a comment. What can be done today is to say so where a
-- caller will read it, and that is what this does.
--
-- Comments only. No behaviour changes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Safe to repeat, and why each one is
-- ---------------------------------------------------------------------

comment on function public.run_depreciation(uuid, date) is
  'Charges depreciation on every active asset up to a date, posts one '
  'journal grouped by expense and accumulated account, and returns the '
  'run. SAFE TO RUN TWICE: it computes what each asset SHOULD stand at '
  'on the date and charges only the difference, so a second run on the '
  'same date charges nothing, deletes its own empty run and returns '
  'NULL. A null return is therefore "there was nothing to do", not a '
  'failure. Assets acquired after the date are skipped and one that '
  'reaches cost less residual is marked fully depreciated. Refuses when '
  'the chart has no 6400 or 1590 and the asset names no accounts of its '
  'own — a journal that cannot name both sides is not one to guess at. '
  'Needs `can_post`.';

comment on function public.add_fixed_public_holidays(uuid, integer) is
  'Adds the four fixed-date national holidays — Labour Day, National '
  'Day, Malaysia Day, Christmas — to a year''s calendar, and returns '
  'how many were actually added. SAFE TO RUN TWICE: a date already in '
  'the calendar is left alone, so a second call returns 0 rather than '
  'duplicating anything. Only the fixed four: Hari Raya, Deepavali, '
  'Chinese New Year and Wesak move with the lunar and Hindu calendars '
  'and are not computed here. State holidays are untouched — the guard '
  'looks only at rows with no state code. Needs `can_manage_hr`.';

comment on function public.ensure_pay_period(uuid, integer, integer) is
  'Returns the pay period for a month, creating it if it is not there. '
  'SAFE TO RUN TWICE and deliberately NOT a refresh: an existing period '
  'is returned untouched, because a run may already have been '
  'calculated against its pay date and moving that underneath would '
  'change every statutory figure the run computed. Changing the pay day '
  'in settings affects periods raised after it, not ones already '
  'raised. The pay date comes from `payroll_settings.pay_day`, where 0 '
  'means the last day of the month and any other day is capped at the '
  'month''s end — so the 29th is the 29th in January and the 28th in a '
  'February without one. Needs `can_run_payroll`.';

comment on function public.ensure_default_warehouse(uuid) is
  'Returns the company''s default store, creating one if it has none. '
  'Safe to run twice; it is a getter that happens to be able to write. '
  'Needs `can_write`.';

comment on function public.run_recurring_documents_for(uuid, date) is
  'Raises every recurring document due on or before a date for ONE '
  'company, and returns how many. Safe to run twice on the same day: '
  'raising a document advances its `next_run_date`, so the second call '
  'finds nothing due. A date in the past will raise every occurrence '
  'that was missed, which is the intended way to catch up and is not '
  'what you want if you were only re-running today. Needs `can_post`.';

comment on function public.run_recurring_journals_for(uuid, date) is
  'The same for recurring journals, one company, returning how many '
  'were advanced. Two things a caller will not expect. First, a '
  'template with `auto_post` OFF POSTS NOTHING but still has its '
  'schedule advanced — it is counted in the return and no entry exists. '
  'Second, a template that throws does not stop the others: the error '
  'is written to `last_error` on that row and the loop carries on, so a '
  'return of 9 out of 10 is silent, and `last_error_at` is the only '
  'place it shows. Deliberately not `app.run_recurring_journals`, which '
  'walks every organization in the database; a signed-in user may only '
  'post in their own. Needs `can_post`.';

comment on function public.import_items(uuid, jsonb, boolean) is
  'Loads items from a parsed file and returns a verdict per row. '
  '`p_commit` FALSE is a dry run — the default, so the accidental call '
  'is the harmless one — and true writes. Safe to run twice either way: '
  'a code that already exists in the company is reported as such rather '
  'than overwriting it, and a code repeated inside the file is caught '
  'on its second appearance, so an import is additive and never an '
  'update. Every row is checked against the reference tables the '
  'e-Invoice submission will later be validated against — unit of '
  'measure, MyInvois classification, currency — because a code MyInvois '
  'rejects is better found now than at submission. Needs `can_write`.';

-- ---------------------------------------------------------------------
-- NOT safe to repeat
-- ---------------------------------------------------------------------

comment on function public.raise_rent_invoices(uuid, date, date, date) is
  'Invoices every active tenancy at a site for a period, POSTS each '
  'invoice, and returns the run. NOT SAFE TO RUN TWICE: nothing looks '
  'for a run already covering this period, so a second call invoices '
  'every tenant a second time and posts those invoices too. Check '
  '`rent_runs` for the period before calling, and use '
  '`rent_preview` to see what would be raised. Refuses when no tenancy '
  'covers the period at all, which is the only accidental-call guard '
  'there is. The due date defaults to the start of the period. Needs '
  '`can_post` and the `property_nonstrata` module.';

comment on function public.raise_strata_charges(uuid, date, date, date) is
  'Charges every parcel in a scheme for a period — maintenance at the '
  'rate per share unit, plus the sinking fund contribution as a second '
  'line — POSTS each invoice, and returns the run. NOT SAFE TO RUN '
  'TWICE, exactly as `raise_rent_invoices`: nothing checks for an '
  'existing run over the period, and a second call bills every parcel '
  'again. Check `strata_charge_runs` first; `strata_charge_preview` '
  'shows what would be raised. Refuses outright when no rate is in '
  'force on the period start — an AGM resolution sets the rate before '
  'charges can be raised — and refuses when any parcel has no owner on '
  'record, rather than skipping it, because a parcel silently left out '
  'of a charge run is one nobody discovers until the fund is short. '
  'Needs `can_post` and the `property_strata` module.';

comment on function public.run_item_conversion(uuid, numeric, uuid) is
  'Cuts one item up into others — a carcass into cuts, a drum into '
  'bottles — moving stock out of the source and into the outputs, with '
  'the source''s cost split across them by `cost_share`. NOT '
  'IDEMPOTENT, and not meant to be: each call is a real conversion that '
  'really happened, so calling it twice converts twice. Refuses when '
  'there is not enough in the store, unless the company allows negative '
  'stock, and refuses when a batch-tracked source has less in traceable '
  'lots than the run would consume — the quantity and the lots can '
  'disagree, and the lots are what a recall follows. Needs '
  '`can_write_module(''inventory'')`.';

-- ---------------------------------------------------------------------
-- Replaces rather than adds
-- ---------------------------------------------------------------------

comment on function public.apply_statutory_leave_bands(uuid, text) is
  'Writes the Employment Act service bands onto a leave type — 8/12/16 '
  'days for annual, 14/18/22 for sick, by years of service — and '
  'switches the type to scale with service. DELETES EVERY EXISTING BAND '
  'FIRST: replaced wholesale rather than merged, because a band table '
  'with one row from the Act and two somebody typed is worse than '
  'either. Safe to run twice in that the result is the same both times, '
  'but hand-tuned bands do not survive the first call. The preset must '
  'be `annual` or `sick`. Needs `can_manage_hr`.';
