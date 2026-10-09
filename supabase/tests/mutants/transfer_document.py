# Mutants for public.transfer_document (0646) -- one document turned
# into the next in its cycle: never from a void, by somebody who may
# write, approved where a rule says so, not from an expired offer, made
# out to the customer and not the prospect, due on the terms, no line
# taken past what is left, and the header amounts shared by value.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0646_an_approval_nothing_ever_read.sql \
#       supabase/tests/transfer.sql \
#       supabase/tests/mutants/transfer_document.py
#
# RESULT: 31 mutants and a control. Against `transfer.sql` alone, 18
# killed and 13 survived -- and every one of the thirteen is killed by
# another file in the suite, run with the survivors alone (control
# surviving each time), so nothing was added:
#
#   approvals.sql                         the approval rule
#   document_dates.sql, transfer_shapes.sql  an expired offer
#   transfer_shapes.sql                   expiry on the LAST day (< vs <=),
#                                         no term means thirty days, the
#                                         bill naming its order
#   prospect_quotation.sql, transfer_shapes.sql  the prospect, both ways;
#                                         an invoice has a due date
#   transfer_carries_the_price_agreed.sql the branch, the header
#                                         discount shared, both totals
#                                         recomputed
#   document_dates.sql, transfer_shapes.sql  the delivery date carried
#
# The harness takes one test file, so a sweep against the obvious file
# understates the suite. Run the survivors against the rest before
# writing an assertion that already exists.

m("a void sales document is transferred",
  "transfer_document",
  "    if v_sales.deleted_at is not null or v_sales.status = 'void' then",
  "    if false then  -- void sale",
  "-- void sale")

m("a document that does not exist is not said so",
  "transfer_document",
  "      raise exception 'Document % not found', p_source_id using errcode = 'P0002';",
  "      raise notice 'Document % not found', p_source_id;  -- not found said only",
  "-- not found said only")

m("a void purchase document is transferred",
  "transfer_document",
  "    if v_purchase.deleted_at is not null or v_purchase.status = 'void' then",
  "    if false then  -- void purchase",
  "-- void purchase")

m("anybody transfers",
  "transfer_document",
  "  if not app.can_write(v_org) then",
  "  if false then  -- anybody",
  "-- anybody")

m("an approval rule is not read",
  "transfer_document",
  "     and not app.is_approved(v_org, v_kind, p_source_id) then",
  "     and false then  -- unapproved",
  "-- unapproved")

m("an expired offer is transferred",
  "transfer_document",
  "     and v_sales.valid_until < app.today() then",
  "     and false then  -- expired",
  "-- expired")

m("an offer is expired on its last day",
  "transfer_document",
  "     and v_sales.valid_until < app.today() then",
  "     and v_sales.valid_until <= app.today() then  -- last day",
  "-- last day")

m("a prospect's offer is made out to the prospect",
  "transfer_document",
  "    if v_holder.contact_type = 'prospect' then",
  "    if false then  -- not a prospect",
  "-- not a prospect")

m("the customer record is resolved and then not used",
  "transfer_document",
  "      v_contact, v_person, v_address,",
  "      v_sales.contact_id, v_person, v_address,  -- prospect kept",
  "-- prospect kept")

m("an invoice ignores its payment term",
  "transfer_document",
  "    v_due := app.today() + coalesce(v_term_days, 30);",
  "    v_due := app.today() + 30;  -- term ignored",
  "-- term ignored")

m("with no term an invoice falls due at once",
  "transfer_document",
  "    v_due := app.today() + coalesce(v_term_days, 30);",
  "    v_due := app.today() + coalesce(v_term_days, 0);  -- due now",
  "-- due now")

m("an invoice has no due date",
  "transfer_document",
  "  if p_target_type in ('invoice', 'bill') then",
  "  if false then  -- undated",
  "-- undated")

m("the branch is not carried",
  "transfer_document",
  "      v_sales.branch_id,",
  "      null,  -- branchless",
  "-- branchless")

m("the promised delivery date is dropped",
  "transfer_document",
  "      case when p_target_type in ('sales_order', 'delivery_order')",
  "      case when false  -- undelivered",
  "-- undelivered")

m("the new sale does not name its source",
  "transfer_document",
  "      v_sales.reference, v_sales.subject, v_sales.id,",
  "      v_sales.reference, v_sales.subject, null,  -- orphan",
  "-- orphan")

m("a sales line is taken past what is left",
  "transfer_document",
  "      if v_want > v_left then\n        raise exception\n          'Line % has % outstanding; % was asked for.',\n          r.line_no, v_left, v_want using errcode = '23514';\n      end if;\n\n      v_no := v_no + 1;\n      insert into public.sales_document_lines (",
  "      if false then  -- over (sales)\n        raise exception\n          'Line % has % outstanding; % was asked for.',\n          r.line_no, v_left, v_want using errcode = '23514';\n      end if;\n\n      v_no := v_no + 1;\n      insert into public.sales_document_lines (",
  "-- over (sales)")

m("an invoice counts what was delivered, not what was invoiced",
  "transfer_document",
  "        when 'quantity_invoiced' then r.quantity_invoiced",
  "        when 'quantity_invoiced' then r.quantity_fulfilled  -- wrong counter",
  "-- wrong counter")

m("a sales discount is carried whole onto part of a line",
  "transfer_document",
  "        -- carried whole onto a partial transfer.\n        case when r.quantity = 0 then 0\n             else round(r.discount_amount * v_want / r.quantity, 2) end,",
  "        -- carried whole onto a partial transfer.\n        case when r.quantity = 0 then 0\n             else r.discount_amount end,  -- whole discount",
  "-- whole discount")

m("the service period is dropped",
  "transfer_document",
  "        r.service_start, r.service_end",
  "        null, null  -- no period",
  "-- no period")

m("a delivery charge with no lines to share it goes on a partial transfer",
  "transfer_document",
  "      -- none of it on a partial one.\n      when v_src_net = 0 then case when p_lines is null then 1 else 0 end",
  "      -- none of it on a partial one.\n      when v_src_net = 0 then 1  -- all of it",
  "-- all of it")

m("the delivery charge is carried whole",
  "transfer_document",
  "       set shipping_amount = round(coalesce(v_sales.shipping_amount, 0) * v_share, 2),",
  "       set shipping_amount = round(coalesce(v_sales.shipping_amount, 0), 2),  -- whole shipping",
  "-- whole shipping")

m("the header discount is carried whole",
  "transfer_document",
  "           discount_amount = round(coalesce(v_sales.discount_amount, 0) * v_share, 2),",
  "           discount_amount = round(coalesce(v_sales.discount_amount, 0), 2),  -- whole discount h",
  "-- whole discount h")

m("the service charge is dropped",
  "transfer_document",
  "             round(coalesce(v_sales.service_charge_amount, 0) * v_share, 2)",
  "             0  -- no service charge",
  "-- no service charge")

m("the sale's totals are not recomputed",
  "transfer_document",
  "    update public.sales_document_lines\n       set line_no = line_no where document_id = v_new_id;",
  "    perform 1;  -- stale sale",
  "-- stale sale")

m("the new purchase does not name its source",
  "transfer_document",
  "      v_purchase.reference, v_purchase.id, v_purchase.payment_term_id,",
  "      v_purchase.reference, null, v_purchase.payment_term_id,  -- orphan p",
  "-- orphan p")

m("a purchase line is taken past what is left",
  "transfer_document",
  "      if v_want > v_left then\n        raise exception\n          'Line % has % outstanding; % was asked for.',\n          r.line_no, v_left, v_want using errcode = '23514';\n      end if;\n\n      v_no := v_no + 1;\n      insert into public.purchase_document_lines (",
  "      if false then  -- over (purchase)\n        raise exception\n          'Line % has % outstanding; % was asked for.',\n          r.line_no, v_left, v_want using errcode = '23514';\n      end if;\n\n      v_no := v_no + 1;\n      insert into public.purchase_document_lines (",
  "-- over (purchase)")

m("a bill counts what was received, not what was billed",
  "transfer_document",
  "        when 'quantity_billed' then r.quantity_billed",
  "        when 'quantity_billed' then r.quantity_received  -- wrong counter p",
  "-- wrong counter p")

m("the carriage on a purchase is carried whole",
  "transfer_document",
  "       set shipping_amount = round(coalesce(v_purchase.shipping_amount, 0) * v_share, 2),",
  "       set shipping_amount = round(coalesce(v_purchase.shipping_amount, 0), 2),  -- whole carriage",
  "-- whole carriage")

m("the purchase's totals are not recomputed",
  "transfer_document",
  "    update public.purchase_document_lines\n       set line_no = line_no where document_id = v_new_id;",
  "    perform 1;  -- stale purchase",
  "-- stale purchase")

m("an empty document is left behind",
  "transfer_document",
  "  if v_no = 0 then",
  "  if false then  -- empty doc",
  "-- empty doc")

m("CONTROL: a comment inside the block",
  "transfer_document",
  "  if v_no = 0 then",
  "  if v_no = 0 then  -- (control)",
  "(control)")
