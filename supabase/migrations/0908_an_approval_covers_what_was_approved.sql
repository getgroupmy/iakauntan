-- =====================================================================
-- iAkauntan :: 0908 an approval covers what was approved
--
-- `0167` made a document over a rule's amount wait for approval before
-- it posts, and `0646` before it is transferred. Both asked
-- `app.is_approved`, which asked one thing: is there an approved
-- request for this document? Not for how much, nor to whom. And the
-- steps of a request are built from the rules that match the amount
-- when it is SENT, so a bigger document skips the tiers above it.
--
-- Measured on 15 October 2026, locally, as the owner with the role
-- `authenticated`. Rules: RM5,000 and up needs a manager, RM100,000
-- and up a director as well. An invoice of RM6,000 was sent (one
-- step), approved by the manager, edited to RM600,000 and posted: 1210
-- took RM600,000 and the director was never asked. A request waiting
-- for a decision shows the approver the amount it was sent at, so the
-- same goes for an edit made while it waits.
--
-- And a second gap beside it. The rule screen labels its amount "RM",
-- but every reader compared it with `total_amount`, the document's
-- total in its OWN currency: an invoice of USD 2,000 at 4.4 -- RM8,800
-- -- posted under a RM5,000 rule without being sent at all.
--
-- Production on 15 October: one rule, two requests (one approved, one
-- waiting), both on ringgit bills unchanged since they were sent.
--
-- Answered "amount and party" and "compare in ringgit":
--
--   * `approval_requests.contact_id` records the customer or supplier
--     a document was sent for approval made out to;
--   * `app.approval_amount` is a document's total in the company's own
--     currency at the document's rate -- worked out, not read from
--     `base_total_amount`, which a change of rate on the header alone
--     does not recompute -- and a journal's debits as before;
--   * `app.is_approved` holds only while the document is for no more
--     than was approved and made out to the same party. A bigger total,
--     another rate or another party has to be sent again, and sending
--     it again builds the steps for what it is now;
--   * `submit_for_approval`, the posting gate, `approval_state` and
--     `transfer_document` read the amount in ringgit, and the gate says
--     what an approval that no longer covers the document was for.
--
-- Less is not more: a document that came DOWN after approval is still
-- covered. A request that goes stale while it waits can still be
-- approved; the approval then covers what was sent, and the document
-- asks to be sent again.
-- =====================================================================

alter table public.approval_requests
  add column contact_id uuid,
  add constraint approval_requests_contact_fk
    foreign key (org_id, contact_id)
    references public.contacts (org_id, id) on delete set null (contact_id);

comment on column public.approval_requests.contact_id is
  'The customer or supplier the document was made out to when it was '
  'sent for approval; null for a journal. An approval covers that party '
  'and no other. 0908.';

-- ---------------------------------------------------------------------
-- What an approval is about, in one place
-- ---------------------------------------------------------------------
create or replace function app.approval_amount(
  p_kind app.approval_entity,
  p_entity_id uuid)
returns numeric
-- NOT security definer: it reads as whoever asks, and every caller but
-- the posting gate is a definer already.
language sql stable
set search_path = public, pg_temp as $$
  select coalesce(case p_kind
    when 'sales_document' then
      (select round(d.total_amount * coalesce(d.exchange_rate, 1), 2)
         from public.sales_documents d where d.id = p_entity_id)
    when 'purchase_document' then
      (select round(d.total_amount * coalesce(d.exchange_rate, 1), 2)
         from public.purchase_documents d where d.id = p_entity_id)
    else
      (select sum(l.debit) from public.gl_lines l where l.entry_id = p_entity_id)
  end, 0);
$$;

create or replace function app.approval_party(
  p_kind app.approval_entity,
  p_entity_id uuid)
returns uuid
-- NOT security definer, for the same reason. The posting gate runs as
-- the caller and names the party in its refusal, so the caller needs
-- to be able to run it: `trigger_reachable_grants.sql`.
language sql stable
set search_path = public, pg_temp as $$
  select case p_kind
    when 'sales_document' then
      (select d.contact_id from public.sales_documents d where d.id = p_entity_id)
    when 'purchase_document' then
      (select d.contact_id from public.purchase_documents d where d.id = p_entity_id)
  end;
$$;

revoke all on function app.approval_amount(app.approval_entity, uuid) from public, anon, authenticated;
revoke all on function app.approval_party(app.approval_entity, uuid) from public, anon, authenticated;
grant execute on function app.approval_party(app.approval_entity, uuid) to authenticated, service_role;

comment on function app.approval_amount(app.approval_entity, uuid) is
  'What an approval rule and an approval are measured against: a sales or '
  'purchase document''s total in the company''s own currency at its rate, '
  'or a journal''s debits. 0908.';
comment on function app.approval_party(app.approval_entity, uuid) is
  'Who a sales or purchase document is made out to; null for a journal. '
  'An approval covers that party. 0908.';

-- ---------------------------------------------------------------------
-- The requests already made
--
-- Each was sent for its document's total in the document's currency
-- and made out to whoever it is made out to now -- there is nothing
-- else to read. Where the total is still what was sent, it is restated
-- in ringgit; where it has moved, the amount sent is kept, and the
-- document has to be sent again for more.
-- ---------------------------------------------------------------------
update public.approval_requests q
   set contact_id = d.contact_id,
       amount = case when d.total_amount = q.amount
                     then round(d.total_amount * coalesce(d.exchange_rate, 1), 2)
                     else q.amount end
  from public.sales_documents d
 where q.entity_kind = 'sales_document' and d.id = q.entity_id;

update public.approval_requests q
   set contact_id = d.contact_id,
       amount = case when d.total_amount = q.amount
                     then round(d.total_amount * coalesce(d.exchange_rate, 1), 2)
                     else q.amount end
  from public.purchase_documents d
 where q.entity_kind = 'purchase_document' and d.id = q.entity_id;

-- ---------------------------------------------------------------------
-- is_approved: for what it is now
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.is_approved(p_org_id uuid, p_kind app.approval_entity, p_entity_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1 from public.approval_requests q
     where q.org_id = p_org_id and q.entity_kind = p_kind
       and q.entity_id = p_entity_id and q.status = 'approved'
       -- 0908: for what it is now -- no more than was approved, in the
       -- company's own currency, and made out to the same party.
       and q.amount >= app.approval_amount(p_kind, p_entity_id)
       and q.contact_id is not distinct from app.approval_party(p_kind, p_entity_id));
$function$;

-- ---------------------------------------------------------------------
-- submit_for_approval: the amount in ringgit, and the party, recorded
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_for_approval(p_kind app.approval_entity, p_entity_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_org uuid; v_type text; v_amount numeric(18, 2); v_no text;
  v_request uuid; r record; v_steps integer := 0;
begin
  -- Resolve the thing being approved. Three tables, and this is the one
  -- place that has to know which.
  if p_kind = 'sales_document' then
    select d.org_id, d.doc_type::text, d.total_amount, d.doc_no
      into v_org, v_type, v_amount, v_no
      from public.sales_documents d where d.id = p_entity_id;
  elsif p_kind = 'purchase_document' then
    select d.org_id, d.doc_type::text, d.total_amount, d.doc_no
      into v_org, v_type, v_amount, v_no
      from public.purchase_documents d where d.id = p_entity_id;
  else
    select e.org_id, e.source::text,
           (select coalesce(sum(l.debit), 0) from public.gl_lines l
             where l.entry_id = e.id),
           e.entry_no
      into v_org, v_type, v_amount, v_no
      from public.gl_entries e where e.id = p_entity_id;
  end if;

  if v_org is null then
    raise exception 'No such document' using errcode = 'P0002';
  end if;
  -- 0908: in the company's own currency, which is what a rule's amount
  -- is in. Read once, here, and recorded on the request with the party.
  v_amount := app.approval_amount(p_kind, p_entity_id);
  if not app.can_write(v_org) then
    raise exception 'You may not submit this' using errcode = '42501';
  end if;
  if not app.approval_required(v_org, p_kind, v_type, v_amount) then
    raise exception
      'Nothing needs approving here — no rule covers a % of %.',
      p_kind, v_amount using errcode = '22023';
  end if;
  if app.is_approved(v_org, p_kind, p_entity_id) then
    raise exception 'This has already been approved' using errcode = '22023';
  end if;

  insert into public.approval_requests
    (org_id, entity_kind, entity_id, doc_no, amount, requested_by, contact_id)
  values (v_org, p_kind, p_entity_id, v_no, coalesce(v_amount, 0), auth.uid(),
          app.approval_party(p_kind, p_entity_id))
  returning id into v_request;

  -- A step per matching rule, in the order the rules give. Two rules on
  -- the same step number would be two approvers at one stage; the
  -- `unique (request_id, step_no)` above makes that a configuration
  -- error rather than a silent half-chain, and it is caught here rather
  -- than by whoever tries to approve it.
  for r in
    select distinct on (rl.step_no) rl.step_no, rl.approver_role,
           rl.approver_user_id
      from public.approval_rules rl
     where rl.org_id = v_org and rl.entity_kind = p_kind and rl.is_active
       and (rl.doc_type is null or rl.doc_type = v_type)
       and coalesce(v_amount, 0) >= rl.min_amount
     order by rl.step_no, rl.created_at
  loop
    insert into public.approval_steps
      (org_id, request_id, step_no, approver_role, approver_user_id)
    values (v_org, v_request, r.step_no, r.approver_role, r.approver_user_id);
    v_steps := v_steps + 1;
  end loop;

  if v_steps = 0 then
    raise exception 'No approver is configured for this' using errcode = 'P0002';
  end if;

  return v_request;
end $function$;

-- ---------------------------------------------------------------------
-- The posting gate: in ringgit, and saying what was approved
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.refuse_unapproved_posting()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_kind app.approval_entity;
  v_type text;
  v_amount numeric;
  -- 0908: what an approval that no longer covers it was for.
  v_was    public.approval_requests;
begin
  if tg_table_name = 'gl_entries' then
    -- Only journals somebody typed. Every other entry in this table is
    -- the by-product of a document that has its own gate above, and
    -- holding those up would stop an approved invoice posting itself.
    if new.source <> 'manual' then return new; end if;
    v_kind := 'journal';
    v_type := new.source::text;
    -- The journal's value, which only exists once its lines do. This is
    -- why the trigger on `gl_entries` is deferred to commit and the
    -- other two are not: a rule reading "journals over ten thousand"
    -- cannot be evaluated at INSERT, when the entry has no lines yet and
    -- every journal would look like nothing.
    select coalesce(sum(l.debit), 0) into v_amount
      from public.gl_lines l where l.entry_id = new.id;
  else
    -- Only the transition into posted. An already-posted row being
    -- touched for any other reason is not a posting.
    if new.status <> 'posted' or coalesce(old.status, 'draft') = 'posted' then
      return new;
    end if;
    v_kind := case when tg_table_name = 'sales_documents'
                   then 'sales_document' else 'purchase_document' end;
    v_type := new.doc_type::text;
    -- 0908: in the company's own currency, at the document's rate.
    v_amount := round(new.total_amount * coalesce(new.exchange_rate, 1), 2);
  end if;

  if app.approval_required(new.org_id, v_kind, v_type, v_amount)
     and not app.is_approved(new.org_id, v_kind, new.id) then
    -- 0908: approved, but for something else. Say what, so the answer
    -- is "send it again" and not "it says approved".
    select q.* into v_was
      from public.approval_requests q
     where q.org_id = new.org_id and q.entity_kind = v_kind
       and q.entity_id = new.id and q.status = 'approved'
     order by q.decided_at desc nulls last, q.requested_at desc
     limit 1;
    if v_was.id is not null then
      raise exception
        '% was approved at % for %, and is now % for %. An approval covers '
        'what was approved: send it for approval again.',
        coalesce(v_was.doc_no, 'This'), v_was.amount,
        coalesce((select c.name from public.contacts c where c.id = v_was.contact_id), 'no one'),
        v_amount,
        coalesce((select c.name from public.contacts c
                   where c.id = app.approval_party(v_kind, new.id)), 'no one')
        using errcode = '42501';
    end if;
    raise exception
      'This needs approving before it can be posted. Send it for approval '
      'first.' using errcode = '42501';
  end if;

  return new;
end $function$;

-- ---------------------------------------------------------------------
-- approval_state and transfer_document: in ringgit
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.approval_state(p_kind app.approval_entity, p_entity_id uuid)
 RETURNS TABLE(is_required boolean, is_approved boolean, request_id uuid, request_status app.approval_status, awaiting_step smallint, awaiting_who text, awaiting_me boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_org uuid;
  v_type text;
  v_amount numeric;
begin
  if p_kind = 'sales_document' then
    select d.org_id, d.doc_type::text, d.total_amount
      into v_org, v_type, v_amount
      from public.sales_documents d where d.id = p_entity_id;
  elsif p_kind = 'purchase_document' then
    select d.org_id, d.doc_type::text, d.total_amount
      into v_org, v_type, v_amount
      from public.purchase_documents d where d.id = p_entity_id;
  else
    select e.org_id, e.source::text,
           (select coalesce(sum(l.debit), 0) from public.gl_lines l
             where l.entry_id = e.id)
      into v_org, v_type, v_amount
      from public.gl_entries e where e.id = p_entity_id;
  end if;

  -- 0908: in the company's own currency, as the gate reads it.
  v_amount := app.approval_amount(p_kind, p_entity_id);

  -- A document nobody may see is not a document that needs approving.
  -- Returning no row rather than raising: the editor asks this on every
  -- load, and an exception on a row the caller cannot read would turn a
  -- permission answer into an error banner.
  if v_org is null or not app.is_staff_member(v_org) then
    return;
  end if;

  return query
    select
      app.approval_required(v_org, p_kind, v_type, v_amount),
      app.is_approved(v_org, p_kind, p_entity_id),
      q.id,
      q.status,
      s.step_no,
      coalesce(
        (select coalesce(pr.full_name, pr.email) from public.profiles pr
          where pr.id = s.approver_user_id),
        case when s.approver_role is null then null
             else 'an ' || replace(s.approver_role::text, '_', ' ') end),
      coalesce(s.approver_user_id = auth.uid()
               or (s.approver_user_id is null
                   and app.has_org_role(v_org, array[s.approver_role])),
               false)
        -- Nobody signs their own, so it is never waiting on the raiser
        -- even when they hold the role. `decide_approval` refuses it and
        -- `my_approvals` hides it; a button that offered it here would
        -- be a button that fails.
        and q.requested_by is distinct from auth.uid()
      from (select 1) one
      left join public.approval_requests q
        on q.org_id = v_org and q.entity_kind = p_kind
       and q.entity_id = p_entity_id and q.status = 'pending'
      left join lateral (
        select s2.* from public.approval_steps s2
         where s2.request_id = q.id and s2.status = 'pending'
         order by s2.step_no limit 1) s on true;
end $function$;

CREATE OR REPLACE FUNCTION public.transfer_document(p_source_id uuid, p_target_type text, p_lines jsonb DEFAULT NULL::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_sales      public.sales_documents;
  v_purchase   public.purchase_documents;
  v_is_sales   boolean;
  v_org        uuid;
  v_source_type text;
  v_counter    text;
  v_new_id     uuid;
  v_doc_no     text;
  v_due        date;
  v_term_id    uuid;
  v_term_days  integer;
  v_no         integer := 0;
  v_want       numeric(18, 4);
  v_left       numeric(18, 4);
  v_share      numeric(18, 8);
  v_src_net    numeric(18, 2);
  v_new_net    numeric(18, 2);
  -- 0646. What an approval rule would be about, if one covered this.
  v_kind       app.approval_entity;
  v_amount     numeric(18, 2);
  -- 0478. Who the new document is made out to, and their rows.
  v_holder     public.contacts;
  v_contact    uuid;
  v_person     uuid;
  v_address    uuid;
  r            record;
begin
  select * into v_sales from public.sales_documents where id = p_source_id;
  v_is_sales := found;

  if v_is_sales then
    v_org := v_sales.org_id;
    v_source_type := v_sales.doc_type::text;
    if v_sales.deleted_at is not null or v_sales.status = 'void' then
      raise exception 'Document % has been voided', v_sales.doc_no
        using errcode = '23514';
    end if;
  else
    select * into v_purchase from public.purchase_documents where id = p_source_id;
    if not found then
      raise exception 'Document % not found', p_source_id using errcode = 'P0002';
    end if;
    v_org := v_purchase.org_id;
    v_source_type := v_purchase.doc_type::text;
    if v_purchase.deleted_at is not null or v_purchase.status = 'void' then
      raise exception 'Document % has been voided', v_purchase.doc_no
        using errcode = '23514';
    end if;
  end if;

  if not app.can_write(v_org) then
    raise exception 'Insufficient privileges to transfer' using errcode = '42501';
  end if;
  perform app.require_side(v_org, case when v_is_sales then 'sales' else 'purchases' end);

  -- 0646. An approval rule that nothing consulted.
  --
  -- `app.refuse_unapproved_posting` is the only place an approval
  -- decision was ever read, and it fires on the transition into
  -- `posted`. SEVEN of the fifteen document types never post --
  -- quotation, proforma, sales order, delivery order, purchase
  -- requisition, purchase order, purchase return -- and the rule
  -- editor offers every one of them. So a company could set "purchase
  -- orders over ten thousand need the owner", save it, watch it appear
  -- in the list, submit an order for approval, have somebody approve
  -- it -- and the answer was written to a table nothing asked.
  --
  -- The transfer is where a document that does not post becomes an
  -- act: a requisition becomes an order, an order becomes goods
  -- received, a quotation becomes a sale. So the decision is read here
  -- too, with the same two functions the posting trigger uses, and a
  -- rule means the same thing whichever kind of document carries it.
  --
  -- On the SOURCE, not the target. The thing being authorised is
  -- acting on this document; a requisition is approved and then
  -- becomes an order, which is the order procurement is done in
  -- everywhere. The target gets its own gate at posting if it posts.
  --
  -- It inherits `app.approval_required`'s fail-open on the module, for
  -- the reason `approvals.sql` sets out at length: a company whose
  -- add-on lapsed must not be left holding documents it cannot move
  -- and no screen to release them.
  v_kind := case when v_is_sales then 'sales_document'
                 else 'purchase_document' end;
  -- 0908: in the company's own currency, as the posting gate reads it.
  v_amount := app.approval_amount(v_kind, p_source_id);
  if app.approval_required(v_org, v_kind, v_source_type, v_amount)
     and not app.is_approved(v_org, v_kind, p_source_id) then
    raise exception
      '% needs approving before it can be turned into a %. Send it for '
      'approval first.',
      case when v_is_sales then v_sales.doc_no else v_purchase.doc_no end,
      replace(p_target_type, '_', ' ')
      using errcode = '42501';
  end if;

  -- 0374. A price that ran out. A quotation and a proforma are both
  -- offers with a date on them, and turning one into an order or an
  -- invoice after that date charges last quarter's price for this
  -- quarter's work — quietly, because every downstream figure agrees
  -- with it. Refused rather than warned: honouring an expired quote is
  -- a decision somebody makes, and `extend_document_validity` is where
  -- they make it and where it is recorded.
  if v_is_sales
     and v_sales.doc_type in ('quotation', 'proforma')
     and v_sales.valid_until is not null
     and v_sales.valid_until < app.today() then
    raise exception
      '% was only valid until %. Extend it, or raise a new one at '
      'today''s prices.', v_sales.doc_no, to_char(v_sales.valid_until, 'DD Mon YYYY')
      using errcode = '23514';
  end if;

  -- Raises on a transition that is not part of either cycle.
  v_counter := app.transfer_counter(v_source_type, p_target_type);

  -- 0478. The offer was made to a prospect; the sale is the customer
  -- record's. Resolved before anything is written.
  if v_is_sales then
    v_contact := v_sales.contact_id;
    v_person  := v_sales.contact_person_id;
    v_address := v_sales.shipping_address_id;

    select * into v_holder from public.contacts where id = v_sales.contact_id;
    if v_holder.contact_type = 'prospect' then
      v_contact := app.customer_record_of(v_sales.contact_id);
      if v_contact is null then
        raise exception
          '% is a prospect. Create a Customer record for them first; '
          'the % is then made out to it.',
          v_holder.name,
          replace(p_target_type, '_', ' ')
          using errcode = '23514',
                hint = 'Open the prospect, then Records, then '
                       '"Create a Customer record".';
      end if;

      -- The same person and the same door, on the customer record's
      -- own rows; empty where there is no such row, never the
      -- prospect's.
      select p2.id into v_person
        from public.contact_persons p1
        join public.contact_persons p2
          on p2.contact_id = v_contact
         and p2.name = p1.name
         and coalesce(p2.email, '') = coalesce(p1.email, '')
       where p1.id = v_sales.contact_person_id
       order by p2.is_primary desc, p2.created_at
       limit 1;
      if not found then v_person := null; end if;

      select a2.id into v_address
        from public.contact_addresses a1
        join public.contact_addresses a2
          on a2.contact_id = v_contact
         and a2.label = a1.label
         and coalesce(a2.address_line1, '') = coalesce(a1.address_line1, '')
         and coalesce(a2.postcode, '') = coalesce(a1.postcode, '')
       where a1.id = v_sales.shipping_address_id
       order by a2.is_default desc, a2.created_at
       limit 1;
      if not found then v_address := null; end if;
    end if;
  end if;

  v_doc_no := app.next_document_number_internal(v_org, p_target_type);

  -- A document that will be settled needs a due date; ageing is built on
  -- it and a null there quietly parks the debt in "not yet due" forever.
  if p_target_type in ('invoice', 'bill') then
    v_term_id := case when v_is_sales then v_sales.payment_term_id
                      else v_purchase.payment_term_id end;
    if v_term_id is not null then
      select days into v_term_days from public.payment_terms where id = v_term_id;
    end if;
    v_due := app.today() + coalesce(v_term_days, 30);
  end if;

  if v_is_sales then
    insert into public.sales_documents (
      org_id, doc_type, doc_no, doc_date, due_date, contact_id,
      contact_person_id, shipping_address_id, reference, subject, parent_id,
      payment_term_id, currency, exchange_rate, salesperson_id,
      opportunity_id, matter_id, branch_id, notes, terms_conditions, status,
      created_by, delivery_date
    ) values (
      v_org, p_target_type::app.sales_doc_type, v_doc_no, app.today(), v_due,
      v_contact, v_person, v_address,
      v_sales.reference, v_sales.subject, v_sales.id,
      v_sales.payment_term_id, v_sales.currency, v_sales.exchange_rate,
      v_sales.salesperson_id, v_sales.opportunity_id, v_sales.matter_id,
      -- Which branch quoted it is which branch invoices it. An amount
      -- can be split across two invoices; a branch cannot, so this
      -- carries whole.
      v_sales.branch_id,
      v_sales.notes, v_sales.terms_conditions, 'draft', auth.uid(),
      -- 0374. The date promised on the quotation is the date promised on
      -- the order, and on the delivery order raised from it. Dropping it
      -- at each step is how a promise becomes nobody's.
      case when p_target_type in ('sales_order', 'delivery_order')
           then v_sales.delivery_date end
    ) returning id into v_new_id;

    for r in
      select l.*,
             (select (e ->> 'quantity')::numeric
                from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e
               where (e ->> 'line_id')::uuid = l.id) as asked
        from public.sales_document_lines l
       where l.document_id = p_source_id
       order by l.line_no
    loop
      v_left := r.quantity - case v_counter
        when 'quantity_invoiced' then r.quantity_invoiced
        else r.quantity_fulfilled end;

      v_want := case when p_lines is null then greatest(v_left, 0)
                     else coalesce(r.asked, 0) end;
      if v_want <= 0 then continue; end if;

      if v_want > v_left then
        raise exception
          'Line % has % outstanding; % was asked for.',
          r.line_no, v_left, v_want using errcode = '23514';
      end if;

      v_no := v_no + 1;
      insert into public.sales_document_lines (
        org_id, document_id, line_no, line_type, item_id, description,
        classification_code, quantity, uom_code, unit_price, discount_percent,
        discount_amount, tax_code_id, tax_rate, is_tax_inclusive, warehouse_id,
        account_id, project_code, department_code, source_line_id,
        service_start, service_end
      ) values (
        v_org, v_new_id, v_no, r.line_type, r.item_id, r.description,
        r.classification_code, v_want, r.uom_code, r.unit_price,
        r.discount_percent,
        -- A cash discount is proportional to what is being taken, not
        -- carried whole onto a partial transfer.
        case when r.quantity = 0 then 0
             else round(r.discount_amount * v_want / r.quantity, 2) end,
        r.tax_code_id, r.tax_rate, r.is_tax_inclusive, r.warehouse_id,
        r.account_id, r.project_code, r.department_code, r.id,
        -- The period is a property of what was sold, not of the piece of
        -- paper it was first written on. Dropping it here would let a
        -- quoted twelve-month contract arrive at the invoice as income
        -- earned on the day, and nobody would see it go.
        r.service_start, r.service_end
      );
    end loop;

    -- The header amounts, on the same rule the line above states:
    -- proportional to what is being taken, not carried whole onto a
    -- partial transfer and not dropped on a whole one.
    --
    -- Before this they were not carried at all, so a quotation for
    -- RM1000 of goods with RM50 delivery and RM100 off the job was
    -- invoiced at RM1080 against RM1030 quoted: the customer was billed
    -- fifty ringgit more than the price they had agreed, because the
    -- discount went and the delivery went with it.
    --
    -- The share is measured on line value rather than on quantity,
    -- because two lines at different prices are not two equal halves of
    -- a delivery charge. It is taken against the *source's* total and
    -- not against what is left, so two half-transfers add back to one
    -- whole -- exactly the property the line-level proration has.
    v_src_net := coalesce(v_sales.subtotal, 0);
    select coalesce(subtotal, 0) into v_new_net
      from public.sales_documents where id = v_new_id;

    v_share := case
      -- A document whose lines come to nothing but which carries a
      -- delivery charge. There is no value to apportion by, so the
      -- only defensible answers are all of it on a whole transfer and
      -- none of it on a partial one.
      when v_src_net = 0 then case when p_lines is null then 1 else 0 end
      else v_new_net / v_src_net
    end;

    update public.sales_documents d
       set shipping_amount = round(coalesce(v_sales.shipping_amount, 0) * v_share, 2),
           discount_amount = round(coalesce(v_sales.discount_amount, 0) * v_share, 2),
           service_charge_amount =
             round(coalesce(v_sales.service_charge_amount, 0) * v_share, 2)
     where d.id = v_new_id;

    -- And then let the arithmetic be done by the one function that owns
    -- it. `app.recalc_sales_totals` is a trigger on the *lines*, so a
    -- header amount written after the last line is in the row and not
    -- in the total -- which is how the figures above came to disagree
    -- with each other in the first place. Touching a line re-runs it
    -- over the header this function has just finished writing.
    --
    -- Rather than either of the alternatives: computing the share
    -- before the header insert would mean writing the `v_want`
    -- expression a second time, where the two copies can drift apart
    -- silently; and setting `total_amount` here by hand would put this
    -- function in the business of arithmetic that belongs somewhere
    -- else, on a draft somebody is still going to edit.
    update public.sales_document_lines
       set line_no = line_no where document_id = v_new_id;
  else
    insert into public.purchase_documents (
      org_id, doc_type, doc_no, doc_date, due_date, contact_id,
      contact_person_id, reference, parent_id, payment_term_id,
      currency, exchange_rate, branch_id, notes, status, created_by
    ) values (
      v_org, p_target_type::app.purchase_doc_type, v_doc_no, app.today(), v_due,
      v_purchase.contact_id, v_purchase.contact_person_id,
      v_purchase.reference, v_purchase.id, v_purchase.payment_term_id,
      v_purchase.currency, v_purchase.exchange_rate, v_purchase.branch_id,
      v_purchase.notes, 'draft', auth.uid()
    ) returning id into v_new_id;

    for r in
      select l.*,
             (select (e ->> 'quantity')::numeric
                from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e
               where (e ->> 'line_id')::uuid = l.id) as asked
        from public.purchase_document_lines l
       where l.document_id = p_source_id
       order by l.line_no
    loop
      -- 0903. On a purchase order a goods received note and a bill
      -- raised straight from the order each receive the goods, so the
      -- two draw on the one quantity. Goods received on a note are
      -- billed from the note, which clears what it accrued.
      v_left := r.quantity - case
        when v_source_type = 'purchase_order'
          then r.quantity_received + r.quantity_billed
        when v_counter = 'quantity_billed' then r.quantity_billed
        else r.quantity_received end;

      v_want := case when p_lines is null then greatest(v_left, 0)
                     else coalesce(r.asked, 0) end;
      if v_want <= 0 then continue; end if;

      if v_want > v_left then
        raise exception
          'Line % has % outstanding; % was asked for.',
          r.line_no, v_left, v_want using errcode = '23514';
      end if;

      v_no := v_no + 1;
      insert into public.purchase_document_lines (
        org_id, document_id, line_no, line_type, item_id, description,
        classification_code, quantity, uom_code, unit_price, discount_percent,
        discount_amount, tax_code_id, tax_rate, is_tax_inclusive, warehouse_id,
        account_id, project_code, department_code, source_line_id
      ) values (
        v_org, v_new_id, v_no, r.line_type, r.item_id, r.description,
        r.classification_code, v_want, r.uom_code, r.unit_price,
        r.discount_percent,
        case when r.quantity = 0 then 0
             else round(r.discount_amount * v_want / r.quantity, 2) end,
        r.tax_code_id, r.tax_rate, r.is_tax_inclusive, r.warehouse_id,
        r.account_id, r.project_code, r.department_code, r.id
      );
    end loop;

    -- The same on the buying side. A purchase order with carriage on it
    -- part-received and part-billed would otherwise be billed for the
    -- goods and never for the carriage. There is no service charge on a
    -- purchase document: a supplier's is a line on their bill.
    v_src_net := coalesce(v_purchase.subtotal, 0);
    select coalesce(subtotal, 0) into v_new_net
      from public.purchase_documents where id = v_new_id;

    v_share := case
      when v_src_net = 0 then case when p_lines is null then 1 else 0 end
      else v_new_net / v_src_net
    end;

    update public.purchase_documents d
       set shipping_amount = round(coalesce(v_purchase.shipping_amount, 0) * v_share, 2),
           discount_amount = round(coalesce(v_purchase.discount_amount, 0) * v_share, 2)
     where d.id = v_new_id;

    -- The same touch, for the same reason.
    update public.purchase_document_lines
       set line_no = line_no where document_id = v_new_id;
  end if;

  if v_no = 0 then
    -- 0903. Where the other road took it, say which, and where to go.
    if not v_is_sales and v_source_type = 'purchase_order'
       and p_lines is null
       and exists (select 1 from public.purchase_document_lines l
                    where l.document_id = p_source_id
                      and case p_target_type when 'bill' then l.quantity_received
                                             else l.quantity_billed end > 0) then
      raise exception '%', case p_target_type
        when 'bill' then format(
          '%s has been received on a goods received note. Bill it from '
          'the note, which clears what the note accrued.', v_purchase.doc_no)
        else format(
          '%s has been billed straight from the order, and that bill '
          'received the goods.', v_purchase.doc_no) end
        using errcode = '23514';
    end if;
    -- Nothing was left to take. The empty document is rolled back rather
    -- than left behind, because a stray zero-line draft in the numbering
    -- sequence is a document somebody has to explain later.
    raise exception
      'Nothing left to transfer — every line has already been taken forward.'
      using errcode = '23514';
  end if;

  return v_new_id;
end;
$function$;

comment on function app.is_approved(uuid, app.approval_entity, uuid) is
  'True while an approved request covers the document as it is now: for '
  'no less than its total in the company''s own currency, and made out to '
  'the same party. The posting gate, the transfer, the editor''s state and '
  'a second submission all ask this. 0167, 0908.';
