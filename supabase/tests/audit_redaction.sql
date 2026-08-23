-- =====================================================================
-- iAkauntan :: what the audit trail hides, and what it must not
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/audit_redaction.sql
--
-- `app.audit_redact` and `app.attachment_path_ok` are both guards, and
-- neither was named by any test. A guard that fails silently does not
-- produce a wrong number; it produces a leak, or — as it turned out
-- here — a trail that has been recording three asterisks where the
-- company secretary's name should be since 0236.
--
-- 0236 already learned the harder half of this: redaction has to be a
-- property of writing a row down rather than of one of the three ways
-- of writing it down, because putting it inside `audit_diff` hid a
-- changed credential and stored an inserted one in full. That is
-- asserted here for the first time, in all three of insert, update and
-- delete.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- A credential never reaches the trail, however the row was written
--
-- 0236's production probe found an inserted `client_secret` sitting in
-- the trail in full. Asserted here on all three operations, because
-- that defect was visible on exactly one of them.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Kredensial Sdn Bhd');
  v_new jsonb; v_old jsonb;
begin
  -- einvoice_credentials is service-role-only by RLS and carries the
  -- two real secrets in the schema.
  insert into public.einvoice_credentials
    (org_id, environment, client_id, client_secret, cert_private_key_pem)
  values (v_org, 'sandbox', 'CLIENT-1', 'SUPER-SECRET', 'BEGIN PRIVATE KEY');

  -- The table is keyed on (org_id, environment) rather than an id, so
  -- the trail's record_id is null for it and the org is what names the
  -- row here.
  select new_data into v_new from public.audit_logs
   where table_name = 'einvoice_credentials' and org_id = v_org
     and action = 'insert';
  perform pg_temp.check_eq('an inserted client secret is starred out',
    v_new ->> 'client_secret', '***');
  perform pg_temp.check_eq('and so is the signing key',
    v_new ->> 'cert_private_key_pem', '***');
  perform pg_temp.check_eq('while the client id, which is not a secret, is kept',
    v_new ->> 'client_id', 'CLIENT-1');

  update public.einvoice_credentials
     set client_secret = 'SECOND-SECRET' where org_id = v_org;
  select old_data, new_data into v_old, v_new from public.audit_logs
   where table_name = 'einvoice_credentials' and org_id = v_org
     and action = 'update';
  perform pg_temp.check_eq('a changed secret is starred out on the way in',
    v_new ->> 'client_secret', '***');
  perform pg_temp.check_eq('and the one it replaced on the way out',
    v_old ->> 'client_secret', '***');

  delete from public.einvoice_credentials where org_id = v_org;
  select old_data into v_old from public.audit_logs
   where table_name = 'einvoice_credentials' and org_id = v_org
     and action = 'delete';
  perform pg_temp.check_eq('and a deleted row does not spill it either',
    v_old ->> 'client_secret', '***');

  -- The assertion that would have caught 0236's original defect if it
  -- had existed: the literal is nowhere in the trail at all, whatever
  -- key it might have been filed under.
  perform pg_temp.check_eq('the secret appears nowhere in the trail',
    (select count(*) from public.audit_logs
      where table_name = 'einvoice_credentials' and org_id = v_org
        and (old_data::text like '%SUPER-SECRET%'
          or new_data::text like '%SECOND-SECRET%')), 0);
end $$;

-- ---------------------------------------------------------------------
-- The company secretary is not a secret
--
-- `secret` matched as a bare substring, so `responsible_secretary` was
-- redacted and the corporate secretarial module's audit trail recorded
-- three asterisks where the name belonged. 0289 matches whole words
-- within a snake_case name instead.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_eq('the responsible secretary keeps their name',
    app.audit_redact('{"responsible_secretary": "Amanah Setiausaha Sdn Bhd"}'::jsonb)
      ->> 'responsible_secretary', 'Amanah Setiausaha Sdn Bhd');

  -- The words that must still match, one per real column in the schema.
  perform pg_temp.check_eq('client_secret still goes',
    app.audit_redact('{"client_secret": "x"}'::jsonb) ->> 'client_secret', '***');
  perform pg_temp.check_eq('cert_private_key_pem still goes',
    app.audit_redact('{"cert_private_key_pem": "x"}'::jsonb)
      ->> 'cert_private_key_pem', '***');
  perform pg_temp.check_eq('token_hash still goes',
    app.audit_redact('{"token_hash": "x"}'::jsonb) ->> 'token_hash', '***');
  perform pg_temp.check_eq('invite_token still goes',
    app.audit_redact('{"invite_token": "x"}'::jsonb) ->> 'invite_token', '***');
  -- A pointer to a secret rather than a secret. Redacting it costs the
  -- trail nothing anybody needs, and a column called secret_ref is the
  -- right place to be over-cautious.
  perform pg_temp.check_eq('einvoice_secret_ref goes too, though it is only a name',
    app.audit_redact('{"einvoice_secret_ref": "x"}'::jsonb)
      ->> 'einvoice_secret_ref', '***');

  -- Ordinary columns, including ones that contain a sensitive word
  -- without being one.
  perform pg_temp.check_eq('a token_type is a kind, not a token',
    app.audit_redact('{"tokenised_name": "Ahmad"}'::jsonb)
      ->> 'tokenised_name', 'Ahmad');
  perform pg_temp.check_eq('and a name is a name',
    app.audit_redact('{"name": "Sinar Teknologi Sdn Bhd"}'::jsonb)
      ->> 'name', 'Sinar Teknologi Sdn Bhd');

  -- Every audited column in the live schema, checked against the rule
  -- rather than against a list somebody typed. Asserted as a count so
  -- the day a new sensitive column is added it is this that says so.
  perform pg_temp.check_eq('exactly five audited columns are redacted today',
    (with audited as (
       select distinct tgrelid as rel from pg_trigger
        where not tgisinternal and tgfoid = 'app.write_audit_log'::regproc)
     select count(*)
       from audited a
       join pg_attribute att on att.attrelid = a.rel
        and att.attnum > 0 and not att.attisdropped
      where (app.audit_redact(jsonb_build_object(att.attname, 'X'))
               ->> att.attname) = '***'), 5);
end $$;

-- ---------------------------------------------------------------------
-- The empty and the absent
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('a null row redacts to null',
    app.audit_redact(null) is null);
  perform pg_temp.check_eq('an empty row redacts to an empty row',
    app.audit_redact('{}'::jsonb)::text, '{}');
end $$;

-- ---------------------------------------------------------------------
-- What redaction does not reach, said out loud
--
-- Top-level keys only. Thirteen jsonb columns sit on audited tables and
-- a credential inside one of them is written down in full. Left that
-- way on purpose — those columns are user free-form, their contents are
-- already readable to anybody who can read the row, and the rule here
-- is that real credentials live in Edge Function secrets rather than in
-- a table. Asserted so it is a known limit and not a surprise: if
-- somebody makes redaction recursive, this fails and they can delete
-- it deliberately.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_eq('a nested credential is not reached',
    app.audit_redact('{"custom_fields": {"api_key": "hunter2"}}'::jsonb)
      -> 'custom_fields' ->> 'api_key', 'hunter2');
  perform pg_temp.check_eq('though the same key at the top is',
    app.audit_redact('{"api_key": "hunter2"}'::jsonb) ->> 'api_key', '***');
end $$;

-- ---------------------------------------------------------------------
-- And the reasoning above has to stay true
--
-- The limit is defensible because of what the nested columns actually
-- are: `custom_fields` and `variant_attributes`, which a company fills
-- in itself, `attachments`, which is file metadata, `permissions`, and
-- `settings`. Free-form or structural, all of them already readable to
-- anybody who can read the row.
--
-- That argument is about which tables are audited, and nothing was
-- checking it. Give the audit trigger to a table whose jsonb column
-- holds something structured and confidential and the reasoning stops
-- applying silently — the redaction would not have changed, but what it
-- fails to reach would have.
--
-- So the list is the assertion, the way the anon allowlist is. Adding a
-- name here should mean somebody looked at the column and decided a
-- nested credential could not get into it.
--
-- Measured against the running project when this was written: every one
-- of these columns was empty, so the gap is latent rather than open.
-- The first company to name a custom field `password` is what makes it
-- real, and that is the day to make redaction recursive.
-- ---------------------------------------------------------------------
do $$
declare v_unexpected text;
begin
  select string_agg(c.relname || '.' || a.attname, ', ' order by c.relname, a.attname)
    into v_unexpected
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_attribute a on a.attrelid = c.oid
                       and a.attnum > 0 and not a.attisdropped
   where t.tgname = 'audit_changes'
     and format_type(a.atttypid, null) in ('jsonb', 'json')
     and (c.relname || '.' || a.attname) not in (
       'contacts.custom_fields',
       'employees.custom_fields',
       'expenses.attachments',
       'items.custom_fields',
       'items.variant_attributes',
       'org_members.permissions',
       'organizations.settings',
       'purchase_documents.attachments',
       'purchase_documents.custom_fields',
       'purchase_payments.attachments',
       'receipts.attachments',
       'sales_documents.attachments',
       'sales_documents.custom_fields');

  perform pg_temp.check_true(
    'no audited table has grown a nested column nobody has looked at',
    v_unexpected is null);
  if v_unexpected is not null then
    raise notice 'unlisted nested columns on audited tables: %', v_unexpected;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- An attachment path names its own company
--
-- `app.attachment_path_ok` refuses anything that is not exactly
-- <org>/<table>/<record>/<file>. The org prefix is the tenancy boundary:
-- the storage policies read the first segment, so a row whose path
-- carries somebody else's org id would hand a file to the wrong company.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Lampiran Sdn Bhd');
  v_other uuid;
  v_contact uuid;
  v_ok boolean;
begin
  insert into public.organizations (name, slug, entity_type, base_currency, created_by)
  values ('Syarikat Lain', 'syarikat-lain-' || gen_random_uuid(), 'sdn_bhd', 'MYR',
          pg_temp.test_user())
  returning id into v_other;
  insert into public.contacts (org_id, code, contact_type, name)
  values (v_org, 'C-1', 'customer', 'Pelanggan') returning id into v_contact;

  -- The shape that is allowed.
  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path)
  values (v_org, 'contacts', v_contact, 'kad.pdf',
          format('%s/contacts/%s/kad.pdf', v_org, v_contact));
  perform pg_temp.check_eq('a well-formed path is accepted',
    (select count(*) from public.attachments where org_id = v_org), 1);

  -- Each of the four segments, wrong in turn. The org id first, because
  -- it is the one that matters: it is the tenancy boundary.
  v_ok := false;
  begin
    insert into public.attachments
      (org_id, entity_table, entity_id, file_name, storage_path)
    values (v_org, 'contacts', v_contact, 'kad.pdf',
            format('%s/contacts/%s/kad.pdf', v_other, v_contact));
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.check_true('a path naming another company is refused', v_ok);

  v_ok := false;
  begin
    insert into public.attachments
      (org_id, entity_table, entity_id, file_name, storage_path)
    values (v_org, 'contacts', v_contact, 'kad.pdf',
            format('%s/invoices/%s/kad.pdf', v_org, v_contact));
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.check_true('a path naming another table is refused', v_ok);

  v_ok := false;
  begin
    insert into public.attachments
      (org_id, entity_table, entity_id, file_name, storage_path)
    values (v_org, 'contacts', v_contact, 'kad.pdf',
            format('%s/contacts/%s/kad.pdf', v_org, gen_random_uuid()));
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.check_true('a path naming another record is refused', v_ok);

  -- No file name at all: the folder itself.
  v_ok := false;
  begin
    insert into public.attachments
      (org_id, entity_table, entity_id, file_name, storage_path)
    values (v_org, 'contacts', v_contact, 'kad.pdf',
            format('%s/contacts/%s/', v_org, v_contact));
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.check_true('a path with no file on the end is refused', v_ok);

  -- Too short, and too long. A fifth segment is a folder inside the
  -- record's folder, which the storage policies do not expect.
  v_ok := false;
  begin
    insert into public.attachments
      (org_id, entity_table, entity_id, file_name, storage_path)
    values (v_org, 'contacts', v_contact, 'kad.pdf',
            format('%s/contacts/%s', v_org, v_contact));
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.check_true('a path three segments long is refused', v_ok);

  v_ok := false;
  begin
    insert into public.attachments
      (org_id, entity_table, entity_id, file_name, storage_path)
    values (v_org, 'contacts', v_contact, 'kad.pdf',
            format('%s/contacts/%s/sub/kad.pdf', v_org, v_contact));
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.check_true('and one five segments long is refused', v_ok);

  -- That last one is caught by the reconstruction rather than by the
  -- clause written for it: rebuild <org>/<table>/<record>/<fourth
  -- segment> and a path with a fifth segment can never equal it. So the
  -- `split_part(..., 5) <> ''` clause looks redundant, and is — for
  -- every entity_table without a slash in it.
  --
  -- With one it is not. `entity_table = 'a/b'` makes the rebuilt path
  -- five segments long too, and the two agree when the record id and
  -- the file name are the same string. Contrived, and the only way to
  -- reach the clause, which is why it is written down: removing it
  -- would pass every other assertion in this section.
  v_ok := false;
  begin
    insert into public.attachments
      (org_id, entity_table, entity_id, file_name, storage_path)
    values (v_org, 'a/b', v_contact, 'x',
            format('%s/a/b/%s/%s', v_org, v_contact, v_contact));
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.check_true(
    'a table name with a slash in it cannot smuggle a fifth segment past', v_ok);

  -- Climbing out with .. lands as a fifth segment and is refused by the
  -- same rule, which is worth asserting separately because it is the
  -- attack rather than the typo.
  v_ok := false;
  begin
    insert into public.attachments
      (org_id, entity_table, entity_id, file_name, storage_path)
    values (v_org, 'contacts', v_contact, 'kad.pdf',
            format('%s/contacts/%s/../../%s/contacts', v_org, v_contact, v_other));
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.check_true('and so is a path that climbs out of its folder', v_ok);

  -- The guard runs on update too, or a row could be inserted well-formed
  -- and then walked across the boundary.
  v_ok := false;
  begin
    update public.attachments
       set storage_path = format('%s/contacts/%s/kad.pdf', v_other, v_contact)
     where org_id = v_org;
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.check_true('a path cannot be moved to another company later', v_ok);
end $$;

rollback;
