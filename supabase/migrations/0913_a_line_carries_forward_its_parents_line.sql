-- =====================================================================
-- iAkauntan :: 0913 a line carries forward a line of its parent
--
-- `source_line_id` on a sales or purchase document line names the line
-- of an earlier document it carries forward. `transfer_document` sets
-- it, as its owner, on every line it copies, and sets the new header's
-- `parent_id` to the document it copied from. The progress counters
-- are worked out from it: `app.refresh_sales_progress` and
-- `app.refresh_purchase_progress` add up every live line that names a
-- line, and `0904` made the counters the database's -- but not the
-- links they are counted from. `transfer_document` caps what can still
-- be taken forward by those counters, and since `0903` they are what
-- keeps one order line from going forward two ways.
--
-- Measured on 18 October 2026, locally, as the owner with the role
-- `authenticated`: ten ordered at 25, received on a note and the note
-- posted (10 on hand, 1310 at 250, 2118 at -250). A bill typed by hand,
-- its one line naming the note's line: the note read fully billed, and
-- billing it was refused ("Nothing left to transfer"). The typed bill
-- has no parent, so it received the goods itself when it posted -- 20
-- on hand, 1310 at 500, 2110 at -250, and the note's 250 in 2118 never
-- cleared. A typed invoice naming a quotation's line marked the
-- quotation partly invoiced.
--
-- The app writes the column, but only back: a draft is saved by
-- deleting every line and inserting it again (`line_draft.dart`), each
-- with the `source_line_id` it was loaded with, and the editor only
-- ever re-saves the document it loaded. So a client's line can name a
-- line of the document its header was raised from, and nothing else.
--
-- Production on 18 October: 30 linked lines, every one of them in the
-- Sinar Teknologi demo, whose forecasting seeder (`0203`) points bills
-- it built at orders it built after them, as their owner, without a
-- parent. It is not asked.
--
-- Answered "only a line of its parent": a client's line may name as
-- its source only a line of the document its header was raised from --
-- `parent_id`, which since `0911` only the transfer and the two credit
-- functions write -- and a line of a document typed by hand names none.
-- Asked when a line is inserted, or its source or its document is
-- changed. Every SECURITY DEFINER path runs as its owner and is not
-- asked. Nothing is backfilled.
-- =====================================================================

create or replace function app.a_line_carries_its_parents_line()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_doc_no     text;
  v_parent     uuid;
  v_parent_no  text;
  v_source_doc uuid;
  v_source_no  text;
begin
  -- NOT security definer, for 0781's reason: the question is who runs
  -- the statement. `transfer_document` and the demo seeders run as
  -- their owner. Read as the writer, so a line the writer may not see
  -- is a line it may not name.
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if new.source_line_id is null then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and new.source_line_id is not distinct from old.source_line_id
     and new.document_id is not distinct from old.document_id then
    return new;
  end if;

  if tg_table_name = 'sales_document_lines' then
    select d.doc_no, d.parent_id, p.doc_no
      into v_doc_no, v_parent, v_parent_no
      from public.sales_documents d
      left join public.sales_documents p on p.id = d.parent_id
     where d.id = new.document_id;
    select s.document_id, sd.doc_no
      into v_source_doc, v_source_no
      from public.sales_document_lines s
      join public.sales_documents sd on sd.id = s.document_id
     where s.id = new.source_line_id;
  else
    select d.doc_no, d.parent_id, p.doc_no
      into v_doc_no, v_parent, v_parent_no
      from public.purchase_documents d
      left join public.purchase_documents p on p.id = d.parent_id
     where d.id = new.document_id;
    select s.document_id, sd.doc_no
      into v_source_doc, v_source_no
      from public.purchase_document_lines s
      join public.purchase_documents sd on sd.id = s.document_id
     where s.id = new.source_line_id;
  end if;

  if v_parent is null then
    raise exception
      '% was not raised from another document, so none of its lines '
      'carries one forward (this one named a line of %). What an order, '
      'a note or a quotation still has to take forward is counted from '
      'these links, and one made by hand marks it taken forward when it '
      'was not. Transfer the document it comes from instead.',
      v_doc_no, coalesce(v_source_no, 'a document you cannot see')
      using errcode = '42501';
  end if;
  if v_source_doc is distinct from v_parent then
    raise exception
      '% was raised from %, so a line of it carries forward a line of % '
      'and of nothing else (this one named a line of %). What an order, '
      'a note or a quotation still has to take forward is counted from '
      'these links.',
      v_doc_no, v_parent_no, v_parent_no,
      coalesce(v_source_no, 'a document you cannot see')
      using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke all on function app.a_line_carries_its_parents_line() from public, anon, authenticated;

comment on function app.a_line_carries_its_parents_line() is
  'Refuses a client''s sales or purchase document line whose '
  'source_line_id names anything but a line of the document its header '
  'was raised from (parent_id), on insert and when its source or its '
  'document changes. transfer_document sets both, as its owner; the '
  'progress counters are counted from the links. 0913.';

create trigger a_line_carries_its_parents_line
  before insert or update of source_line_id, document_id on public.sales_document_lines
  for each row execute function app.a_line_carries_its_parents_line();

create trigger a_line_carries_its_parents_line
  before insert or update of source_line_id, document_id on public.purchase_document_lines
  for each row execute function app.a_line_carries_its_parents_line();
