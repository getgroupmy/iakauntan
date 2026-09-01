# Indexes, and why 610 of them were not added

Nothing in this repository had looked at performance. This is the record
of the one time somebody did, what was measured, and why the obvious
change was not made — written down so the next person does not repeat
the analysis, and knows what to measure when there is data.

## The structural observation

PostgreSQL indexes the *referenced* side of a foreign key automatically,
because that side is a primary or unique key. It never indexes the
*referencing* side. So a schema accumulates unindexed foreign keys
unless somebody adds them deliberately.

Counted on a freshly migrated database:

| | |
|---|---|
| single-column foreign keys in `public` | 986 |
| of those, whose column leads no index | **610** |
| tables carrying `org_id` where `org_id` leads no index | 93 |

That is the classic omission, and on a multi-tenant schema where every
RLS policy filters by `org_id` it looks alarming.

## What the production statistics actually say

`pg_stat_user_tables` on the hosted project, ordered by sequential
scans:

| table | seq_scan | idx_scan | live rows | size |
|---|---|---|---|---|
| `organizations` | 198,196 | 13,850 | 8 | 16 kB |
| `org_members` | 92,588 | 7,329 | 10 | 8 kB |
| `payroll_settings` | 37,258 | 183 | 0 | 8 kB |
| `items` | 18,424 | 7,544 | 19 | 24 kB |
| `contacts` | 18,396 | 2,689 | 26 | 24 kB |
| `sales_documents` | 10,572 | 13,091 | 78 | 96 kB |
| `gl_entries` | 6,576 | 24,169 | 149 | 192 kB |
| `payslip_lines` | 3,649 | 499 | 217 | 56 kB |

Every one of those tables is **one to a few pages**. At that size a
sequential scan is not the planner failing to use an index; it is the
planner correctly declining to, because reading the single page the
table occupies is cheaper than descending a B-tree and then reading it
anyway. `organizations` scanned 198,196 times is 198,196 single-page
reads.

So there is no measurable performance problem, and — this is the part
worth being precise about — **these statistics cannot tell us whether
there would be one at scale.** They are evidence about a database with
eight organizations in it. They are not evidence that the 610 are
harmless when a company has three years of ledger in it.

## Why the indexes were not added anyway

Three reasons, in order of weight.

1. **No evidence of which ones to add.** An index earns its place
   against a query shape. The attempt to infer those shapes from the
   client — pairing `.eq('column', …)` in `app/lib` against the
   unindexed columns — matched 198 of them, but only by *column name*:
   it could not tell which table each `.eq` was written against, so
   `item_id` filtered on one table appeared to justify an index on
   every table with an `item_id`. That is not evidence, and indexes
   chosen from it would be guesses with a maintenance cost.

2. **Most of the 610 are on line tables that are never queried by that
   column.** `einvoice_lines` is read by `einvoice_id`, `bom_lines` by
   `bom_id`. Where the parent id *is* indexed, the planner finds the
   handful of rows by that index and applies the `org_id` predicate to
   them; an `org_id` index on such a table would never be chosen.

3. **Every index is paid for on every write.** This schema's hot path is
   writing — posting documents, payroll runs, POS sales — and 610 extra
   B-trees is a cost taken on every one of those, forever, against a
   benefit nobody has measured.

## What to measure when there is data

Re-run this, which is the only version of the question worth asking —
unindexed foreign keys **on tables large enough for it to matter**,
ordered by how often they are actually scanned:

```sql
select t.relname, a.attname, s.seq_scan, s.idx_scan, s.n_live_tup,
       pg_size_pretty(pg_relation_size(t.oid)) as size
  from pg_constraint c
  join pg_class t on t.oid = c.conrelid
  join pg_namespace n on n.oid = t.relnamespace
  join pg_attribute a on a.attrelid = t.oid and a.attnum = c.conkey[1]
  join pg_stat_user_tables s on s.relid = t.oid
 where c.contype = 'f' and n.nspname = 'public'
   and array_length(c.conkey, 1) = 1
   and not exists (select 1 from pg_index i
                    where i.indrelid = c.conrelid
                      and i.indkey[0] = c.conkey[1])
   and s.n_live_tup > 10000          -- the threshold is the point
 order by s.seq_scan desc;
```

The threshold is what makes it an engineering question rather than a
principle. Below it, adding the index is a write cost with no read
benefit; above it, the seq_scan column says which ones are being paid
for and how often.

Two things worth knowing before acting on the result:

- **`explain (analyze, buffers)` the actual query**, not the table.
  A sequential scan on a table the planner has correctly sized is not
  a defect, and `seq_scan` alone cannot distinguish the two.
- **Deleting an organization is the one case that does not depend on
  volume.** Every foreign key referencing a row being deleted forces a
  check of the referencing table, indexed or not, so
  `close_my_account` and the demo teardown scan several hundred tables
  by construction. If either becomes slow, that is where to look, and
  the fix is indexes on the `org_id` columns specifically — a much
  smaller and better-motivated set than 610.
