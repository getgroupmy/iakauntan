-- A till with no signal, and a sale that lands exactly once.
--
-- ## What actually goes wrong
--
-- Not the selling. A device can hold a basket, price it and take cash
-- with no network at all. What goes wrong is the SENDING: the request
-- times out, the device does not know whether the server got it, and it
-- sends again. Without an answer to that, a shop's takings are somewhere
-- between right and double.
--
-- 0208 put `client_uuid` on the sale for this, generated on the device
-- before it tries. This migration is the other half: a function that
-- takes a whole finished sale in one payload and is safe to call twice.
-- The second call does not create anything and does not error -- it
-- returns the sale that already landed and says so, because an error is
-- something a device retries and a plain answer is something it can
-- stop retrying.
--
-- ## The prices come from the device
--
-- The till charged what it charged. If the price list changed while the
-- device was offline, re-pricing on the way in would put a different
-- number in the books from the one on the customer's receipt. The
-- payload carries the price and it is used as given.
--
-- ## A closed drawer stays closed
--
-- If the shift the sale belongs to has been counted and closed, the
-- sale is REFUSED rather than added. `close_pos_shift` computed a
-- variance from what was in the drawer at that moment; a cash sale
-- landing afterwards makes that figure a lie about a count somebody
-- signed for. The payload is kept in `pos_offline_rejects` so a
-- manager can deal with it -- nothing is dropped, it is parked.
--
-- ## One bad payload does not lose the good ones
--
-- A device coming back online sends everything it has. Each payload
-- lands in its own subtransaction, so a sale referring to an item
-- somebody deleted yesterday is rejected on its own and the other
-- eleven still land.

alter table public.pos_sales
  add column if not exists offline_sold_at timestamptz;

comment on column public.pos_sales.offline_sold_at is
  'When the device says the sale happened, which is not when the server heard about it. Both are true and both are kept.';

-- ---------------------------------------------------------------------
-- What could not land
-- ---------------------------------------------------------------------
--
-- Kept rather than dropped. A payload that fails is money somebody took
-- across a counter, and the only thing worse than failing to record it
-- is failing to record that it failed.
create table if not exists public.pos_offline_rejects (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  register_id uuid references public.pos_registers (id) on delete set null,
  client_uuid uuid,
  payload     jsonb not null,
  error_code  text,
  message     text,
  resolved_at timestamptz,
  created_at  timestamptz not null default now()
);

create index if not exists pos_offline_rejects_open_idx
  on public.pos_offline_rejects (org_id, created_at desc) where resolved_at is null;
-- One row per payload that failed, not one per attempt: a device that
-- retries a doomed sale twelve times should not fill the screen with
-- twelve identical problems.
create unique index if not exists pos_offline_rejects_one_per_client
  on public.pos_offline_rejects (org_id, client_uuid) where client_uuid is not null;

-- ---------------------------------------------------------------------
-- Writing down what failed
-- ---------------------------------------------------------------------
--
-- Its own function for the reason `pos_consolidation_absorb` is: the
-- caller returns a column called `client_uuid`, the table has a column
-- called `client_uuid`, and an ON CONFLICT clause carries an index
-- predicate that cannot be qualified with an alias. Moving the write
-- somewhere no parameter is named after a column removes the question
-- rather than answering it.
create or replace function app.pos_record_reject(
  p_org      uuid,
  p_register uuid,
  p_client   uuid,
  p_payload  jsonb,
  p_state    text,
  p_message  text)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
begin
  insert into public.pos_offline_rejects
    (org_id, register_id, client_uuid, payload, error_code, message)
  values (p_org, p_register, p_client, p_payload, p_state, p_message)
  on conflict (org_id, client_uuid) where client_uuid is not null
    do update set payload = excluded.payload,
                  error_code = excluded.error_code,
                  message = excluded.message,
                  created_at = now(),
                  resolved_at = null;
end;
$$;

revoke all on function app.pos_record_reject(uuid, uuid, uuid, jsonb, text, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Landing one sale
-- ---------------------------------------------------------------------
create or replace function app.land_offline_sale(
  p_register uuid,
  p_payload  jsonb)
returns table (sale_id uuid, invoice_no text, landed boolean)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_reg    public.pos_registers;
  v_client uuid := nullif(p_payload ->> 'client_uuid', '')::uuid;
  v_sale   uuid;
  v_status app.pos_sale_status;
  v_line   jsonb;
  v_mod    jsonb;
  v_lid    uuid;
  v_done   record;
begin
  select * into v_reg from public.pos_registers where id = p_register;
  if v_reg.id is null then
    raise exception 'No such register.' using errcode = 'P0002';
  end if;
  if v_client is null then
    raise exception
      'An offline sale needs the id the device gave it, or there is no '
      'way to tell a retry from a second sale.'
      using errcode = '23502';
  end if;

  -- Already here. Not an error: a device that gets an error retries,
  -- and this is precisely the case where it should stop.
  select s.id, s.status into v_sale, v_status
    from public.pos_sales s
   where s.org_id = v_reg.org_id and s.client_uuid = v_client;
  if v_sale is not null and v_status = 'completed' then
    sale_id := v_sale;
    select d.doc_no into invoice_no from public.sales_documents d
      join public.pos_sales s on s.invoice_id = d.id where s.id = v_sale;
    landed := false;
    return next;
    return;
  end if;

  -- `open_pos_sale` carries the same idempotency and insists on an open
  -- shift, which is the refusal a counted drawer needs.
  v_sale := public.open_pos_sale(
    p_register,
    nullif(p_payload ->> 'contact_id', '')::uuid,
    v_client);

  update public.pos_sales s
     set offline_sold_at = nullif(p_payload ->> 'sold_at', '')::timestamptz,
         table_id = nullif(p_payload ->> 'table_id', '')::uuid,
         covers = nullif(p_payload ->> 'covers', '')::integer,
         note = nullif(p_payload ->> 'note', '')
   where s.id = v_sale;

  for v_line in select e from jsonb_array_elements(coalesce(p_payload -> 'lines', '[]'::jsonb)) e
  loop
    v_lid := public.add_pos_sale_line(
      v_sale,
      (v_line ->> 'item_id')::uuid,
      coalesce((v_line ->> 'quantity')::numeric, 1),
      -- As charged. See the header: the till's price is the one on the
      -- customer's receipt.
      (v_line ->> 'unit_price')::numeric,
      coalesce((v_line ->> 'discount')::numeric, 0),
      v_line ->> 'note');

    for v_mod in select e from jsonb_array_elements(coalesce(v_line -> 'modifiers', '[]'::jsonb)) e
    loop
      perform public.add_line_modifier(
        v_lid,
        (v_mod ->> 'modifier_id')::uuid,
        coalesce((v_mod ->> 'quantity')::integer, 1));
    end loop;
  end loop;

  select r.sale_id, r.invoice_no into v_done
    from public.complete_pos_sale(v_sale, coalesce(p_payload -> 'tenders', '[]'::jsonb)) r;

  sale_id := v_done.sale_id;
  invoice_no := v_done.invoice_no;
  landed := true;
  return next;
end;
$$;

revoke all on function app.land_offline_sale(uuid, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- What a device sends when the signal comes back
-- ---------------------------------------------------------------------
--
-- A batch, because that is what a device has: everything it could not
-- send, at once. Each payload gets its own subtransaction, so one bad
-- sale is rejected alone rather than taking the day's takings with it.
create or replace function public.ingest_offline_sales(
  p_register uuid,
  p_sales    jsonb)
returns table (
  client_uuid uuid,
  sale_id     uuid,
  invoice_no  text,
  outcome     text,
  message     text)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_reg     public.pos_registers;
  v_payload jsonb;
  v_client  uuid;
  v_row     record;
  v_err     text;
  v_state   text;
begin
  select * into v_reg from public.pos_registers where id = p_register;
  if v_reg.id is null then
    raise exception 'No such register.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_reg.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if jsonb_typeof(p_sales) <> 'array' then
    raise exception 'Send a list of sales.' using errcode = '22023';
  end if;

  for v_payload in select e from jsonb_array_elements(p_sales) e
  loop
    v_client := nullif(v_payload ->> 'client_uuid', '')::uuid;
    begin
      select * into v_row from app.land_offline_sale(p_register, v_payload);

      client_uuid := v_client;
      sale_id     := v_row.sale_id;
      invoice_no  := v_row.invoice_no;
      outcome     := case when v_row.landed then 'landed' else 'already' end;
      message     := null;

      -- A payload that failed before and works now stops being a
      -- problem, rather than sitting on the screen for ever.
      update public.pos_offline_rejects r
         set resolved_at = now()
       where r.org_id = v_reg.org_id and r.client_uuid = v_client
         and r.resolved_at is null;

      return next;
    exception when others then
      get stacked diagnostics v_err = message_text, v_state = returned_sqlstate;

      perform app.pos_record_reject(
        v_reg.org_id, p_register, v_client, v_payload, v_state, v_err);

      client_uuid := v_client;
      sale_id     := null;
      invoice_no  := null;
      outcome     := 'rejected';
      message     := v_err;
      return next;
    end;
  end loop;
end;
$$;

revoke all on function public.ingest_offline_sales(uuid, jsonb) from public, anon;
grant execute on function public.ingest_offline_sales(uuid, jsonb) to authenticated;

comment on function public.ingest_offline_sales(uuid, jsonb) is
  'Lands a batch of sales rung up with no signal. Safe to call twice: a sale already here is reported, not repeated. One bad payload is rejected on its own and kept for somebody to look at.';

-- ---------------------------------------------------------------------
-- What is still stuck
-- ---------------------------------------------------------------------
create or replace function public.pos_offline_problems(p_org uuid)
returns table (
  reject_id   uuid,
  register    text,
  client_uuid uuid,
  taken_at    timestamptz,
  total       numeric,
  error_code  text,
  message     text)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select r.id, g.name, r.client_uuid,
         nullif(r.payload ->> 'sold_at', '')::timestamptz,
         coalesce((
           select sum(coalesce((l ->> 'quantity')::numeric, 1)
                      * coalesce((l ->> 'unit_price')::numeric, 0))
             from jsonb_array_elements(coalesce(r.payload -> 'lines', '[]'::jsonb)) l), 0),
         r.error_code, r.message
    from public.pos_offline_rejects r
    left join public.pos_registers g on g.id = r.register_id
   where r.org_id = p_org
     and r.resolved_at is null
     and app.can_read_module(p_org, 'pos')
   order by r.created_at;
$$;

grant execute on function public.pos_offline_problems(uuid) to authenticated;

comment on function public.pos_offline_problems(uuid) is
  'Sales a device took that the server could not accept. Money crossed a counter for each of these, so they are listed rather than logged and forgotten.';

-- ---------------------------------------------------------------------
-- Who may look
-- ---------------------------------------------------------------------
alter table public.pos_offline_rejects enable row level security;

-- Read only. The rejects are written by the ingest, which is the only
-- thing that knows a payload failed; and resolving one is done by
-- landing the sale, not by ticking it off.
create policy pos_offline_rejects_read on public.pos_offline_rejects for select
  using (app.can_read_module(org_id, 'pos'));

grant select on public.pos_offline_rejects to authenticated;
