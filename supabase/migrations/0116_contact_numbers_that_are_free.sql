-- A contact code the counter has never heard of
--
-- `app.next_document_number_internal` counts. It does not look at the
-- table it is numbering, and nothing obliges a code to have come from
-- it: the CSV importer in 0103 writes whatever the file said, a lead
-- converted before that could carry its own, and an organization can be
-- seeded with contacts already numbered.
--
-- So the counter sits at 1 while `C-2026-00001` is already taken, and
-- the next contact anybody creates fails on
-- `contacts_org_id_code_key`. It is not a race and it does not heal by
-- itself: the same number comes back every time until something
-- advances the sequence past it.
--
-- Two halves to the fix, and this is the durable one. The app retries a
-- generated code, which covers a collision arriving from anywhere at
-- any time. This moves each contact counter past what its own
-- organization already holds, so the first attempt is normally right and
-- the retry stays what it should be — an exception, not the mechanism.
--
-- Only codes that look like this sequence's own output are considered.
-- A supplier seeded as `S-2026-00001` cannot collide with a `C-2026-`
-- number, and counting it would push the sequence forward for no
-- reason.

do $$
declare
  v_org uuid;
  v_seq record;
  v_period text;
  v_pattern text;
  v_max bigint;
begin
  -- The counter row first, for every organization that has contacts.
  --
  -- Walking the sequences alone would skip precisely the organizations
  -- this is for: one seeded with contacts and no counter has no row to
  -- walk, and would collide on the very first contact anybody creates.
  -- The defaults are the ones the numbering function itself would use.
  for v_org in
    select distinct org_id from public.contacts
  loop
    insert into public.number_sequences (org_id, doc_type, prefix)
    values (v_org, 'contact', app.default_doc_prefix('contact'))
    on conflict (org_id, doc_type) do nothing;
  end loop;

  for v_seq in
    select * from public.number_sequences where doc_type = 'contact'
  loop
    v_period := case v_seq.reset_policy
      when 'yearly' then to_char(current_date, 'YYYY')
      when 'monthly' then to_char(current_date, 'YYYYMM')
      else null end;

    -- The shape the sequence produces right now: prefix, the period key
    -- where there is one, the zero-padded body, then the suffix.
    v_pattern := '^' || regexp_replace(coalesce(v_seq.prefix, ''), '([.^$*+?()\[\]{}|\\])', '\\\1', 'g')
      || coalesce(v_period || '-', '')
      || '(\d+)'
      || regexp_replace(coalesce(v_seq.suffix, ''), '([.^$*+?()\[\]{}|\\])', '\\\1', 'g')
      || '$';

    select max((regexp_match(c.code, v_pattern))[1]::bigint)
      into v_max
      from public.contacts c
     where c.org_id = v_seq.org_id
       and c.code ~ v_pattern;

    -- Only ever forward. A counter that is already ahead of the table is
    -- correct — the codes in between may have been deleted, and reusing
    -- them is exactly what nobody wants.
    if v_max is not null and v_seq.next_value <= v_max then
      update public.number_sequences
         set next_value = v_max + 1,
             period_key = coalesce(v_period, period_key)
       where id = v_seq.id;
    end if;
  end loop;
end $$;
