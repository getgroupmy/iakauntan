-- ---------------------------------------------------------------------
-- The company secretary's name was being redacted as a credential
--
-- `app.audit_redact` decides what never reaches the audit trail by
-- matching the column name against
--
--     (secret|password|private_key|passphrase|api_key|token|credential)
--
-- as a bare substring. `corp_entities.responsible_secretary` contains
-- "secret", so every audit record of the corporate secretarial module's
-- central field reads
--
--     {"responsible_secretary": "***"}
--
-- The audit trail exists to answer "who changed the responsible
-- secretary, and to whom". On that one field it has been answering
-- "somebody changed it to three asterisks" since 0236.
--
-- The fix is to match whole words within a snake_case name rather than
-- substrings: the sensitive word has to start the name, end it, or sit
-- between underscores. `client_secret`, `cert_private_key_pem`,
-- `token_hash`, `invite_token` and `einvoice_secret_ref` all still
-- match; `responsible_secretary` no longer does, because `secret` is
-- followed by `ary` rather than by an underscore or the end.
--
-- `einvoice_secret_ref` stays redacted although it holds only the *name*
-- of an edge-function secret rather than a secret. Redacting a pointer
-- costs an audit trail nothing anybody needs, and erring towards
-- redaction on a column called `secret_ref` is the right way to be
-- wrong.
--
-- A few synonyms go in at the same time — passwd, pwd, apikey, and the
-- plurals — because they cost nothing and no column is named any of
-- them today, so nothing changes except what a future column would do.
--
-- ## What this does not fix
--
-- Redaction still reaches top-level keys only. Thirteen jsonb columns
-- sit on audited tables — `custom_fields` on contacts, employees, items
-- and both document tables, `organizations.settings`,
-- `org_members.permissions`, and the `attachments` arrays — and a key
-- called `api_key` *inside* one of them is written down in full.
--
-- Left alone deliberately. Those columns are user free-form, their
-- contents are already readable to anybody who can read the row, and
-- the rule this project works to is that real credentials never live in
-- a table at all — they live in Edge Function secrets. Recursing would
-- also rewrite ordinary business data in the trail on the strength of a
-- key name somebody typed. Recorded here and asserted in
-- `audit_redaction.sql` so it is a known limit rather than a surprise.
-- ---------------------------------------------------------------------

create or replace function app.audit_redact(p_row jsonb)
returns jsonb
language sql
immutable
set search_path = pg_catalog, pg_temp as $$
  select case
           when p_row is null then null
           else coalesce(
             (select jsonb_object_agg(
                       key,
                       case when key ~* ('(^|_)('
                              || 'secret|secrets|password|passwords|passwd|pwd'
                              || '|private_key|private_keys|passphrase'
                              || '|api_key|api_keys|apikey'
                              || '|token|tokens|credential|credentials'
                              || ')(_|$)')
                            then to_jsonb('***'::text)
                            else value
                       end)
                from jsonb_each(p_row)),
             '{}'::jsonb)
         end;
$$;
