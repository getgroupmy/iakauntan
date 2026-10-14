-- =====================================================================
-- iAkauntan :: 0898 a transfer arrives no earlier than it leaves
--
-- `send_stock_transfer` posts the movement out, and its journal, on the
-- transfer's own date; `receive_stock_transfer` posted the movement in,
-- and its journal, on today. A transfer dated ahead was therefore
-- received before it left.
--
-- Measured on 14 October 2026, locally, as the owner with the role
-- `authenticated`: 20 kg of rice on a transfer dated ten days ahead,
-- sent and received the same day. The shop held it from that day, the
-- kitchen gave it up ten days later -- 120 kg on the books where there
-- were 100 -- and the receipt journal came ten days before the dispatch
-- it clears out of transit.
--
-- Production held no stock transfer on 14 October.
--
-- Answered "receive on the later day": the movement in and its journal
-- are dated the later of today and the transfer's date, the rule the
-- voids follow in `0888` and "credit this" in `0889`.
--
-- The body is `pg_get_functiondef` of what was applied, with the block
-- marked 0898 added and its two dates read from it.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.receive_stock_transfer(p_id uuid, p_counts jsonb DEFAULT '[]'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_t       public.stock_transfers;
  v_line    record;
  v_got     numeric;
  v_arrived numeric := 0;
  v_short   numeric := 0;
  v_lines   jsonb;
  v_entry   uuid;
  v_inv     uuid;
  v_transit uuid;
  v_shrink  uuid;
  v_on      date;
begin
  select * into v_t from public.stock_transfers where id = p_id;
  if v_t.id is null then
    raise exception 'No such transfer.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_t.org_id, 'inventory') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if v_t.status <> 'sent' then
    raise exception
      'That transfer is %, so there is nothing on its way to receive.',
      v_t.status using errcode = '23514';
  end if;
  -- 0898: it arrives no earlier than it leaves. Sending posts on the
  -- transfer's own date; one dated ahead is received on that day, not
  -- today, as a void or a credit of a document dated ahead is (0888,
  -- 0889). One already dated is received today, as before.
  v_on := greatest(app.today(), v_t.transfer_date);

  for v_line in
    select l.*, i.name as item_name
      from public.stock_transfer_lines l
      join public.items i on i.id = l.item_id
     where l.transfer_id = p_id
     order by l.line_no
  loop
    select (e ->> 'quantity')::numeric into v_got
      from jsonb_array_elements(coalesce(p_counts, '[]'::jsonb)) e
     where (e ->> 'line')::uuid = v_line.id;
    v_got := coalesce(v_got, v_line.sent_quantity);

    if v_got < 0 then
      raise exception 'A count cannot be negative.' using errcode = '23514';
    end if;
    -- See the header: there is no such thing as receiving more than
    -- was sent.
    if v_got > v_line.sent_quantity then
      raise exception
        'Only % of % was sent, so % of it cannot have arrived.',
        v_line.sent_quantity, v_line.item_name, v_got
        using errcode = '23514';
    end if;

    update public.stock_transfer_lines l
       set received_quantity = v_got where l.id = v_line.id;

    if v_got > 0 then
      insert into public.stock_movements (
        org_id, movement_no, movement_date, movement_type, item_id,
        warehouse_id, quantity, unit_cost, source_table, source_id,
        source_line_id, notes, created_by)
      values (
        v_t.org_id,
        app.next_document_number_internal(v_t.org_id, 'stock_movement'),
        v_on, 'transfer_in', v_line.item_id,
        v_t.to_warehouse_id, v_got,
        -- The price it left at. An inbound movement is taken at the
        -- cost it is given, and taking it in at the destination's own
        -- average would move value between two warehouses that are
        -- supposed to be one company's stock.
        coalesce(v_line.sent_unit_cost, 0),
        'stock_transfers', p_id, v_line.id,
        'Received ' || v_t.transfer_no, auth.uid());
    end if;

    v_arrived := v_arrived + round(v_got * coalesce(v_line.sent_unit_cost, 0), 2);
    v_short   := v_short
      + round((v_line.sent_quantity - v_got) * coalesce(v_line.sent_unit_cost, 0), 2);
  end loop;

  if round(v_arrived, 2) <> 0 or round(v_short, 2) <> 0 then
    v_inv     := (select a.id from public.accounts a
                   where a.org_id = v_t.org_id and a.code = '1310');
    v_transit := app.goods_in_transit_account(v_t.org_id);

    v_lines := '[]'::jsonb;
    if round(v_arrived, 2) <> 0 then
      v_lines := v_lines || jsonb_build_object('account_id', v_inv,
        'description', 'Received ' || v_t.transfer_no,
        'debit', round(v_arrived, 2), 'credit', 0);
    end if;
    if round(v_short, 2) <> 0 then
      -- What left and never arrived. 5900 is where 0087 already puts a
      -- stock difference nobody can explain, and a transfer that loses
      -- a case is exactly that.
      v_shrink := (select a.id from public.accounts a
                    where a.org_id = v_t.org_id and a.code = '5900');
      if v_shrink is null then
        raise exception 'No inventory adjustment account (5900) in the chart.'
          using errcode = 'P0002';
      end if;
      v_lines := v_lines || jsonb_build_object('account_id', v_shrink,
        'description', 'Short on ' || v_t.transfer_no,
        'debit', round(v_short, 2), 'credit', 0);
    end if;
    v_lines := v_lines || jsonb_build_object('account_id', v_transit,
      'description', 'Out of transit ' || v_t.transfer_no,
      'debit', 0, 'credit', round(v_arrived + v_short, 2));

    v_entry := app.create_gl_entry_internal(
      v_t.org_id, v_on, 'stock_movement', v_lines,
      'Stock transfer received ' || v_t.transfer_no, 'stock_transfers', p_id);

    update public.stock_movements sm set gl_entry_id = v_entry
     where sm.source_table = 'stock_transfers' and sm.source_id = p_id
       and sm.movement_type = 'transfer_in' and sm.gl_entry_id is null;
  end if;

  update public.stock_transfers t
     set status = 'received', received_at = now(), received_by = auth.uid(),
         receipt_entry_id = v_entry, updated_at = now()
   where t.id = p_id;

  return v_entry;
end;
$function$;
