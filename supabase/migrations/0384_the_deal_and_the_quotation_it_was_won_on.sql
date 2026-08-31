-- =====================================================================
-- iAkauntan :: 0384 the deal and the quotation it was won on
--
-- `opportunities.quotation_id` has carried its own comment since
-- `0008`:
--
--     -- Set when the deal is converted into a quotation/invoice
--
-- Nothing sets it. So the pipeline and the sales ledger are two
-- accounts of the same deal with nothing joining them: a deal is
-- marked won, somebody raises a quotation from the contact screen, and
-- the only thing tying the two together is that they were done in the
-- same afternoon by the same person.
--
-- ---------------------------------------------------------------------
-- The forecast is the thing that goes wrong
--
-- `opportunities.amount` is typed by whoever opened the deal, usually
-- early and usually round — sixty thousand, because that is the size of
-- the job. The quotation that goes out weeks later says 48,250, because
-- by then somebody has priced it.
--
-- Both figures then sit in the system. The weighted pipeline, the
-- forecast, and every "what is our quarter looking like" answer come
-- off `amount`; the invoice, the ledger and the cash come off the
-- quotation. Nothing compares them, so a pipeline can be twelve
-- thousand out on one deal and nobody finds out — the deal closes, the
-- invoice is right, the forecast was wrong, and the two facts never
-- meet.
--
-- `quote_opportunity` raises the quotation **from** the deal and takes
-- the deal's figure from it: one number, in one place, written once.
-- `report_pipeline_quote_mismatch` catches the ones where they have
-- since drifted apart, which is ordinary — a quote gets revised — and
-- is exactly the thing a sales manager wants to be told.
--
-- ---------------------------------------------------------------------
-- Winning on a quotation that expired
--
-- `0374` made a quotation's `valid_until` mean something: it will not
-- transfer to an order after it lapses, because the price was an offer
-- and the offer ran out. A deal marked won against a lapsed quotation
-- is the same mistake one screen earlier — the pipeline says the
-- customer accepted, and what they accepted cannot be turned into
-- anything.
--
-- So closing a deal as won, where a quotation is linked, checks it.
-- The way through is `extend_document_validity`, which `0374` added
-- for exactly this and which the message names.
--
-- What it does **not** do is refuse a won deal with no quotation at
-- all. Plenty of business is won on a phone call and invoiced
-- directly, and a CRM that will not record that is a CRM people keep
-- outside the system.
-- =====================================================================

-- ---------------------------------------------------------------------
-- What is already there
-- ---------------------------------------------------------------------
do $$
declare v_n integer;
begin
  select count(*) into v_n from public.opportunities
   where deleted_at is null and status = 'won' and quotation_id is null;
  if v_n > 0 then
    raise notice
      '0384: % won deal(s) name no quotation. Whether the pipeline '
      'figure matched what was actually sold cannot be answered for '
      'them.', v_n;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Raising the quotation from the deal
-- ---------------------------------------------------------------------
create or replace function public.quote_opportunity(
  p_opportunity uuid,
  p_valid_until date default null,
  p_description text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_o     public.opportunities;
  v_doc   uuid;
  v_no    text;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  select * into v_o from public.opportunities
   where id = p_opportunity and deleted_at is null;
  if v_o.id is null then
    raise exception 'No such opportunity.' using errcode = 'P0002';
  end if;
  if not app.can_write(v_o.org_id) then
    raise exception 'not permitted to raise a quotation'
      using errcode = '42501';
  end if;
  if v_o.contact_id is null then
    raise exception
      'A quotation goes to somebody. Name the customer on the deal '
      'first.' using errcode = '23502';
  end if;
  if v_o.quotation_id is not null then
    raise exception
      'This deal already has a quotation. Revise that one, or the '
      'pipeline ends up with two figures for one job.'
      using errcode = '23505';
  end if;
  if v_o.status <> 'open' then
    raise exception
      'This deal is already %. Quoting a closed deal is quoting for '
      'work nobody is waiting on.', v_o.status using errcode = '23514';
  end if;
  if coalesce(v_o.amount, 0) <= 0 then
    raise exception
      'The deal is worth nothing, so there is nothing to quote. Put the '
      'figure on the deal first.' using errcode = '23514';
  end if;
  if p_valid_until is not null and p_valid_until < v_today then
    raise exception 'A quotation cannot be valid until a day that has '
      'already passed.' using errcode = '23514';
  end if;

  v_no := public.next_document_number(v_o.org_id, 'quotation');

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, valid_until, notes, created_by)
  values (v_o.org_id, 'quotation', v_no, v_today, v_o.contact_id,
          coalesce(v_o.currency, app.base_currency(v_o.org_id)), 1,
          'draft',
          -- A quotation with no end is an offer that never runs out,
          -- which `0374` is the note on. Thirty days where nobody said.
          coalesce(p_valid_until, v_today + 30),
          v_o.name, auth.uid())
  returning id into v_doc;

  -- One line, at the deal's own figure. It is a starting point that
  -- somebody prices properly; what matters is that the deal and the
  -- document begin from the same number instead of two.
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_o.org_id, v_doc, 1,
          coalesce(nullif(btrim(coalesce(p_description, '')), ''), v_o.name),
          1, v_o.amount);

  update public.opportunities
     set quotation_id = v_doc, updated_at = now()
   where id = p_opportunity;

  return v_doc;
end $$;

-- ---------------------------------------------------------------------
-- Attaching one that already exists
-- ---------------------------------------------------------------------
create or replace function public.link_opportunity_quotation(
  p_opportunity uuid,
  p_document    uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_o public.opportunities;
  v_d public.sales_documents;
begin
  select * into v_o from public.opportunities
   where id = p_opportunity and deleted_at is null;
  if v_o.id is null then
    raise exception 'No such opportunity.' using errcode = 'P0002';
  end if;
  if not app.can_write(v_o.org_id) then
    raise exception 'not permitted to link a quotation'
      using errcode = '42501';
  end if;

  if p_document is null then
    update public.opportunities
       set quotation_id = null, updated_at = now() where id = p_opportunity;
    return;
  end if;

  select * into v_d from public.sales_documents where id = p_document;
  if v_d.id is null or v_d.org_id <> v_o.org_id then
    raise exception 'No such document.' using errcode = 'P0002';
  end if;
  if v_d.doc_type <> 'quotation' then
    raise exception
      'A deal is won on a quotation, not on a %. Link the quotation it '
      'came from.', v_d.doc_type using errcode = '22023';
  end if;
  if v_o.contact_id is not null and v_d.contact_id <> v_o.contact_id then
    raise exception
      'That quotation went to somebody else. A deal and its quotation '
      'name the same customer, or the pipeline is reporting one '
      'company''s business under another''s.' using errcode = '23514';
  end if;

  update public.opportunities
     set quotation_id = p_document,
         -- The document is the priced answer; the deal's figure was a
         -- guess. One number, and this is the one somebody worked out.
         amount = v_d.total_amount,
         updated_at = now()
   where id = p_opportunity;
end $$;

-- ---------------------------------------------------------------------
-- Won against a quotation that had run out
-- ---------------------------------------------------------------------
create or replace function app.opportunity_won_quote_guard()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_d     public.sales_documents;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  -- Judging the change: only the moment a deal is declared won. A deal
  -- already won stays editable, and a deal with no quotation is not
  -- this rule's business — plenty of work is won on a phone call.
  if new.status <> 'won' then return null; end if;
  if tg_op = 'UPDATE' and old.status = 'won' then return null; end if;
  if new.quotation_id is null then return null; end if;

  select * into v_d from public.sales_documents where id = new.quotation_id;
  if v_d.id is null then return null; end if;

  if v_d.status = 'void' then
    raise exception
      '% was voided. A deal cannot be won on a quotation that was '
      'withdrawn.', v_d.doc_no using errcode = '23514';
  end if;
  if v_d.valid_until is not null and v_d.valid_until < v_today then
    raise exception
      '% was only valid until %, so what the customer accepted cannot '
      'be turned into an order. Extend it first — '
      'extend_document_validity — and then close the deal.',
      v_d.doc_no, to_char(v_d.valid_until, 'DD Mon YYYY')
      using errcode = '23514';
  end if;
  return null;
end $$;

-- AFTER, not BEFORE, and the reason matters. `0009`'s `track_stage` is
-- a BEFORE trigger that derives `status` from the stage the deal was
-- moved into, and `close_opportunity` closes a deal by moving its
-- stage. A BEFORE trigger on the same row would run before or after
-- that one depending on nothing but their names, and half the time
-- would be looking at a status that had not been worked out yet. An
-- AFTER trigger sees the row as it will be stored, whatever else ran.
drop trigger if exists opportunities_won_quote_ck on public.opportunities;
create trigger opportunities_won_quote_ck
  after insert or update on public.opportunities
  for each row execute function app.opportunity_won_quote_guard();

-- ---------------------------------------------------------------------
-- Where the two figures have drifted apart
-- ---------------------------------------------------------------------
create or replace function public.report_pipeline_quote_mismatch(
  p_org uuid)
returns table (
  opportunity_id uuid,
  opportunity_no text,
  deal_name      text,
  contact_name   text,
  deal_amount    numeric,
  quoted_amount  numeric,
  difference     numeric,
  document_id    uuid,
  doc_no         text,
  doc_status     text)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select o.id, o.opportunity_no, o.name, c.name,
         o.amount, d.total_amount,
         round(d.total_amount - o.amount, 2),
         d.id, d.doc_no, d.status::text
    from public.opportunities o
    join public.sales_documents d on d.id = o.quotation_id
    left join public.contacts c on c.id = o.contact_id
   where o.org_id = p_org
     and app.can_read_module(p_org, 'crm')
     and o.deleted_at is null
     -- Open deals only. A closed one's figure is history, and
     -- rewriting history to agree with a document is not a fix.
     and o.status = 'open'
     and d.status <> 'void'
     and round(d.total_amount, 2) <> round(o.amount, 2)
   order by abs(d.total_amount - o.amount) desc;
$$;

-- ---------------------------------------------------------------------
revoke all on function
  public.quote_opportunity(uuid, date, text) from public, anon;
revoke all on function
  public.link_opportunity_quotation(uuid, uuid) from public, anon;
revoke all on function
  public.report_pipeline_quote_mismatch(uuid) from public, anon;

grant execute on function
  public.quote_opportunity(uuid, date, text) to authenticated;
grant execute on function
  public.link_opportunity_quotation(uuid, uuid) to authenticated;
grant execute on function
  public.report_pipeline_quote_mismatch(uuid) to authenticated;

comment on function public.quote_opportunity(uuid, date, text) is
  'Raises a quotation from a deal and links the two. '
  '`opportunities.quotation_id` carried a comment saying it was set '
  'when this happened and nothing set it, so the pipeline figure and '
  'what was actually quoted were two numbers that never met.';
comment on function app.opportunity_won_quote_guard() is
  'A deal won on a lapsed or voided quotation is the pipeline saying '
  'the customer accepted something that cannot be turned into an '
  'order. `0374` is the note on why a quotation runs out.';
comment on function public.report_pipeline_quote_mismatch(uuid) is
  'Open deals whose figure no longer matches the quotation they are '
  'attached to. Ordinary — a quote gets revised — and exactly what a '
  'forecast is silently wrong by.';
