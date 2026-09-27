/**
 * The signature is the security boundary, so it is the thing asserted.
 *
 *   deno test supabase/functions/_shared/billplz_test.ts
 *
 * `billplz-callback` is the first function in this project deployed
 * with `verify_jwt = false`. It has to be: Billplz's servers hold no
 * session with us, and a payment confirmation that could only arrive
 * with a JWT would never arrive. What stands in its place is an HMAC
 * over the callback's own fields, and everything below is about that
 * one substitution being sound.
 *
 * No permissions are needed to run this — no network, no environment,
 * no disk. If that ever stops being true it is worth noticing, which is
 * why CI runs it with no flags.
 *
 * The vectors here are computed from Billplz's published construction
 * rule rather than lifted from a page fetched at the time; their site
 * was unreachable from where this was written, and `billplz.ts` says so
 * at length. What that means for these tests is that they assert the
 * rule is implemented consistently and cannot be bypassed — not that
 * the rule is transcribed correctly. The second half is a five-minute
 * check against a sandbox callback and it has to be done before this
 * goes live. It fails safe in the meantime: a wrong source string
 * rejects every real callback rather than accepting a forged one.
 */
import {
  assert,
  assertEquals,
  assertNotEquals,
  assertThrows,
} from "jsr:@std/assert@1.0.19";

import {
  billplzApiBase,
  billplzSignature,
  billplzSourceString,
  flattenRedirectParams,
  toSen,
  verifyBillplzSignature,
} from "./billplz.ts";

const KEY = "S-signature-key-nobody-else-has";

/** A callback shaped the way Billplz sends one. */
const CALLBACK = {
  id: "W_break",
  collection_id: "inbmmepb",
  paid: "true",
  state: "paid",
  amount: "50000",
  paid_amount: "50000",
  due_at: "2026-09-30",
  email: "akaun@contoh.my",
  mobile: "+60123456789",
  name: "Contoh Sdn Bhd",
  url: "https://www.billplz.com/bills/W_break",
  paid_at: "2026-08-23 16:04:12 +0800",
};

Deno.test("the source string is sorted, joined, and excludes the signature", () => {
  const source = billplzSourceString({ ...CALLBACK, x_signature: "deadbeef" });

  assertEquals(
    source,
    "amount50000|collection_idinbmmepb|due_at2026-09-30|emailakaun@contoh.my|" +
      "idW_break|mobile+60123456789|nameContoh Sdn Bhd|paidtrue|" +
      "paid_amount50000|paid_at2026-08-23 16:04:12 +0800|statepaid|" +
      "urlhttps://www.billplz.com/bills/W_break",
  );

  // The signature is not signed by itself. Including it would make the
  // check unfalsifiable in the worst way: any value would verify,
  // because it would be part of what was hashed.
  assert(!source.includes("deadbeef"));
});

Deno.test("paid, paid_amount and paid_at sort the way bytes sort", () => {
  // The one ordering a locale-aware collation gets wrong, and the
  // reason the implementation sorts by code unit. `paid_amount` before
  // `paid_at` because 'm' is before 't'.
  const source = billplzSourceString({
    paid_at: "x",
    paid: "y",
    paid_amount: "z",
  });
  assertEquals(source, "paidy|paid_amountz|paid_atx");
});

Deno.test("the order the fields arrive in does not change the signature", async () => {
  const forwards = await billplzSignature(CALLBACK, KEY);
  const backwards = await billplzSignature(
    Object.fromEntries(Object.entries(CALLBACK).reverse()),
    KEY,
  );
  assertEquals(forwards, backwards);
  // 32 bytes of SHA-256, hex.
  assertEquals(forwards.length, 64);
});

Deno.test("a genuine callback verifies", async () => {
  const signature = await billplzSignature(CALLBACK, KEY);
  assert(await verifyBillplzSignature(CALLBACK, signature, KEY));
  // Billplz sends it lower case; a proxy that upper-cased it, or a
  // stray space from a form parser, must not cost a customer their
  // payment.
  assert(await verifyBillplzSignature(CALLBACK, signature.toUpperCase(), KEY));
  assert(await verifyBillplzSignature(CALLBACK, ` ${signature} `, KEY));
});

Deno.test("changing any field at all invalidates it", async () => {
  const signature = await billplzSignature(CALLBACK, KEY);

  for (const field of Object.keys(CALLBACK)) {
    const tampered = { ...CALLBACK, [field]: `${CALLBACK[field as keyof typeof CALLBACK]}0` };
    assert(
      !(await verifyBillplzSignature(tampered, signature, KEY)),
      `tampering with ${field} was accepted`,
    );
  }

  // The two that would actually be worth forging, spelled out: an
  // unpaid bill claiming to be paid, and a paid one claiming to be
  // worth more than was handed over.
  assert(!(await verifyBillplzSignature(
    { ...CALLBACK, paid: "true", state: "paid" },
    await billplzSignature({ ...CALLBACK, paid: "false", state: "due" }, KEY),
    KEY,
  )));
  assert(!(await verifyBillplzSignature(
    { ...CALLBACK, paid_amount: "50000" },
    await billplzSignature({ ...CALLBACK, paid_amount: "1" }, KEY),
    KEY,
  )));
});

Deno.test("adding a field invalidates it too", async () => {
  // A caller who appends their own parameter changes what is signed, so
  // an otherwise genuine signature stops matching. That is the correct
  // outcome: a payload we would act on must be exactly the one Billplz
  // signed, not a superset somebody assembled.
  const signature = await billplzSignature(CALLBACK, KEY);
  assert(
    !(await verifyBillplzSignature(
      { ...CALLBACK, org_id: "somebody-elses" },
      signature,
      KEY,
    )),
  );
});

Deno.test("the wrong key does not verify", async () => {
  const signature = await billplzSignature(CALLBACK, KEY);
  assert(!(await verifyBillplzSignature(CALLBACK, signature, `${KEY}!`)));
});

Deno.test("no key configured refuses everything", async () => {
  // The failure this whole module exists to not have. Deployed before
  // anybody set BILLPLZ_XSIGNATURE_KEY, an implementation that hashed
  // under "" would accept a callback from anyone who worked that out —
  // and every invoice on the platform could be marked paid by a
  // stranger with a curl command.
  //
  // Two halves. Verification refuses before it computes anything, so a
  // signature that is genuine under a real key still gets nowhere when
  // the deployment has no key to check it with:
  const genuine = await billplzSignature(CALLBACK, KEY);
  assert(!(await verifyBillplzSignature(CALLBACK, genuine, "")));
  assert(!(await verifyBillplzSignature(CALLBACK, genuine, null)));
  assert(!(await verifyBillplzSignature(CALLBACK, genuine, undefined)));

  // And signing refuses by name rather than letting WebCrypto throw
  // `DataError: Key length is zero` three frames down, which says
  // nothing about which secret was missing.
  assertThrows(() => billplzSignature(CALLBACK, ""), Error, "BILLPLZ_XSIGNATURE_KEY");
});

Deno.test("no signature is not a signature that matched", async () => {
  assert(!(await verifyBillplzSignature(CALLBACK, null, KEY)));
  assert(!(await verifyBillplzSignature(CALLBACK, undefined, KEY)));
  assert(!(await verifyBillplzSignature(CALLBACK, "", KEY)));
  assert(!(await verifyBillplzSignature(CALLBACK, "   ", KEY)));
});

Deno.test("the redirect's bracketed names flatten to what they sign", async () => {
  const query = new URLSearchParams({
    "billplz[id]": "W_break",
    "billplz[paid]": "true",
    "billplz[paid_at]": "2026-08-23 16:04:12 +0800",
    "billplz[x_signature]": "not-checked-here",
    // The payer controls this URL. Anything they append is dropped
    // rather than fed into the check.
    "utm_source": "whatever",
    "org_id": "somebody-elses",
  });

  const flat = flattenRedirectParams(query);
  assertEquals(flat, {
    billplzid: "W_break",
    billplzpaid: "true",
    billplzpaid_at: "2026-08-23 16:04:12 +0800",
    billplzx_signature: "not-checked-here",
  });

  assertEquals(
    billplzSourceString({ ...flat, x_signature: "ignored" }),
    "billplzidW_break|billplzpaidtrue|" +
      "billplzpaid_at2026-08-23 16:04:12 +0800|" +
      "billplzx_signaturenot-checked-here",
  );

  // The redirect is a courtesy — it tells the browser what happened.
  // It is signed, so it can be checked, but nothing is settled on it.
  const signature = await billplzSignature(flat, KEY);
  assert(await verifyBillplzSignature(flat, signature, KEY));
});

Deno.test("sandbox and live are different hosts", () => {
  assertEquals(billplzApiBase("live"), "https://www.billplz.com/api/v3");
  assertEquals(
    billplzApiBase("sandbox"),
    "https://www.billplz-sandbox.com/api/v3",
  );
  // Anything that is not the word "live" is the sandbox. A gateway row
  // saved with an empty or misspelled mode must not start taking real
  // money.
  assertEquals(billplzApiBase(""), billplzApiBase("sandbox"));
  assertEquals(billplzApiBase("LIVE"), billplzApiBase("sandbox"));
  assertEquals(billplzApiBase("production"), billplzApiBase("sandbox"));
  assertNotEquals(billplzApiBase("live"), billplzApiBase("sandbox"));
});

Deno.test("ringgit convert to sen without losing one", () => {
  assertEquals(toSen(5), 500);
  assertEquals(toSen(0.1), 10);
  // The case a truncation gets wrong: 12.34 * 100 is
  // 1233.9999999999998 in binary floating point, and `Math.trunc` of
  // that is 1233 — a sen short, on every invoice that lands badly.
  assertEquals(toSen(12.34), 1234);
  assertEquals(toSen(499.99), 49999);
  assertEquals(toSen(1_000_000), 100_000_000);
});

Deno.test("every amount an invoice can actually hold converts exactly", () => {
  // `platform_invoices.total_amount` is numeric(18,2), so an amount
  // with a third decimal never arrives and there is nothing here to
  // round — the only question is whether two decimals survive the trip
  // through a double. Ten thousand of them, including every one of the
  // hundred possible sen endings, say yes.
  //
  // Worth saying because the first draft of this test asserted
  // toSen(1.005) === 101 and was simply wrong: 1.005 is
  // 1.00499999999999989 as a double, so 100 is the correct answer and
  // the test was describing a number that cannot reach this function.
  for (let sen = 0; sen <= 1_000_000; sen += 97) {
    const ringgit = Number((sen / 100).toFixed(2));
    assertEquals(toSen(ringgit), sen, `RM${ringgit.toFixed(2)}`);
  }
});
