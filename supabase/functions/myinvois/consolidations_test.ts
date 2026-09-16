import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { DueRow, periodLabel, whyNot } from "./consolidations.ts";

/**
 * Which companies the scheduler leaves alone, and what it says about
 * them.
 *
 * The decision is pure and is asserted here because the alternative is
 * finding out from MyInvois. A company with no credentials attempted
 * anyway spends a call to be told what the database already knew, and
 * buries the real problem — somebody never finished the setup — inside
 * a transport error on a report nobody reads twice.
 *
 * Each sentence names the setup step, because the person who reads this
 * report is the person who has to do it. That is asserted too: a report
 * saying "skipped: not configured" is a report that has to be taken to
 * somebody else.
 */
function aDueRow(overrides: Partial<DueRow> = {}): DueRow {
  return {
    org_id: "11111111-1111-1111-1111-111111111111",
    org_name: "Kedai Konsolidasi Sdn Bhd",
    consolidation_id: "22222222-2222-2222-2222-222222222222",
    period_start: "2026-08-01",
    period_end: "2026-08-31",
    due_date: "2026-09-07",
    days_left: 2,
    document_count: 148,
    total_amount: 9_431.5,
    status: "generated",
    einvoice_id: null,
    environment: "production",
    einvoice_version: "1.0",
    has_credentials: true,
    has_certificate: false,
    ...overrides,
  };
}

Deno.test("a company that is ready is not skipped", () => {
  assertEquals(whyNot(aDueRow()), null);
});

Deno.test("no credentials names the screen to add them on", () => {
  const why = whyNot(aDueRow({ has_credentials: false }));
  assertStringIncludes(why!, "production");
  assertStringIncludes(why!, "Settings > LHDN e-Invoice");
});

Deno.test("and names the environment it is missing them for", () => {
  // A company with sandbox credentials and none for production is the
  // ordinary shape of a half-finished switch to live, and "no
  // credentials" alone sends somebody to look at the ones they can see.
  const why = whyNot(aDueRow({ has_credentials: false, environment: "sandbox" }));
  assertStringIncludes(why!, "sandbox");
});

Deno.test("1.1 with no certificate is skipped, with both ways out", () => {
  const why = whyNot(
    aDueRow({ einvoice_version: "1.1", has_certificate: false }),
  );
  assertStringIncludes(why!, "1.1");
  assertStringIncludes(why!, "signing certificate");
  // Load one, or go back to 1.0. Naming only the first would tell a
  // shop with no certificate to hand that it cannot file at all.
  assertStringIncludes(why!, "back to 1.0");
});

Deno.test("1.1 WITH a certificate is not skipped", () => {
  assertEquals(
    whyNot(aDueRow({ einvoice_version: "1.1", has_certificate: true })),
    null,
  );
});

Deno.test("1.0 does not need a certificate", () => {
  // The control for the rule above: a 1.0 document carries no
  // signature, so the missing certificate is not a reason to skip and
  // a check that forgot the version would stop every unsigned filing.
  assertEquals(whyNot(aDueRow({ has_certificate: false })), null);
});

Deno.test("an empty consolidation is skipped rather than filed as nothing", () => {
  // Filing a zero-value e-Invoice is a statement to LHDN that the shop
  // sold nothing, which is a different claim from not having filed.
  assertStringIncludes(whyNot(aDueRow({ document_count: 0 }))!, "nothing");
});

Deno.test("the credentials are checked before the certificate", () => {
  // A company missing both is told about the credentials, because that
  // is the first step and the certificate cannot be loaded without it
  // — `set_einvoice_signing_certificate` refuses.
  const why = whyNot(
    aDueRow({
      has_credentials: false,
      einvoice_version: "1.1",
      has_certificate: false,
    }),
  );
  assertStringIncludes(why!, "credentials");
});

Deno.test("the period reads as a period", () => {
  assertEquals(periodLabel(aDueRow()), "2026-08-01 to 2026-08-31");
});

Deno.test("an overdue row is still a row to act on", () => {
  // `days_left` is negative and nothing here looks at it. The list
  // itself is what decides; a skip based on lateness would quietly
  // abandon the filings that matter most.
  assertEquals(whyNot(aDueRow({ days_left: -40 })), null);
});
