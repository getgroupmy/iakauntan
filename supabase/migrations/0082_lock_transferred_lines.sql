-- Stop a transferred document from quietly detaching its chain.
--
-- `saveDocument` in the client deletes a document's lines and re-inserts
-- them, deliberately, so the totals triggers recompute rather than the
-- client being trusted. That is right for an ordinary edit and wrong the
-- moment the document has been transferred: the re-inserted lines get
-- new ids, `source_line_id` on the children is set to null by the
-- foreign key, the source's counters recompute to zero, and the
-- quotation that has already become an order reads as untouched.
--
-- Somebody then transfers it again and the customer receives two orders
-- for one quotation. Nothing in the ledger objects, because none of this
-- has reached the ledger yet.
--
-- So: a line that something was transferred from cannot be deleted. The
-- document has to be dealt with on its own terms — amend the order, or
-- void it, which releases the quantity through the path 0081 already
-- provides.
--
-- This is the same shape as the corp_documents lock in 0072: the rule
-- that matters is enforced where it cannot be bypassed, and the client
-- is changed to not walk into it.

create or replace function app.refuse_transferred_line_delete()
returns trigger
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_doc_no text; v_child text;
begin
  select d.doc_no into v_child
    from public.sales_document_lines c
    join public.sales_documents d on d.id = c.document_id
   where c.source_line_id = old.id
     and d.deleted_at is null and d.status <> 'void'
   limit 1;

  if v_child is not null then
    select doc_no into v_doc_no from public.sales_documents
     where id = old.document_id;
    raise exception
      'Line % of % has been transferred to %. Amend or void % instead.',
      old.line_no, v_doc_no, v_child, v_child
      using errcode = '23514';
  end if;

  return old;
end;
$$;

create or replace function app.refuse_transferred_purchase_line_delete()
returns trigger
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_doc_no text; v_child text;
begin
  select d.doc_no into v_child
    from public.purchase_document_lines c
    join public.purchase_documents d on d.id = c.document_id
   where c.source_line_id = old.id
     and d.deleted_at is null and d.status <> 'void'
   limit 1;

  if v_child is not null then
    select doc_no into v_doc_no from public.purchase_documents
     where id = old.document_id;
    raise exception
      'Line % of % has been transferred to %. Amend or void % instead.',
      old.line_no, v_doc_no, v_child, v_child
      using errcode = '23514';
  end if;

  return old;
end;
$$;

drop trigger if exists refuse_transferred_delete on public.sales_document_lines;
create trigger refuse_transferred_delete
  before delete on public.sales_document_lines
  for each row execute function app.refuse_transferred_line_delete();

drop trigger if exists refuse_transferred_delete on public.purchase_document_lines;
create trigger refuse_transferred_delete
  before delete on public.purchase_document_lines
  for each row execute function app.refuse_transferred_purchase_line_delete();

revoke all on function app.refuse_transferred_line_delete()
  from public, anon, authenticated;
revoke all on function app.refuse_transferred_purchase_line_delete()
  from public, anon, authenticated;
