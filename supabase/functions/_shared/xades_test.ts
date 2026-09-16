import { assertEquals, assertRejects, assertStringIncludes } from "jsr:@std/assert@1";
import { pemToDer, readCertificate, toBase64 } from "./der.ts";
import {
  buildQualifyingProperties,
  prepareForDigest,
  SIGNED_VERSION,
  signUblJsonDocument,
  signingTimestamp,
  verifySignedUblJsonDocument,
} from "./xades.ts";

/**
 * The signature a 1.1 e-Invoice carries.
 *
 * ## No private key is committed, and none is needed
 *
 * A signing test wants a certificate and the key that matches it, and
 * this repository's own rule is that a private key is never in it. So
 * the key pair is generated here, in WebCrypto, every run — and the
 * certificate is the committed sample with the generated public key
 * spliced in where its own used to be. Both are RSA-2048, so the
 * SubjectPublicKeyInfo is the same length and the splice is byte for
 * byte.
 *
 * What that produces is a certificate whose own signature no longer
 * verifies, and nothing here checks that: LHDN checks the chain, this
 * checks the pair. Everything the signature depends on — the issuer,
 * the serial, the validity, and now the public key — is real.
 *
 * ## What these tests DO NOT prove
 *
 * That LHDN agrees about the shape. There is no sandbox credential in
 * this repository and `sdk.myinvois.hasil.gov.my` is unreachable from
 * the network this is built on, so the structure is written to the
 * published binding and agrees with two independent implementations of
 * it, and it has never been submitted. `docs/einvoice-signing.md` says
 * what closing that gap takes. What IS proved below is the half that
 * is arithmetic: both digests recompute from the emitted document and
 * the signature verifies against the certificate inside it, which is
 * the check LHDN performs.
 */
const SAMPLE = await Deno.readTextFile(
  new URL("./testdata/sample_certificate.pem", import.meta.url),
);

function toPem(der: Uint8Array, label: string): string {
  const body = toBase64(der).replace(/(.{64})/g, "$1\n").trimEnd();
  return `-----BEGIN ${label}-----\n${body}\n-----END ${label}-----\n`;
}

function indexOfBytes(haystack: Uint8Array, needle: Uint8Array): number {
  outer: for (let i = 0; i + needle.length <= haystack.length; i++) {
    for (let j = 0; j < needle.length; j++) {
      if (haystack[i + j] !== needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/** A certificate and the key that matches it, neither of them on disk. */
async function aRealPair(): Promise<{ certificatePem: string; privateKeyPem: string }> {
  const pair = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const spki = new Uint8Array(
    await crypto.subtle.exportKey("spki", pair.publicKey),
  );
  const pkcs8 = new Uint8Array(
    await crypto.subtle.exportKey("pkcs8", pair.privateKey),
  );

  const der = pemToDer(SAMPLE);
  const original = readCertificate(SAMPLE).publicKeyDer;
  const at = indexOfBytes(der, original);
  if (at < 0 || original.length !== spki.length) {
    throw new Error("The sample certificate is not RSA-2048 any more.");
  }
  const spliced = new Uint8Array(der);
  spliced.set(spki, at);

  return {
    certificatePem: toPem(spliced, "CERTIFICATE"),
    privateKeyPem: toPem(pkcs8, "PRIVATE KEY"),
  };
}

/** The shape `buildUblDocument` emits, cut down to what signing touches. */
function aDocument(): Record<string, unknown> {
  return {
    _D: "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2",
    _A: "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2",
    _B: "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2",
    Invoice: [{
      ID: [{ _: "INV-2026-000041" }],
      IssueDate: [{ _: "2026-09-16" }],
      IssueTime: [{ _: "14:30:00Z" }],
      InvoiceTypeCode: [{ _: "01", listVersionID: "1.0" }],
      DocumentCurrencyCode: [{ _: "MYR" }],
      LegalMonetaryTotal: [{
        PayableAmount: [{ _: 1234.56, currencyID: "MYR" }],
      }],
    }],
  };
}

/** Walks to the signature block of a signed document. */
// deno-lint-ignore no-explicit-any
function signatureOf(doc: any): any {
  return doc.Invoice[0].UBLExtensions[0].UBLExtension[0]
    .ExtensionContent[0].UBLDocumentSignatures[0]
    .SignatureInformation[0].Signature[0];
}

Deno.test("a signed document verifies against itself", async () => {
  const signed = await signUblJsonDocument(aDocument(), await aRealPair());
  const check = await verifySignedUblJsonDocument(signed.document);
  assertEquals(check, {
    valid: true,
    documentDigestMatches: true,
    propertiesDigestMatches: true,
    signatureMatches: true,
  });
});

Deno.test("the version is raised BEFORE the digest, not after", async () => {
  // The fault this ordering exists for: a document hashed at 1.0 and
  // then relabelled 1.1 carries a digest LHDN recomputes differently,
  // and the rejection names the signature rather than the version.
  const signed = await signUblJsonDocument(aDocument(), await aRealPair());
  assertEquals(
    // deno-lint-ignore no-explicit-any
    (signed.document as any).Invoice[0].InvoiceTypeCode[0].listVersionID,
    SIGNED_VERSION,
  );
  // And the digest agrees with the relabelled document, which is what
  // `verifySignedUblJsonDocument` recomputes.
  assertEquals((await verifySignedUblJsonDocument(signed.document)).documentDigestMatches, true);
});

Deno.test("the digest is taken WITHOUT the signature it is about to carry", async () => {
  // Circular otherwise. Asserted by signing an already-signed document:
  // the second signature's document digest has to equal the first's,
  // because both are over the same document with the signature removed.
  const pair = await aRealPair();
  const once = await signUblJsonDocument(aDocument(), pair);
  const twice = await signUblJsonDocument(once.document, pair, {
    signingTime: once.signingTime,
  });
  assertEquals(twice.documentDigest, once.documentDigest);
  assertEquals(twice.signatureValue, once.signatureValue);
});

Deno.test("the properties digest covers the Target wrapper", async () => {
  // Not the bare SignedProperties. Hashing the wrong one of the two
  // produces a document that is perfect except for eleven characters,
  // and the rejection code does not say which.
  const pair = await aRealPair();
  const signed = await signUblJsonDocument(aDocument(), pair);
  const certificate = readCertificate(pair.certificatePem);
  const wrapped = buildQualifyingProperties(
    signed.certificateDigest,
    certificate.issuerName,
    certificate.serialNumber,
    signed.signingTime,
  );

  const digest = async (value: unknown) =>
    toBase64(
      new Uint8Array(
        await crypto.subtle.digest(
          "SHA-256",
          new TextEncoder().encode(JSON.stringify(value)) as BufferSource,
        ),
      ),
    );

  assertEquals(signed.propertiesDigest, await digest(wrapped));
  // The control: the bare object hashes differently, so the assertion
  // above is about the wrapper and not about the contents.
  assertEquals(
    signed.propertiesDigest === await digest(wrapped.SignedProperties),
    false,
  );
});

Deno.test("a tampered figure breaks the document digest and nothing else", async () => {
  // What the digest is FOR. Changing an amount after signing has to be
  // detectable, and it has to be detectable as a document change rather
  // than as a broken certificate.
  const signed = await signUblJsonDocument(aDocument(), await aRealPair());
  // deno-lint-ignore no-explicit-any
  const doc = JSON.parse(JSON.stringify(signed.document)) as any;
  doc.Invoice[0].LegalMonetaryTotal[0].PayableAmount[0]._ = 12.34;

  const check = await verifySignedUblJsonDocument(doc);
  assertEquals(check.valid, false);
  assertEquals(check.documentDigestMatches, false);
  assertEquals(check.signatureMatches, false);
  assertEquals(check.propertiesDigestMatches, true);
});

Deno.test("a tampered signing time breaks the properties digest alone", async () => {
  // The other half. Back-dating the signature must not go unnoticed,
  // and it leaves the document itself untouched -- so exactly one of
  // the three checks fails.
  const signed = await signUblJsonDocument(aDocument(), await aRealPair());
  // deno-lint-ignore no-explicit-any
  const doc = JSON.parse(JSON.stringify(signed.document)) as any;
  signatureOf(doc).Object[0].QualifyingProperties[0]
    .SignedProperties[0].SignedSignatureProperties[0]
    .SigningTime[0]._ = "2020-01-01T00:00:00Z";

  const check = await verifySignedUblJsonDocument(doc);
  assertEquals(check.valid, false);
  assertEquals(check.propertiesDigestMatches, false);
  assertEquals(check.documentDigestMatches, true);
  assertEquals(check.signatureMatches, true);
});

Deno.test("a key that does not match the certificate is refused here", async () => {
  // Rather than at LHDN, hours later, as a validation code. Both halves
  // are real and they are from different pairs.
  const one = await aRealPair();
  const two = await aRealPair();
  await assertRejects(
    () =>
      signUblJsonDocument(aDocument(), {
        certificatePem: one.certificatePem,
        privateKeyPem: two.privateKeyPem,
      }),
    Error,
    "does not match the certificate",
  );
});

Deno.test("an expired certificate is refused, naming the date", async () => {
  // Signing with one works and produces a document LHDN rejects hours
  // later with a code that names the signature rather than the expiry.
  // The signing time is what it is measured against, so this asserts it
  // by signing in the future rather than by waiting ten years.
  const pair = await aRealPair();
  const expiry = readCertificate(pair.certificatePem).notAfter;
  const after = new Date(expiry.getTime() + 86_400_000).toISOString()
    .replace(/\.\d{3}Z$/, "Z");

  const error = await assertRejects(
    () => signUblJsonDocument(aDocument(), pair, { signingTime: after }),
    Error,
    "expired on",
  );
  assertStringIncludes(error.message, expiry.toISOString().slice(0, 10));

  // The control: a day before it expires, the same pair signs.
  const before = new Date(expiry.getTime() - 86_400_000).toISOString()
    .replace(/\.\d{3}Z$/, "Z");
  const signed = await signUblJsonDocument(aDocument(), pair, {
    signingTime: before,
  });
  assertEquals((await verifySignedUblJsonDocument(signed.document)).valid, true);
});

Deno.test("a certificate that has not started yet is refused too", async () => {
  const pair = await aRealPair();
  const start = readCertificate(pair.certificatePem).notBefore;
  const early = new Date(start.getTime() - 86_400_000).toISOString()
    .replace(/\.\d{3}Z$/, "Z");
  await assertRejects(
    () => signUblJsonDocument(aDocument(), pair, { signingTime: early }),
    Error,
    "not valid until",
  );
});

Deno.test("a PKCS#12 key says how to convert it", async () => {
  // The failure somebody will actually hit: Malaysian certification
  // authorities hand out .p12 and WebCrypto does not read it. "Invalid
  // key data" sends somebody nowhere.
  const pair = await aRealPair();
  const error = await assertRejects(
    () =>
      signUblJsonDocument(aDocument(), {
        certificatePem: pair.certificatePem,
        privateKeyPem: "-----BEGIN PKCS12-----\nAAAA\n-----END PKCS12-----",
      }),
    Error,
  );
  assertStringIncludes(error.message, "openssl pkcs12");
});

Deno.test("the block the document carries is the shape LHDN publishes", async () => {
  const signed = await signUblJsonDocument(aDocument(), await aRealPair());
  // deno-lint-ignore no-explicit-any
  const invoice = (signed.document as any).Invoice[0];

  assertEquals(
    invoice.UBLExtensions[0].UBLExtension[0].ExtensionURI[0]._,
    "urn:oasis:names:specification:ubl:dsig:enveloped:xades",
  );
  assertEquals(
    invoice.Signature[0].ID[0]._,
    "urn:oasis:names:specification:ubl:signature:Invoice",
  );
  assertEquals(
    invoice.Signature[0].SignatureMethod[0]._,
    "urn:oasis:names:specification:ubl:dsig:enveloped:xades",
  );

  const signature = signatureOf(signed.document);
  assertEquals(signature.Id, "signature");
  assertEquals(
    signature.Object[0].QualifyingProperties[0].Target,
    "signature",
  );
  assertEquals(
    signature.Object[0].QualifyingProperties[0].SignedProperties[0].Id,
    "id-xades-signed-props",
  );
  assertEquals(
    signature.SignedInfo[0].SignatureMethod[0].Algorithm,
    "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256",
  );
  // Two references: the signed properties by fragment, the document by
  // the empty URI that means "this document".
  const uris = signature.SignedInfo[0].Reference.map((r: { URI: string }) => r.URI);
  assertEquals(uris.sort(), ["", "#id-xades-signed-props"]);
  for (const reference of signature.SignedInfo[0].Reference) {
    assertEquals(
      reference.DigestMethod[0].Algorithm,
      "http://www.w3.org/2001/04/xmlenc#sha256",
    );
  }
});

Deno.test("the certificate in the document is the certificate that signed", async () => {
  const pair = await aRealPair();
  const signed = await signUblJsonDocument(aDocument(), pair);
  const certificate = readCertificate(pair.certificatePem);
  const signature = signatureOf(signed.document);

  assertEquals(
    signature.KeyInfo[0].X509Data[0].X509Certificate[0]._,
    toBase64(certificate.der),
  );
  assertEquals(
    signature.KeyInfo[0].X509Data[0].X509IssuerSerial[0].X509SerialNumber[0]._,
    certificate.serialNumber,
  );
  // And the issuer is stated twice — in KeyInfo and in the signed
  // properties — so the two are asserted to agree. They are built from
  // one value, and a future edit that reads it twice would not be.
  assertEquals(
    signature.KeyInfo[0].X509Data[0].X509IssuerSerial[0].X509IssuerName[0]._,
    signature.Object[0].QualifyingProperties[0].SignedProperties[0]
      .SignedSignatureProperties[0].SigningCertificate[0].Cert[0]
      .IssuerSerial[0].X509IssuerName[0]._,
  );
});

Deno.test("the minified string is the one that was signed", async () => {
  // The bytes submitted have to be the bytes hashed. Returning the
  // object and letting the caller stringify it again is how a key order
  // changes between signing and submitting.
  const signed = await signUblJsonDocument(aDocument(), await aRealPair());
  assertEquals(signed.minified, JSON.stringify(signed.document));
  assertEquals(signed.minified.includes("\n"), false);
});

Deno.test("prepareForDigest takes both signature elements off", () => {
  const document = aDocument();
  // deno-lint-ignore no-explicit-any
  (document as any).Invoice[0].UBLExtensions = [{ anything: true }];
  // deno-lint-ignore no-explicit-any
  (document as any).Invoice[0].Signature = [{ anything: true }];
  const prepared = prepareForDigest(document);
  // deno-lint-ignore no-explicit-any
  const body = (prepared as any).Invoice[0];
  assertEquals("UBLExtensions" in body, false);
  assertEquals("Signature" in body, false);
  assertEquals(body.ID[0]._, "INV-2026-000041");
});

Deno.test("the signing time is whole seconds in UTC", () => {
  // LHDN's samples carry no milliseconds. A `Z` with three extra digits
  // is a different string in the properties digest.
  const at = new Date("2026-09-16T22:41:12.345Z");
  assertEquals(signingTimestamp(at), "2026-09-16T22:41:12Z");
  // A string is passed through, so a caller that has one already is not
  // made to parse it back into a Date and lose the seconds.
  assertEquals(signingTimestamp("2026-01-01T00:00:00Z"), "2026-01-01T00:00:00Z");
});

Deno.test("an unsigned document says so rather than reading as unsigned-and-fine", async () => {
  await assertRejects(
    () => verifySignedUblJsonDocument(aDocument()),
    Error,
    "carries no signature",
  );
});

Deno.test("something that is not a UBL document is named as such", async () => {
  const pair = await aRealPair();
  await assertRejects(
    () => signUblJsonDocument({ hello: "world" }, pair),
    Error,
    "expected an `Invoice` array",
  );
});
