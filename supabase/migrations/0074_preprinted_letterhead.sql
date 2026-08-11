-- Companies that print onto their own letterhead paper.
--
-- Whether a business owns pre-printed stationery is a fact about the
-- business, not about one invoice, so it belongs beside the company's
-- other printing settings rather than in a menu on every download. When
-- it is on, the invoice and payslip PDFs leave the top of the first page
-- clear instead of drawing a second header onto paper that already has
-- one.
--
-- Default false: a company that has said nothing gets a PDF that is
-- complete on its own, which is the only safe assumption for a file that
-- will be e-mailed rather than printed.
--
-- The statutory identifiers are NOT controlled by this. A tax invoice has
-- to carry the registration and SST numbers under the Sales Tax Act, and
-- printed stationery routinely shows a name and address but not an SST
-- registration, so the client keeps printing them either way — smaller
-- and lower down when this is on.

alter table public.organizations
  add column if not exists uses_preprinted_letterhead boolean not null
    default false;

comment on column public.organizations.uses_preprinted_letterhead is
  'True when the company prints onto pre-printed letterhead paper: the '
  'generated invoice and payslip PDFs then reserve blank space at the top '
  'of the first page instead of drawing their own identity block. Never '
  'suppresses the statutory registration numbers.';
