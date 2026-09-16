-- =====================================================================
-- iAkauntan :: 0614 what the paper actually is
--
-- "Instantly capture document data with AI SmartScan, no manual entry
-- required."
--
-- The reading half is built: `ocr_scans`, five readers, an extraction
-- that carries a supplier, a document number, a date, a currency, three
-- totals and the lines. What it has never had is a notion of what the
-- PAPER IS.
--
-- Three screens start a scan -- an expense, a contact, a purchase
-- document -- and each of them already knows the answer because
-- somebody pressed a button on that screen. That is the whole of why
-- this has worked so far and the whole of why it does not scale: it
-- cannot serve a person holding a stack of paper who does not want to
-- sort it first, which is the person the sentence above is written for.
--
-- ---------------------------------------------------------------------
-- A table, not an enum, and by request
--
-- The same shape `0605` gave the kinds of business and `0606` gave the
-- registers to search, for the same reason and at the same person's
-- asking: the list of things worth recognising is not knowable in
-- advance, and a platform administrator adding one should not need a
-- migration.
--
-- ---------------------------------------------------------------------
-- What it does NOT do
--
-- It does not classify. The rules live in the app, in Dart, in a pure
-- function over the text the reader returned -- because they are string
-- matching, they change with every bank's letterhead, and putting them
-- in SQL would mean a migration every time somebody notices that
-- Maybank writes "PENYATA AKAUN" and CIMB writes "ACCOUNT STATEMENT".
--
-- What this holds is the LIST and what each kind is FOR: the words on
-- screen, and where a document of that kind should end up. The
-- classifier chooses between rows; it does not invent them.
-- =====================================================================

create table public.scan_document_kinds (
  code text primary key
    check (code ~ '^[a-z][a-z0-9_]{1,40}$'),

  -- What it is called on screen: "Supplier's bill", "Bank statement".
  label text not null,
  label_my text,

  -- Where a document of this kind goes. Null means "nothing yet" --
  -- which is honest and is not the same as the kind being useless: a
  -- statement of account is worth naming and filing even where nothing
  -- in this product turns one into a record.
  --
  -- Free text rather than a key onto anything: the destinations are
  -- screens, and a screen is not a row.
  destination text,

  -- One line under the name, saying what will happen if it is accepted.
  -- "Becomes a bill you can post." Not decoration: somebody is about to
  -- press a button and this is the only place that says what it does.
  hint text,

  sort_order integer not null default 100,
  is_active boolean not null default true,

  -- One of the ones this shipped with. Renameable and retirable, not
  -- deletable: a scan already filed under a kind stays filed under it.
  is_builtin boolean not null default false,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id) on delete set null
);

comment on table public.scan_document_kinds is
  'What a scanned paper can be recognised as, and where that kind of '
  'paper goes. The rules that CHOOSE between these live in the app: '
  'they are string matching against letterheads and would need a '
  'migration every time a bank changed its wording. 0614.';

create index scan_document_kinds_order_idx
  on public.scan_document_kinds (sort_order, code) where is_active;

create trigger set_updated_at before update on public.scan_document_kinds
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------
-- The ones worth recognising on day one
--
-- Chosen by what this product can DO with them, not by what a scanner
-- can read. A payslip is a document somebody might scan and there is
-- nowhere here for it to go, so it is not on the list -- an option that
-- leads nowhere is worse than no option.
--
-- `other` is last and is the answer when nothing matches, which is the
-- common case for a first reading. It is not a failure.
-- ---------------------------------------------------------------------
insert into public.scan_document_kinds
  (code, label, destination, hint, sort_order, is_builtin)
values
  ('bill', 'Supplier''s bill or invoice', 'purchase_document',
   'Becomes a bill, with the supplier and the lines filled in.',
   10, true),
  ('receipt', 'Receipt', 'expense',
   'Becomes an expense claim you can attach to a payment.', 20, true),
  ('quotation', 'Quotation from a supplier', 'purchase_document',
   'Becomes a purchase order once somebody accepts the price.',
   30, true),
  ('delivery_order', 'Delivery order', 'goods_received',
   'Becomes a goods received note, which puts the stock on the shelf.',
   40, true),
  ('bank_statement', 'Bank statement', 'bank_import',
   'Goes to the reconciliation screen, which matches the lines against '
   'what is already in the books.', 50, true),
  ('name_card', 'Name card or letterhead', 'contact',
   'Becomes a contact, with whatever the paper carries — the name, the '
   'numbers, the address.', 60, true),
  ('ssm_document', 'SSM certificate or profile', 'contact',
   'Fills in a company''s registered name and registration number, '
   'which is what the registry''s own paper is for.', 70, true),
  ('statement_of_account', 'Statement of account', null,
   'Filed as an attachment. Nothing here turns one into a record yet.',
   80, true),
  ('other', 'Something else', null,
   'Filed as an attachment, and the form is typed in.', 999, true)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- Reading it
--
-- Everybody signed in: it is a dropdown on a scan result, and there is
-- nothing tenant-shaped on the row.
-- ---------------------------------------------------------------------
alter table public.scan_document_kinds enable row level security;

create policy scan_document_kinds_read on public.scan_document_kinds
  for select to authenticated using (true);

grant select on public.scan_document_kinds to authenticated;

-- ---------------------------------------------------------------------
-- What the scan was taken to be
--
-- On the scan rather than only in the app, because the question a
-- bookkeeper asks three months later is "what did it think this was",
-- and an answer that lived only in a dialog is an answer nobody can
-- get back to.
--
-- `on delete set null` rather than restrict: a kind that is removed
-- leaves the scans that were filed under it, and a scan whose kind is
-- gone is better than a kind that cannot be tidied. This differs from
-- `entity_types`, deliberately -- a contact's kind is part of the
-- contact, and a scan's kind is a note about a reading.
-- ---------------------------------------------------------------------
alter table public.ocr_scans
  add column if not exists document_kind text
  references public.scan_document_kinds (code)
  on update cascade on delete set null;

comment on column public.ocr_scans.document_kind is
  'What the reading was taken to be. Suggested by the classifier in '
  'the app and confirmable by the person holding the paper. 0614.';

-- ---------------------------------------------------------------------
-- Writing the list
-- ---------------------------------------------------------------------
create or replace function public.platform_save_scan_kind(
  p_code text,
  p_label text,
  p_label_my text default null,
  p_destination text default null,
  p_hint text default null,
  p_sort_order integer default null,
  p_is_active boolean default null)
returns text
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_code text;
  v_existing public.scan_document_kinds%rowtype;
begin
  if not app.is_platform_admin() then
    raise exception 'What a scan can be recognised as is the whole '
                    'platform''s list and may only be changed by a '
                    'platform administrator'
      using errcode = '42501';
  end if;

  v_code := lower(btrim(coalesce(p_code, '')));
  if v_code = '' then
    raise exception 'A kind of document needs a code' using errcode = '23514';
  end if;
  if coalesce(btrim(p_label), '') = '' then
    raise exception 'A kind of document needs a name' using errcode = '23514';
  end if;

  select * into v_existing from public.scan_document_kinds where code = v_code;

  if v_existing.code is null then
    if v_code !~ '^[a-z][a-z0-9_]{1,40}$' then
      raise exception 'A code is lower-case letters, digits and '
                      'underscores, starting with a letter — for example '
                      'credit_note'
        using errcode = '23514';
    end if;
    insert into public.scan_document_kinds
      (code, label, label_my, destination, hint, sort_order, is_active,
       is_builtin, updated_by)
    values
      (v_code, btrim(p_label), nullif(btrim(p_label_my), ''),
       nullif(btrim(p_destination), ''), nullif(btrim(p_hint), ''),
       coalesce(p_sort_order, 100), coalesce(p_is_active, true),
       false, auth.uid());
    return v_code;
  end if;

  -- An absent argument means "leave it alone", the same shape every
  -- other platform list uses. Correcting a label must not clear a hint.
  --
  -- An argument that is PRESENT and empty means "clear it", which the
  -- other platform lists do not need and this one does: three of the
  -- kinds this shipped with have no destination on purpose, so the
  -- console offers "filed only" -- and under a plain `coalesce` picking
  -- it would have said "Saved" and left the old destination standing.
  -- A screen that reports a change it did not make is the fault worth
  -- spending two `case` expressions on.
  --
  -- `label` is not among them: it is refused above when empty, so there
  -- is no third state for it to be in.
  update public.scan_document_kinds set
    label       = btrim(p_label),
    label_my    = case when p_label_my is null then label_my
                       else nullif(btrim(p_label_my), '') end,
    destination = case when p_destination is null then destination
                       else nullif(btrim(p_destination), '') end,
    hint        = case when p_hint is null then hint
                       else nullif(btrim(p_hint), '') end,
    sort_order  = coalesce(p_sort_order, sort_order),
    is_active   = coalesce(p_is_active, is_active),
    updated_by  = auth.uid()
   where code = v_code;

  return v_code;
end;
$function$;

comment on function public.platform_save_scan_kind(
  text, text, text, text, text, integer, boolean) is
  'Adds or amends a kind of document a scan can be recognised as. An '
  'absent argument means "leave it alone"; an empty one means "clear '
  'it", which is how a destination is taken away. 0614.';

revoke all on function public.platform_save_scan_kind(
  text, text, text, text, text, integer, boolean) from public, anon;
grant execute on function public.platform_save_scan_kind(
  text, text, text, text, text, integer, boolean) to authenticated;

create or replace function public.platform_delete_scan_kind(p_code text)
returns boolean
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_builtin boolean;
  v_used bigint;
begin
  if not app.is_platform_admin() then
    raise exception 'What a scan can be recognised as is the whole '
                    'platform''s list and may only be changed by a '
                    'platform administrator'
      using errcode = '42501';
  end if;

  select is_builtin into v_builtin
    from public.scan_document_kinds where code = p_code;
  if v_builtin is null then
    raise exception 'No such kind of document' using errcode = 'P0002';
  end if;
  if v_builtin then
    raise exception 'The kinds this shipped with cannot be removed, only '
                    'switched off — scans are filed under them'
      using errcode = '23503';
  end if;

  -- Named rather than refused. The foreign key is `on delete set null`,
  -- so removing a kind does not break anything -- but a count of what
  -- it would unfile is worth seeing before pressing the button, and
  -- switching it off is usually what was meant.
  select count(*) into v_used
    from public.ocr_scans where document_kind = p_code;
  if v_used > 0 then
    raise exception 'Switch it off instead: % scan(s) are filed as this '
                    'kind and would be left saying nothing', v_used
      using errcode = '23503';
  end if;

  delete from public.scan_document_kinds where code = p_code;
  return true;
end;
$function$;

comment on function public.platform_delete_scan_kind(text) is
  'Removes a kind of document nothing is filed as. Refuses a built-in '
  'one and refuses one in use, naming how many. 0614.';

revoke all on function public.platform_delete_scan_kind(text)
  from public, anon;
grant execute on function public.platform_delete_scan_kind(text)
  to authenticated;

-- ---------------------------------------------------------------------
-- Writing what the person holding the paper said it was
--
-- The kind is chosen AFTER the reading -- the scan row is already
-- written by then, by `ocr_finish` or by `ocr_record_local` -- so it is
-- its own call rather than another argument to either.
--
-- Keyed on the ATTACHMENT rather than the scan, because the attachment
-- is what the app has in its hand: the dialog is handed a reading and
-- the id of the file it came from, and the scan's own id never leaves
-- the database. The most recent scan of that attachment is the one
-- meant; a re-read is a new row and the answer belongs on the reading
-- somebody was actually looking at.
--
-- `app.can_write` rather than a policy: `ocr_scans` has a read policy
-- and no write policy at all, which is deliberate -- rows are written
-- by the functions that charge for them. This is the one field on the
-- row that is a person's opinion rather than an accounting fact.
-- ---------------------------------------------------------------------
create or replace function public.set_scan_document_kind(
  p_org_id uuid,
  p_attachment_id uuid,
  p_document_kind text)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_scan uuid;
  v_kind text;
begin
  if not app.can_write(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  v_kind := nullif(btrim(coalesce(p_document_kind, '')), '');
  if v_kind is not null
     and not exists (select 1 from public.scan_document_kinds
                      where code = v_kind) then
    raise exception 'No such kind of document: %', v_kind
      using errcode = 'P0002';
  end if;

  -- A switched-off kind is NOT refused. The list moves under people,
  -- and a reading somebody is looking at right now was offered the
  -- kinds that were on the list when it loaded. Refusing it here would
  -- lose the answer to a race nobody can see.
  select id into v_scan
    from public.ocr_scans
   where org_id = p_org_id
     and attachment_id = p_attachment_id
   order by created_at desc
   limit 1;

  if v_scan is null then
    -- Not an error. The on-device reader records its scan and the
    -- server one records its own, and a capture that was never read at
    -- all still reaches this call with a kind somebody typed. There is
    -- simply nothing to write it on.
    return null;
  end if;

  update public.ocr_scans set document_kind = v_kind where id = v_scan;
  return v_scan;
end;
$function$;

comment on function public.set_scan_document_kind(uuid, uuid, text) is
  'Files the most recent scan of an attachment as a kind of document. '
  'Accepts a kind that has since been switched off, and answers null '
  'where there is no scan to write on. 0614.';

revoke all on function public.set_scan_document_kind(uuid, uuid, text)
  from public, anon;
grant execute on function public.set_scan_document_kind(uuid, uuid, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- On the platform's own live channel
--
-- The same argument `0605` made for the kinds of business: an
-- administrator adding a kind of document is doing it FOR somebody who
-- is holding the paper now, and "log out and back in" is not an answer
-- to give them.
--
-- `live_changes` cannot carry it — that feed is keyed on `org_id` and
-- this table has none.
--
-- Both halves or neither. `platform_live.dart` names what the client
-- subscribes to and `platform_live_test.dart` asserts the two lists
-- agree, so a table published here and not listened for there fails a
-- test rather than quietly delivering to nobody.
-- ---------------------------------------------------------------------
do $do$
begin
  if not exists (
    select 1
      from pg_publication_rel pr
      join pg_publication p on p.oid = pr.prpubid
      join pg_class c on c.oid = pr.prrelid
      join pg_namespace n on n.oid = c.relnamespace
     where p.pubname = 'supabase_realtime'
       and n.nspname = 'public'
       and c.relname = 'scan_document_kinds'
  ) then
    alter publication supabase_realtime add table public.scan_document_kinds;
  end if;
end $do$;
