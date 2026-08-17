-- What the document editor needs to know, in one question.
--
-- `0167` put the gate on the table, which is right — it covers the
-- posting paths nobody has written yet. But a trigger only speaks when
-- it refuses, and a screen cannot build a button out of an exception.
-- Before the editor can offer "Send for approval" it has to know three
-- things about the document in front of it: whether a rule covers it,
-- whether it has already been cleared, and if neither, whose desk it is
-- sitting on.
--
-- `app.approval_required` and `app.is_approved` answer the first two,
-- and PostgREST cannot call either: only `public` is exposed, and the
-- guards deliberately live in `app`. Rather than move them — they are
-- called from triggers, where `app` is where they belong — this puts one
-- read-only function in `public` that answers all three at once. One
-- round trip per document, not three.
--
-- Purely a read. It writes nothing and decides nothing; the gate is
-- still the trigger.

create or replace function public.approval_state(
  p_kind app.approval_entity,
  p_entity_id uuid)
returns table (
  is_required   boolean,
  is_approved   boolean,
  request_id    uuid,
  request_status app.approval_status,
  awaiting_step smallint,
  -- Who the next signature is owed by, as a sentence rather than an id:
  -- "an admin", or a person's name. The editor shows it verbatim.
  awaiting_who  text,
  -- True when the signed-in user is the one holding it up, which is the
  -- difference between "waiting for approval" and "waiting for you".
  awaiting_me   boolean)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
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

  -- A document nobody may see is not a document that needs approving.
  -- Returning no row rather than raising: the editor asks this on every
  -- load, and an exception on a row the caller cannot read would turn a
  -- permission answer into an error banner.
  if v_org is null or not app.is_org_member(v_org) then
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
end $$;

revoke execute on function public.approval_state(app.approval_entity, uuid)
  from public, anon;
grant execute on function public.approval_state(app.approval_entity, uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- And the inbox needs to know which document it is looking at
--
-- `my_approvals` returned the kind but not the type, and the routes are
-- `/sales/:docType/:id` — so a row in the inbox knew it was a sales
-- document without knowing whether to open it as an invoice or a credit
-- note. `doc_no` was carrying the whole burden of identifying it, which
-- is a label, not an address.
--
-- The rest of the function is unchanged. It is repeated in full because
-- `create or replace function` cannot add an OUT parameter to an
-- existing signature otherwise.
-- ---------------------------------------------------------------------
drop function if exists public.my_approvals(uuid);

create or replace function public.my_approvals(p_org_id uuid)
returns table (
  request_id uuid,
  entity_kind app.approval_entity,
  entity_id uuid,
  doc_type text,
  doc_no text,
  amount numeric,
  step_no smallint,
  requested_at timestamptz,
  requested_by_name text)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  return query
    select q.id, q.entity_kind, q.entity_id,
           case q.entity_kind
             when 'sales_document' then
               (select d.doc_type::text from public.sales_documents d
                 where d.id = q.entity_id)
             when 'purchase_document' then
               (select d.doc_type::text from public.purchase_documents d
                 where d.id = q.entity_id)
             else 'manual'
           end,
           q.doc_no, q.amount,
           s.step_no, q.requested_at,
           coalesce(p.full_name, p.email)
      from public.approval_requests q
      join public.approval_steps s on s.request_id = q.id
      left join public.profiles p on p.id = q.requested_by
     where q.org_id = p_org_id
       and q.status = 'pending'
       and s.status = 'pending'
       -- The step in front, not any step of mine further down the chain.
       and s.step_no = (select min(s2.step_no) from public.approval_steps s2
                         where s2.request_id = q.id and s2.status = 'pending')
       and (s.approver_user_id = auth.uid()
            or (s.approver_user_id is null
                and app.has_org_role(p_org_id, array[s.approver_role])))
       -- Not my own, for the same reason `decide_approval` refuses it.
       and q.requested_by is distinct from auth.uid()
     order by q.requested_at;
end $$;

revoke execute on function public.my_approvals(uuid) from public, anon;
grant execute on function public.my_approvals(uuid) to authenticated;
