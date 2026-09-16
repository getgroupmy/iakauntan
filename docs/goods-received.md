# The goods received note, and the stock it never received

## What was wrong

A goods received note received no goods. Measured against the schema as
it shipped, buying the same ten units two ways:

```
PO -> Bill          : 1 movement(s), 10.0000 received
PO -> GRN -> Bill   : 0 movement(s), 0 received
```

`app.post_purchase_document_internal` has carried this since `0013`:

```sql
-- Receive stock unless a goods-received note already did.
if not exists (
  select 1 from public.purchase_documents d
   where d.id = v_doc.parent_id and d.doc_type = 'goods_received'
) then
```

The comment is right about what it intends and wrong about the world.
Nothing anywhere ever received stock on a goods received note: there was
no `post_goods_received`, no trigger, and the only three statements in
the schema that write a `purchase_receipt` movement were the three
successive restatements of that same function — `0013`, `0097`, `0270` —
each skipping for the same reason.

So the bill skipped, the note had done nothing, and the stock was simply
short. The ledger was not: the supplier was still owed, the input tax was
still claimed, the journal still balanced. Only the stock figure was
wrong, and nothing on any screen said so.

`0609` fixes it forwards. **It does not backfill.**

## What a company that used this path has to do

Count the stock.

Nothing can be backfilled safely. A movement written now would land on
today's date, at today's valuation, and walk into a period that may be
closed. The quantity that was missed is knowable — it is the sum of the
item lines on every posted goods received note that has no stock
movement against it — but the DATE it should have landed on is not
something a migration may decide on a company's behalf, and the value
depends on which costing pass it would have joined.

To find out how much is at stake:

```sql
select d.doc_no,
       d.doc_date,
       i.code,
       i.name,
       coalesce(l.base_quantity, l.quantity) as never_received
  from public.purchase_documents d
  join public.purchase_document_lines l on l.document_id = d.id
  join public.items i on i.id = l.item_id
 where d.org_id = :org
   and d.doc_type = 'goods_received'
   and l.line_type = 'item'
   and i.track_inventory
   and not exists (select 1 from public.stock_movements m
                    where m.source_table = 'purchase_documents'
                      and m.source_id = d.id)
 order by d.doc_date;
```

Every row is stock that arrived and was never recorded. Correct it with a
stock adjustment dated when you choose, in an open period, which is what
a stock count produces anyway.

A company that has only ever gone from purchase order straight to bill is
not affected: that path always received the goods, and
`goods_received.sql` asserts it still does.

## How it works now

The note is an accounting event, because the goods arriving is one:

```
goods received note   Dr Inventory        Cr 2118 Goods Received Not Invoiced
supplier's bill       Dr 2118 GRNI        Cr Accounts Payable
                      Dr Input tax
```

The two together are exactly what the direct path posts. That is the
assertion `supabase/tests/goods_received.sql` opens with: buy the same
thing both ways and every account ends on the same figure.

Leaving the note unposted and merely writing the stock movement was the
smaller change and was not available. This schema is perpetual —
`track_inventory` items capitalise into `1310` rather than expensing — so
stock that exists with no ledger entry behind it is a balance sheet that
disagrees with the stock valuation report for as long as the bill takes
to arrive, which is precisely the period the document exists to describe.

### Where the price differs

If the bill charges more than the receiving note said — a line edited
after transfer, a supplier who invoiced above the order — the difference
stays in `2118` rather than being absorbed. That is a purchase price
variance and it is meant to be visible. Clear it deliberately; a balance
sitting in `2118` with no outstanding receipt behind it is telling you
something.

### Service lines

A receiving note refuses to post if nothing on it is stock. Nothing
arrived, nothing goes on a shelf, and capitalising a service into
inventory would be worse than saying so. Put it on the bill.
