# iAkauntan

A Flutter (web/Android/iOS) front end over a Supabase Postgres back end:
accounting, CRM, HR and payroll, corporate secretarial and LHDN e-Invoice for
Malaysian businesses. `README.md` is the real orientation — read it before
changing anything statutory.

Two things to know before you touch the code:

- **The database is the application.** Business rules live in SQL — numbered,
  append-only migrations in `supabase/migrations/`, applied in order and never
  edited once applied. Permissions are RLS policies plus `app.can_*` guards
  inside SECURITY DEFINER functions. A rule enforced only in Dart is not
  enforced.
- **Statutory arithmetic is asserted, not eyeballed.** `supabase/tests/*.sql`
  runs in CI. Anything touching EPF, SOCSO, EIS, PCB or an SSM deadline needs a
  test that would fail if the number moved.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
