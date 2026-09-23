import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1.0.19";
import {
  type Ctx,
  HttpError,
  loadCredentials,
  persistLogs,
  requirePostingRole,
} from "./context.ts";

/**
 * Which company's credentials, and which environment's.
 *
 * `buildContext` is not tested here: it calls `createClient` and reads
 * a real JWT. What IS testable is everything after it, and two of those
 * decide where a statutory document goes.
 *
 * `loadCredentials` takes the environment from the ORGANIZATION and
 * then filters the credentials on it. Its own comment records why:
 * since `0107` an organization holds sandbox AND production at once, so
 * the earlier version -- selecting on `org_id` alone -- matched two
 * rows and `maybeSingle()` threw on the second set somebody
 * configured. Getting this wrong now is quieter and worse: sandbox
 * credentials against production is a rejected submission, and
 * production credentials against a sandbox test is a real invoice filed
 * with LHDN.
 *
 * The Supabase client is faked rather than stubbed, so the test can
 * assert WHICH FILTERS were applied rather than only what came back.
 */

// deno-lint-ignore no-explicit-any
type Row = Record<string, any>;

/** A chainable stand-in that records every `.eq()` it was given. */
function fakeAdmin(tables: Record<string, Row | null>) {
  const seen: { table: string; filters: Row }[] = [];
  const inserted: { table: string; rows: Row[] }[] = [];

  const admin = {
    from(table: string) {
      const filters: Row = {};
      const chain = {
        select: () => chain,
        eq(column: string, value: unknown) {
          filters[column] = value;
          return chain;
        },
        maybeSingle() {
          seen.push({ table, filters });
          return Promise.resolve({ data: tables[table] ?? null, error: null });
        },
        insert(rows: Row[]) {
          inserted.push({ table, rows });
          return Promise.resolve({ data: null, error: null });
        },
      };
      return chain;
    },
  };
  return { admin, seen, inserted };
}

function ctxWith(admin: unknown, over: Partial<Ctx> = {}): Ctx {
  return {
    // deno-lint-ignore no-explicit-any
    userClient: {} as any,
    // deno-lint-ignore no-explicit-any
    admin: admin as any,
    userId: "u-1",
    orgId: "org-1",
    role: "admin",
    body: {},
    ...over,
  };
}

Deno.test("credentials are filtered by the organization's environment", async () => {
  const { admin, seen } = fakeAdmin({
    organizations: { einvoice_environment: "production" },
    einvoice_credentials: {
      client_id: "cid",
      client_secret: "shh",
      environment: "production",
    },
  });

  const creds = await loadCredentials(ctxWith(admin));
  assertEquals(creds.environment, "production");

  // The part the comment is about: BOTH org_id and environment. With
  // org_id alone this matches the sandbox row too, and maybeSingle
  // throws on the second.
  const q = seen.find((s) => s.table === "einvoice_credentials")!;
  assertEquals(q.filters.org_id, "org-1");
  assertEquals(q.filters.environment, "production");
});

Deno.test("and the environment is read off the organization, not the row", async () => {
  // A credentials row that disagrees with the organization must not
  // decide the question -- the org's setting is what says which one is
  // in force.
  const { admin, seen } = fakeAdmin({
    organizations: { einvoice_environment: "sandbox" },
    einvoice_credentials: {
      client_id: "cid",
      client_secret: "shh",
      environment: "sandbox",
    },
  });
  await loadCredentials(ctxWith(admin));
  assertEquals(
    seen.find((s) => s.table === "einvoice_credentials")!.filters.environment,
    "sandbox",
  );
});

Deno.test("an organization with no setting is sandbox, not production", async () => {
  // The safe direction. A company that has configured nothing must not
  // file a real invoice with LHDN by default.
  const { admin, seen } = fakeAdmin({
    organizations: null,
    einvoice_credentials: {
      client_id: "cid",
      client_secret: "shh",
      environment: "sandbox",
    },
  });
  const creds = await loadCredentials(ctxWith(admin));
  assertEquals(creds.environment, "sandbox");
  assertEquals(
    seen.find((s) => s.table === "einvoice_credentials")!.filters.environment,
    "sandbox",
  );
});

Deno.test("missing credentials say which environment and where to add them", async () => {
  const { admin } = fakeAdmin({
    organizations: { einvoice_environment: "production" },
    einvoice_credentials: null,
  });

  const err = await assertRejects(
    () => loadCredentials(ctxWith(admin)),
    HttpError,
  );
  assertEquals(err.status, 400);
  // Naming the environment matters: a company that has configured
  // sandbox and switched to production sees a message about the one it
  // is missing rather than a flat "not configured".
  assertEquals(err.message.includes("production"), true);
  assertEquals(err.message.includes("Settings > e-Invoice"), true);
});

Deno.test("the credentials are scoped to the caller's own organization", async () => {
  const { admin, seen } = fakeAdmin({
    organizations: { einvoice_environment: "sandbox" },
    einvoice_credentials: {
      client_id: "cid",
      client_secret: "shh",
      environment: "sandbox",
    },
  });
  await loadCredentials(ctxWith(admin, { orgId: "org-99" }));
  for (const q of seen) assertEquals(q.filters.id ?? q.filters.org_id, "org-99");
});

Deno.test("posting is owner, admin and accountant", () => {
  for (const role of ["owner", "admin", "accountant"]) {
    requirePostingRole(ctxWith(null, { role }), "submit an invoice");
  }
});

Deno.test("and nobody else, with their role named back to them", () => {
  // The control. Filing with LHDN is not something a viewer or a
  // clerk does, and a message that says which role they hold is the
  // difference between "ask your administrator" and a support ticket.
  for (const role of ["viewer", "accounts_clerk", "cashier", ""]) {
    const err = assertThrows(
      () => requirePostingRole(ctxWith(null, { role }), "submit an invoice"),
      HttpError,
    ) as HttpError;
    assertEquals(err.status, 403);
    assertEquals(err.message.includes(role), true);
    assertEquals(err.message.includes("submit an invoice"), true);
  }
});

Deno.test("no calls means no insert at all", async () => {
  const { admin, inserted } = fakeAdmin({});
  await persistLogs(ctxWith(admin), []);
  // An empty insert is a round trip that does nothing and a row count
  // somebody has to explain.
  assertEquals(inserted.length, 0);
});

Deno.test("and a call is written with every field LHDN expects kept", async () => {
  const { admin, inserted } = fakeAdmin({});
  await persistLogs(
    ctxWith(admin),
    [{
      operation: "submit",
      endpoint: "/api/v1.0/documentsubmissions",
      method: "POST",
      status: 202,
      requestBody: { a: 1 },
      responseBody: { b: 2 },
      durationMs: 41,
    // deno-lint-ignore no-explicit-any
    }] as any,
    { submissionId: "sub-1" },
  );

  assertEquals(inserted.length, 1);
  assertEquals(inserted[0].table, "einvoice_logs");
  const row = inserted[0].rows[0];
  assertEquals(row.org_id, "org-1");
  assertEquals(row.submission_id, "sub-1");
  // The trail LHDN expects retained for seven years, so a field
  // dropped here is a gap in an audit nobody notices for years.
  assertEquals(row.operation, "submit");
  assertEquals(row.http_method, "POST");
  assertEquals(row.http_status, 202);
  assertEquals(row.duration_ms, 41);
  assertEquals(row.request_body, { a: 1 });
  assertEquals(row.response_body, { b: 2 });
  // Absent optional fields are null rather than undefined, which
  // postgrest would otherwise drop from the row entirely.
  assertEquals(row.einvoice_id, null);
  assertEquals(row.error_message, null);
});
