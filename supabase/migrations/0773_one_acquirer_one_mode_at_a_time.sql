-- =====================================================================
-- iAkauntan :: 0773 one acquirer, one mode at a time
--
-- A company keeps an acquirer's keys twice -- once for its sandbox and
-- once for production -- and `set_org_payment_gateway` switched each
-- on and off by itself. Nothing stopped both being on, and everything
-- downstream assumes one:
--
--   * `app.shared_payment_intent` returned BOTH rows, and the share
--     link offered the acquirer twice (`shared_payment_options`);
--   * `pay-invoice` built the bill from `rows[0]` -- whichever the
--     database happened to return first;
--   * `begin_shared_payment` recorded its own first row, from a second
--     query, in no stated order either;
--   * the callback checks the signature with the key of the mode that
--     was RECORDED (`app.shared_payment_signature_key`).
--
-- So either a customer is sent to the sandbox page, pays with test
-- money, and the invoice is settled with a real receipt banked to a
-- real account; or the bill is made live and recorded as sandbox, and
-- the real payment's callback fails its signature check -- the money
-- arrives and the invoice never settles. Measured on 9 October 2026,
-- locally: two intent rows, the acquirer offered twice, the payment
-- started in sandbox with production switched on.
--
-- Answered "one mode per acquirer": switching an acquirer on in one
-- mode switches its other mode off, and an index makes the double
-- state impossible to write by any other road. The intent and the
-- options then return at most one row per acquirer, and the three
-- readers above need no change.
--
-- Production held no acquirer configuration at all when this was
-- written, so the clean-up below changes nothing there. It is here so
-- the index cannot fail on a database that does hold the double state,
-- and it keeps the LIVE keys on: a company that has gone live and left
-- its sandbox switched on meant the live one.
-- =====================================================================

update public.org_payment_gateways s
   set is_active = false, updated_at = now()
 where s.mode = 'sandbox' and s.is_active
   and exists (select 1 from public.org_payment_gateways p
                where p.org_id = s.org_id
                  and p.gateway_code = s.gateway_code
                  and p.mode = 'production' and p.is_active);

create unique index org_payment_gateways_one_active_mode
  on public.org_payment_gateways (org_id, gateway_code)
  where is_active;

-- Restated from 0412, which is what production runs (identical source
-- hash on 9 October). One paragraph is new, before the insert.
create or replace function public.set_org_payment_gateway(
  p_org_id         uuid,
  p_gateway        text,
  p_mode           text default 'sandbox',
  p_api_key        text default null,
  p_collection_ref text default null,
  p_signature_key  text default null,
  p_is_active      boolean default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp
as $fn$
declare
  v_key    text;
  v_ref    text;
  v_sig    text;
  v_active boolean;
begin
  -- `can_admin`, not `can_write`: these are the keys to taking money in
  -- this company's name.
  if not app.can_admin(p_org_id) then
    raise exception
      'Only an administrator can set this company''s payment credentials'
      using errcode = '42501';
  end if;

  if p_mode not in ('sandbox', 'production') then
    raise exception 'Mode must be sandbox or production, not %', p_mode
      using errcode = '23514';
  end if;

  if not exists (select 1 from public.payment_gateways g
                  where g.code = p_gateway) then
    raise exception '% is not an acquirer this platform knows about.',
      p_gateway using errcode = '23503';
  end if;

  select c.api_key, c.collection_ref, c.signature_key, c.is_active
    into v_key, v_ref, v_sig, v_active
    from public.org_payment_gateways c
   where c.org_id = p_org_id and c.gateway_code = p_gateway
     and c.mode = p_mode;

  -- Before the insert, not in the `on conflict` arm: `api_key` is NOT
  -- NULL and the proposed row is validated before the conflict is
  -- looked for, so a coalesce in the update arm never runs. `0107`
  -- found this with a failing test rather than by reading the manual.
  v_key    := coalesce(nullif(trim(coalesce(p_api_key, '')), ''), v_key);
  v_ref    := coalesce(nullif(trim(coalesce(p_collection_ref, '')), ''), v_ref);
  v_sig    := coalesce(nullif(trim(coalesce(p_signature_key, '')), ''), v_sig);
  v_active := coalesce(p_is_active, v_active, false);

  if v_key is null then
    raise exception
      'An API key is required the first time % is set up for %',
      p_gateway, p_mode using errcode = '23514';
  end if;

  -- `0773`: one mode at a time. Switching this mode on switches the
  -- other one off, first, so the index on (org, gateway) where active
  -- never sees two. Switching this mode OFF leaves the other alone.
  if v_active then
    update public.org_payment_gateways c
       set is_active = false, updated_by = auth.uid(), updated_at = now()
     where c.org_id = p_org_id and c.gateway_code = p_gateway
       and c.mode <> p_mode and c.is_active;
  end if;

  insert into public.org_payment_gateways
    (org_id, gateway_code, mode, api_key, collection_ref, signature_key,
     is_active, updated_by)
  values (p_org_id, p_gateway, p_mode, v_key, v_ref, v_sig, v_active,
          auth.uid())
  on conflict (org_id, gateway_code, mode) do update
     set api_key        = excluded.api_key,
         collection_ref = excluded.collection_ref,
         signature_key  = excluded.signature_key,
         is_active      = excluded.is_active,
         updated_by     = excluded.updated_by,
         updated_at     = now();
end
$fn$;

comment on function public.set_org_payment_gateway(uuid, text, text, text, text, text, boolean) is
  'Stores a company''s own acquirer credentials for one gateway in one '
  'mode. `can_admin` and not `can_write`, because these are the keys to '
  'taking money in this company''s name. Refuses a gateway this '
  'platform does not know and a mode that is neither sandbox nor '
  'production. The key is resolved BEFORE the insert rather than in the '
  '`on conflict` arm: `api_key` is NOT NULL and the proposed row is '
  'validated before the conflict is looked for, so a coalesce in the '
  'update arm would never run (`0107`). Switching one mode ON switches '
  'the same acquirer''s other mode OFF (`0773`): with both on, the pay '
  'link chose between them by row order, and a sandbox payment could '
  'settle a real invoice.';
