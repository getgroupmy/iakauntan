-- =====================================================================
-- iAkauntan :: document scanning, and the money it costs
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ocr_credit.sql
--
-- Not statutory arithmetic, but arithmetic somebody is billed for, which
-- earns the same treatment: every ringgit that moves is asserted, and a
-- refund that pays out twice has to break CI rather than a balance.
--
-- The properties asserted here are the ones that would be expensive to
-- get wrong:
--
--   * scanning is off until an administrator turns it on, and an absent
--     settings row is off rather than a default;
--   * a scan on an empty balance is refused before the provider is
--     called, not after;
--   * a scan that fails at the provider returns exactly what it took —
--     once, however many times the callback arrives;
--   * a scan that succeeds returns nothing;
--   * the ledger and the balance say the same number after every move;
--   * a top-up raises an invoice from the issuer in platform_settings,
--     with service tax on top of the credit rather than out of it;
--   * a signed-in user cannot reach the table holding provider keys, and
--     cannot reach the function that hands money back.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- An organization with a receipt already filed against an expense, which
-- is the only thing there is to scan.
create or replace function pg_temp.scannable(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  return v_org;
end;
$$;

create or replace function pg_temp.receipt(p_org uuid, p_file text)
returns uuid language plpgsql as $$
declare
  v_entity uuid := gen_random_uuid();
  v_id     uuid;
begin
  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path, mime_type,
     file_size)
  values (p_org, 'expenses', v_entity, p_file,
          format('%s/expenses/%s/%s', p_org, v_entity, p_file),
          'image/jpeg', 120000)
  returning id into v_id;
  return v_id;
end;
$$;

-- The ledger is the history and org_credits is the number. They are
-- written together or not at all, so every assertion below checks both.
create or replace function pg_temp.check_balance(
  p_label text, p_org uuid, p_expected numeric)
returns void language plpgsql as $$
begin
  perform pg_temp.check_eq(p_label,
    (select balance from public.org_credits where org_id = p_org), p_expected);
  perform pg_temp.check_eq(p_label || ' — ledger agrees',
    (select coalesce(sum(amount), 0) from public.credit_ledger where org_id = p_org),
    p_expected);
  perform pg_temp.check_eq(p_label || ' — last balance_after agrees',
    coalesce((select balance_after from public.credit_ledger
               where org_id = p_org order by created_at desc, ctid desc limit 1),
             0),
    p_expected);
end;
$$;

-- ---------------------------------------------------------------------
-- Off, and staying off
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.scannable('Scanner Sdn Bhd');
  v_file uuid := pg_temp.receipt(v_org, 'tenaga-jun.jpg');
begin
  perform pg_temp.check_true('an organization starts with no scanning row',
    not exists (select 1 from public.org_ocr_settings where org_id = v_org));
  perform pg_temp.check_true('and reads as off rather than as a default',
    (public.ocr_status(v_org) ->> 'enabled')::boolean is false);

  begin
    perform public.ocr_begin(v_org, v_file);
    raise exception 'FAIL: scanned with scanning switched off';
  exception when sqlstate '42501' then
    raise notice 'ok   a scan is refused until somebody turns it on';
  end;

  -- Switching on with your own key you have not supplied is caught at
  -- the moment somebody can still do something about it, rather than at
  -- the first scan.
  begin
    perform public.set_ocr_settings(v_org, true, 'claude', 'own');
    raise exception 'FAIL: enabled own-key scanning with no key';
  exception when sqlstate '23514' then
    raise notice 'ok   own-key scanning needs a key first';
  end;

  -- Google wants a processor, not just a key.
  begin
    perform public.set_ocr_credentials(v_org, 'google', '{"type":"service_account"}');
    raise exception 'FAIL: stored a Document AI key with no processor';
  exception when sqlstate '23514' then
    raise notice 'ok   Document AI needs a project, location and processor';
  end;
end $$;

-- ---------------------------------------------------------------------
-- The platform key, which is the one that costs money
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.scannable('Kredit Sdn Bhd');
  v_user  uuid := pg_temp.test_user();
  v_file  uuid := pg_temp.receipt(v_org, 'petrol-01.jpg');
  v_file2 uuid := pg_temp.receipt(v_org, 'petrol-02.jpg');
  v_scan  uuid;
  v_top   jsonb;
begin
  perform public.set_ocr_settings(v_org, true, 'claude', 'platform');
  perform pg_temp.check_eq('the platform price is what the console says',
    (public.ocr_status(v_org) -> 'price')::numeric, 0.30);

  -- Nothing bought yet.
  begin
    perform public.ocr_begin(v_org, v_file);
    raise exception 'FAIL: scanned on an empty balance';
  exception when sqlstate '23514' then
    raise notice 'ok   a scan on an empty balance is refused';
  end;
  perform pg_temp.check_eq('and nothing was recorded as pending',
    (select count(*) from public.ocr_scans where org_id = v_org), 0);

  -- Selling the credit. Only the platform may.
  begin
    perform public.platform_topup_credit(v_org, 10);
    raise exception 'FAIL: a tenant topped up its own balance';
  exception when sqlstate '42501' then
    raise notice 'ok   a tenant cannot top itself up';
  end;

  insert into public.platform_admins (user_id) values (v_user)
  on conflict do nothing;

  v_top := public.platform_topup_credit(v_org, 10, 'First purchase');
  perform pg_temp.check_eq('a top-up grants the ringgit it sold',
    (v_top -> 'subtotal')::numeric, 10.00);
  perform pg_temp.check_balance('and the balance carries it', v_org, 10.00);

  -- One scan, one charge.
  v_scan := (public.ocr_begin(v_org, v_file) ->> 'scan_id')::uuid;
  perform pg_temp.check_balance('a scan takes the price', v_org, 9.70);
  perform pg_temp.check_eq('and records what it took',
    (select amount_charged from public.ocr_scans where id = v_scan), 0.30);

  -- Failed at the provider: exactly what it took comes back.
  perform public.ocr_finish(v_scan, 'failed', null, 'provider returned 500');
  perform pg_temp.check_balance('a failed scan gives it back', v_org, 10.00);
  perform pg_temp.check_true('and says so on the scan',
    (select refunded and status = 'failed' from public.ocr_scans where id = v_scan));

  -- A retried callback must not pay out twice. This is the assertion the
  -- whole `status <> 'pending'` guard exists for.
  perform public.ocr_finish(v_scan, 'failed', null, 'provider returned 500');
  perform pg_temp.check_balance('and only once, however often it arrives',
    v_org, 10.00);
  perform pg_temp.check_eq('one usage line and one refund line, no more',
    (select count(*) from public.credit_ledger
      where org_id = v_org and scan_id = v_scan), 2);

  -- A scan that works keeps the money.
  v_scan := (public.ocr_begin(v_org, v_file2) ->> 'scan_id')::uuid;
  perform public.ocr_finish(v_scan, 'ok',
    '{"supplier":"Petron","total":85.40}'::jsonb, null);
  perform pg_temp.check_balance('a scan that works keeps the charge',
    v_org, 9.70);
  perform pg_temp.check_true('and hands back what it read',
    (select extracted ->> 'supplier' = 'Petron'
       from public.ocr_scans where id = v_scan));
end $$;

-- ---------------------------------------------------------------------
-- Their own key, which costs the platform nothing
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.scannable('Kunci Sendiri Sdn Bhd');
  v_file uuid := pg_temp.receipt(v_org, 'astro-jul.jpg');
  v_out  jsonb;
begin
  -- Key first, then the setting that needs it. That order is not
  -- incidental: `set_ocr_settings` refuses `own` while no key is on file
  -- (asserted above), so it is the only sequence that works, and the
  -- Settings screen writes both in exactly this order for that reason.
  -- The first version of that screen wrote the setting alone and put
  -- the key field behind it, which nothing could reach.
  perform public.set_ocr_credentials(v_org, 'claude', 'sk-ant-fixture');
  perform public.set_ocr_settings(v_org, true, 'claude', 'own');

  v_out := public.ocr_begin(v_org, v_file);
  perform pg_temp.check_eq('an organization on its own key is not charged',
    (v_out -> 'charged')::numeric, 0);
  perform pg_temp.check_eq('and no ledger line is written',
    (select count(*) from public.credit_ledger where org_id = v_org), 0);

  -- The key never comes back through anything the app calls.
  perform pg_temp.check_true('the status says a key is set',
    (public.ocr_status(v_org) ->> 'has_own_key')::boolean);
  perform pg_temp.check_true('and does not say what it is',
    public.ocr_status(v_org)::text not like '%sk-ant-fixture%');

  -- Removing the key switches scanning off rather than leaving a run of
  -- failures behind it.
  perform public.clear_ocr_credentials(v_org, 'claude');
  perform pg_temp.check_true('removing the key switches scanning off',
    (public.ocr_status(v_org) ->> 'enabled')::boolean is false);
end $$;

-- ---------------------------------------------------------------------
-- The invoice Kabeer Holdings issues for the credit
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.scannable('Pembeli Kredit Sdn Bhd');
  v_user uuid := pg_temp.test_user();
  v_top   jsonb;
  inv     public.platform_invoices;
  v_first integer;
begin
  insert into public.platform_admins (user_id) values (v_user)
  on conflict do nothing;

  v_top := public.platform_topup_credit(v_org, 250, 'Bank transfer 11 Aug');
  select * into inv from public.platform_invoices
   where id = (v_top ->> 'invoice_id')::uuid;
  v_first := substring(inv.invoice_no from '[0-9]+$')::integer;

  perform pg_temp.check_true('the invoice is numbered by year',
    inv.invoice_no like 'KH-' || to_char(current_date, 'YYYY') || '-%');
  perform pg_temp.check_true('and carries both registration numbers',
    inv.issuer_registration_no = '201901030189'
    and inv.issuer_old_registration_no = '1339519K');
  perform pg_temp.check_true('and names the issuer',
    inv.issuer_name = 'Kabeer Holdings Sdn Bhd');
  perform pg_temp.check_true('and the customer it was raised on',
    inv.bill_to_name = 'Pembeli Kredit Sdn Bhd');

  -- Not registered for service tax, so there is none — and the invoice
  -- says zero rather than leaving it to be inferred.
  perform pg_temp.check_eq('no service tax while unregistered',
    inv.tax_amount, 0.00);
  perform pg_temp.check_eq('so the total is the credit', inv.total_amount, 250.00);
  perform pg_temp.check_balance('and the credit landed', v_org, 250.00);

  -- The day Kabeer Holdings registers. Tax goes on top of the credit:
  -- RM 250 bought is RM 250 spendable, whatever the tax on the supply.
  update public.platform_settings
     set value = value || '{"sst_registered": true, "sst_rate": 8, "sst_no": "W10-1808-31000123"}'::jsonb
   where key = 'platform_issuer';

  v_top := public.platform_topup_credit(v_org, 250, 'Second purchase');
  select * into inv from public.platform_invoices
   where id = (v_top ->> 'invoice_id')::uuid;

  perform pg_temp.check_eq('service tax at 8 per cent once registered',
    inv.tax_amount, 20.00);
  perform pg_temp.check_eq('charged on top of the credit',
    inv.total_amount, 270.00);
  perform pg_temp.check_true('with the registration number on the document',
    inv.issuer_sst_no = 'W10-1808-31000123');
  perform pg_temp.check_balance('and the credit is still what was bought',
    v_org, 500.00);

  -- One higher than the last one issued, not a fixed number: the block
  -- above this one already sold credit to a different organization, so
  -- the first invoice here is not the first invoice of the year. That
  -- is the whole point of the counter, and asserting a literal tested
  -- the fixture rather than the code.
  perform pg_temp.check_eq('numbers run in sequence',
    substring(inv.invoice_no from '[0-9]+$')::integer, v_first + 1);
  perform pg_temp.check_true('and stay padded and prefixed',
    inv.invoice_no ~ ('^KH-' || to_char(current_date, 'YYYY') || '-[0-9]{4}$'));

  -- Goodwill, and taking it back, both leave a line.
  perform public.platform_adjust_credit(v_org, 25, 'Outage on 12 Aug');
  perform pg_temp.check_balance('an adjustment moves the balance',
    v_org, 525.00);
  perform pg_temp.check_true('and says why',
    (select description = 'Outage on 12 Aug' from public.credit_ledger
      where org_id = v_org order by created_at desc, ctid desc limit 1));

  begin
    perform public.platform_adjust_credit(v_org, -1000, 'Clawback');
    raise exception 'FAIL: adjusted a balance below zero';
  exception when sqlstate '23514' then
    raise notice 'ok   an adjustment cannot push a balance negative';
  end;
end $$;

-- ---------------------------------------------------------------------
-- The catalog, which is what makes the next reader a row
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.scannable('Katalog Sdn Bhd');
  v_file uuid := pg_temp.receipt(v_org, 'grab-01.jpg');
begin
  -- A reader nobody has finished setting up is refused by name, with
  -- the reason and who can fix it. ChatGPT and Grok ship with no model
  -- deliberately: guessing an identifier produces a migration that
  -- looks finished and a 404 at the first scan.
  begin
    perform public.set_ocr_settings(v_org, true, 'openai', 'platform');
    raise exception 'FAIL: switched on a reader with no model set';
  exception when sqlstate '23514' then
    raise notice 'ok   a reader with no model cannot be chosen';
  end;

  -- Once the platform sets one, it works — and this is the whole point:
  -- no migration, no deploy, no app release.
  update public.ocr_providers set model = 'a-vision-model' where code = 'openai';
  perform public.set_ocr_settings(v_org, true, 'openai', 'platform');
  perform pg_temp.check_eq('a reader set up in the console can be chosen',
    (select count(*) from public.org_ocr_settings
      where org_id = v_org and provider = 'openai'), 1);

  -- Price comes off the catalog row, so a scan is charged what the
  -- console says and not what a second table remembers.
  update public.ocr_providers set price = 0.45 where code = 'openai';
  perform pg_temp.check_eq('the price is the catalog price',
    (public.ocr_status(v_org) -> 'price')::numeric, 0.45);

  -- Grok speaks the same protocol as ChatGPT, which is why it is a row
  -- and not a code path.
  perform pg_temp.check_true('Grok and ChatGPT share one protocol',
    (select count(distinct kind) = 1 from public.ocr_providers
      where code in ('openai', 'grok')));

  -- Choosing the on-device reader forces `device` whatever was asked
  -- for — including `own`, which it has no key for — so nothing later
  -- goes looking for a key or bills for a free reading. Coerced rather
  -- than refused: the caller's mistake is harmless and the stored row
  -- is right either way, which is not true of the reverse.
  perform public.set_ocr_settings(v_org, true, 'mlkit', 'own');
  perform pg_temp.check_true('the on-device reader forces its own source',
    (select key_source = 'device' from public.org_ocr_settings
      where org_id = v_org));
  perform public.set_ocr_settings(v_org, true, 'mlkit', 'platform');
  perform pg_temp.check_true('however it is asked for',
    (select key_source = 'device' from public.org_ocr_settings
      where org_id = v_org));

  -- The reverse is refused, because there is nothing to coerce it to: a
  -- reader that needs a key cannot be told it runs on the device.
  begin
    perform public.set_ocr_settings(v_org, true, 'openai', 'device');
    raise exception 'FAIL: claimed a server reader runs on the device';
  exception when sqlstate '23514' then
    raise notice 'ok   a server reader cannot claim to run on the device';
  end;

  -- And the server refuses to start a scan it cannot serve.
  begin
    perform public.ocr_begin(v_org, v_file);
    raise exception 'FAIL: started a server scan for an on-device reader';
  exception when sqlstate '0A000' then
    raise notice 'ok   the server will not start an on-device scan';
  end;

  -- The reverse: the local log refuses a reading the organization did
  -- not choose to make locally.
  perform public.set_ocr_settings(v_org, true, 'claude', 'platform');
  begin
    perform public.ocr_record_local(v_org, v_file, '{}'::jsonb);
    raise exception 'FAIL: logged a local scan for a server reader';
  exception when sqlstate '23514' then
    raise notice 'ok   nor log a local scan against a server reader';
  end;

  -- A local reading costs nothing and still leaves a row, because
  -- "where did this figure come from" is asked about free readings too.
  perform public.set_ocr_settings(v_org, true, 'mlkit', 'platform');
  perform public.ocr_record_local(v_org, v_file,
    '{"supplier_name":"99 Speedmart","total_amount":33.91}'::jsonb);
  perform pg_temp.check_eq('a local reading is logged at zero',
    (select amount_charged from public.ocr_scans
      where org_id = v_org order by created_at desc limit 1), 0);
  perform pg_temp.check_eq('and moves no money',
    (select count(*) from public.credit_ledger where org_id = v_org), 0);
  perform pg_temp.check_true('and is settled, not left pending',
    (select status = 'ok' from public.ocr_scans
      where org_id = v_org order by created_at desc limit 1));
end $$;

-- ---------------------------------------------------------------------
-- A reader in use cannot be deleted out from under an organization
-- ---------------------------------------------------------------------
do $$
declare v_org uuid := pg_temp.scannable('Pengguna Setia Sdn Bhd');
begin
  perform public.set_ocr_settings(v_org, true, 'claude', 'platform');
  begin
    delete from public.ocr_providers where code = 'claude';
    raise exception 'FAIL: deleted a reader an organization is using';
  exception when foreign_key_violation then
    raise notice 'ok   a reader in use cannot be deleted';
  end;
  -- Retiring one is a flag, which stops it being chosen without
  -- breaking whoever already has it.
  update public.ocr_providers set is_active = false where code = 'claude';
  perform pg_temp.check_true('a retired reader still reads back',
    (public.ocr_status(v_org) ->> 'provider') = 'claude');
end $$;

-- ---------------------------------------------------------------------
-- What a signed-in user cannot reach
--
-- Both of these are grants rather than policies, so they hold even if a
-- policy is dropped — the lesson 0107 exists for.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('a signed-in user cannot read provider keys',
    not has_table_privilege('authenticated', 'public.org_ocr_credentials', 'select'));
  perform pg_temp.check_true('nor write them',
    not has_table_privilege('authenticated', 'public.org_ocr_credentials', 'insert'));

  -- ocr_finish hands money back. Reachable from a browser it would be a
  -- refund button with no scan behind it.
  perform pg_temp.check_true('nor settle a scan, which is what refunds',
    not has_function_privilege('authenticated',
      'public.ocr_finish(uuid, text, jsonb, text)', 'execute'));
  perform pg_temp.check_true('nor move a balance directly',
    not has_function_privilege('authenticated',
      'app.move_credit(uuid, text, numeric, text, uuid, uuid, boolean)', 'execute'));

  -- The catalog decides where documents are sent. A tenant able to
  -- write it could point the whole system at an endpoint of their
  -- choosing, which is a data exfiltration path and not a setting.
  perform pg_temp.check_true('a signed-in user cannot edit the reader catalog',
    not has_function_privilege('anon',
      'public.platform_set_ocr_provider(text, text, text, text, text, numeric, boolean, text)',
      'execute'));
  perform pg_temp.check_true('and reading it is all a tenant may do',
    (select count(*) = 1 from pg_policies
      where tablename = 'ocr_providers' and cmd = 'SELECT'));

  -- The anonymous role reaches none of it either.
  perform pg_temp.check_true('and anon reaches none of it',
    not has_function_privilege('anon', 'public.ocr_begin(uuid, uuid)', 'execute')
    and not has_function_privilege('anon',
      'public.platform_topup_credit(uuid, numeric, text)', 'execute'));
end $$;

-- ---------------------------------------------------------------------
-- A reader you run yourself (0586)
-- ---------------------------------------------------------------------
do $$
declare
  v_bad integer;
begin
  perform pg_temp.check_true(
    'the catalog accepts a self-hosted reader',
    exists (select 1 from public.ocr_providers
             where kind = 'self_hosted'));

  -- The three ship switched OFF and with no address. A row offering a
  -- reader nobody has deployed is a door with nothing behind it, and
  -- the console would draw it.
  select count(*) into v_bad
    from public.ocr_providers
   where kind = 'self_hosted'
     and (is_active or endpoint is not null);
  perform pg_temp.check_eq(
    'and every one of them ships inactive and unaddressed', v_bad, 0);

  -- The edge function refuses a self-hosted reader with no endpoint,
  -- and there is no default that would make sense. Asserted here so a
  -- row added later with `is_active` and no address fails the build
  -- rather than a scan.
  perform pg_temp.check_true(
    'and none of them claims to run on the device',
    not exists (select 1 from public.ocr_providers
                 where kind = 'self_hosted' and runs_on_device));

  -- The kind is still closed. A typo in a later insert should be a
  -- constraint violation and not a reader the function cannot talk to.
  perform pg_temp.check_refused(
    'and an unknown kind is still refused by the catalog',
    $q$insert into public.ocr_providers (code, name, kind)
       values ('nonsense', 'Nonsense', 'whatever')$q$,
    '%ocr_providers_kind_check%');
end $$;

rollback;
