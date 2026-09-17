/**
 * The XAdES signature a MyInvois e-Invoice version 1.1 has to carry.
 *
 * A 1.0 document is submitted as it stands. A 1.1 document must be
 * signed by the taxpayer with a certificate from a Malaysian
 * certification authority, and LHDN recomputes both digests and the
 * signature before it will validate the document. Getting any byte of
 * this wrong produces a document that is accepted by the transport and
 * rejected by validation, hours later, with a code.
 *
 * ## The procedure, which is LHDN's and not ours
 *
 *   1. Take the document WITHOUT `UBLExtensions` and `Signature`, and
 *      minify it.
 *   2. DocDigest   = base64(SHA-256(that string))
 *   3. Sig         = base64(RSA-PKCS#1 v1.5 SHA-256 over that string)
 *   4. CertDigest  = base64(SHA-256(the certificate's DER))
 *   5. Build the signed properties: when it was signed, and which
 *      certificate signed it.
 *   6. PropsDigest = base64(SHA-256(minified `{"Target":…,"SignedProperties":[…]}`))
 *   7. Put the whole thing back under `UBLExtensions`, and add the
 *      `Signature` pointer beside it.
 *
 * ## Two things that silently produce a rejected document
 *
 * **The digest is over the FINAL document.** Anything that changes the
 * document -- including raising `InvoiceTypeCode/@listVersionID` from
 * 1.0 to 1.1, which a signed document must declare -- has to happen
 * before step 2. So this raises it itself rather than trusting the
 * caller to have done it in the right order.
 *
 * **PropsDigest covers the `Target` wrapper**, not the bare signed
 * properties. The object hashed in step 6 is the same object embedded
 * in step 7 -- one variable, used twice -- because two constructions of
 * "the same" object are how a mismatch gets in.
 *
 * ## What is NOT verified here, and cannot be from this machine
 *
 * The structure below is written to LHDN's published JSON binding and
 * agrees with two independent implementations of it. It has never been
 * submitted to MyInvois from this repository -- there is no sandbox
 * credential here and `sdk.myinvois.hasil.gov.my` is unreachable from
 * the network this is built on. What `xades_test.ts` proves is
 * self-consistency: the digests recompute from the emitted document and
 * the signature verifies against the certificate in it, which is the
 * check LHDN performs. What it cannot prove is that LHDN agrees about
 * the shape. `docs/einvoice-signing.md` says what to do about that.
 */
import { readCertificate, pemToDer, toBase64 } from "./der.ts";

const EXTENSION_URI = "urn:oasis:names:specification:ubl:dsig:enveloped:xades";
const SIGNATURE_INFORMATION_ID =
  "urn:oasis:names:specification:ubl:signature:1";
const REFERENCED_SIGNATURE_ID =
  "urn:oasis:names:specification:ubl:signature:Invoice";
const SIGNATURE_ID = "signature";
const SIGNED_PROPERTIES_ID = "id-xades-signed-props";
const DIGEST_ALGORITHM = "http://www.w3.org/2001/04/xmlenc#sha256";
const SIGNATURE_ALGORITHM =
  "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256";
const SIGNED_PROPERTIES_TYPE =
  "http://uri.etsi.org/01903/v1.3.2#SignedProperties";

/** The version a signed document declares. A 1.0 document has no signature. */
export const SIGNED_VERSION = "1.1";

type Node = Record<string, unknown>;

const leaf = (value: unknown, attrs: Node = {}): Node[] => [
  { _: value, ...attrs },
];

/** A `DigestMethod`: an empty value carrying the algorithm as an attribute. */
const digestMethod = (): Node[] => [{ _: "", Algorithm: DIGEST_ALGORITHM }];

const encoder = new TextEncoder();

async function sha256Base64(data: string | Uint8Array): Promise<string> {
  const bytes = typeof data === "string" ? encoder.encode(data) : data;
  const digest = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return toBase64(new Uint8Array(digest));
}

/**
 * Malaysian certification authorities hand out PKCS#12, and WebCrypto
 * does not read it. Said here rather than left as "invalid key data",
 * because this is the failure somebody will actually hit.
 */
const PKCS12_HINT =
  "WebCrypto reads PKCS#8 PEM, not PKCS#12. If this is a .p12 or .pfx " +
  "from your certification authority, convert it once with:\n" +
  "  openssl pkcs12 -in signing.p12 -nodes -legacy -out signing.pem\n" +
  "and paste the PRIVATE KEY block from that file.";

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  let der: Uint8Array;
  try {
    der = pemToDer(pem, "PRIVATE KEY");
  } catch (cause) {
    throw new Error(
      `Could not read the signing key. ${PKCS12_HINT}`,
      { cause },
    );
  }
  try {
    return await crypto.subtle.importKey(
      "pkcs8",
      der as BufferSource,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"],
    );
  } catch (cause) {
    throw new Error(`Could not read the signing key. ${PKCS12_HINT}`, { cause });
  }
}

async function importPublicKey(spki: Uint8Array): Promise<CryptoKey> {
  return await crypto.subtle.importKey(
    "spki",
    spki as BufferSource,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
}

function base64ToBytes(value: string): Uint8Array {
  const binary = atob(value);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

/** `2026-09-16T22:41:12Z` — UTC, whole seconds, as in LHDN's samples. */
export function signingTimestamp(at?: Date | string): string {
  if (typeof at === "string") return at;
  return (at ?? new Date()).toISOString().replace(/\.\d{3}Z$/, "Z");
}

function invoiceBody(document: Node): Node {
  const invoice = document.Invoice;
  if (!Array.isArray(invoice) || invoice.length === 0 ||
      typeof invoice[0] !== "object" || invoice[0] === null) {
    throw new Error(
      "Not a MyInvois UBL JSON document: expected an `Invoice` array at " +
        "the root.",
    );
  }
  return invoice[0] as Node;
}

/**
 * The document as it must look before hashing: the version raised, and
 * any signature it already carried taken off.
 *
 * Object spread keeps insertion order, so the surviving keys stay in the
 * sequence `buildUblDocument` emitted. The digest is over a byte-exact
 * string and reordering two keys changes it.
 */
export function prepareForDigest(document: Node): Node {
  const { UBLExtensions: _ext, Signature: _sig, ...body } = invoiceBody(
    document,
  );
  const typeCode = body.InvoiceTypeCode;
  if (Array.isArray(typeCode)) {
    body.InvoiceTypeCode = typeCode.map((entry) =>
      entry && typeof entry === "object"
        ? { ...entry as Node, listVersionID: SIGNED_VERSION }
        : entry
    );
  }
  return { ...document, Invoice: [body] };
}

/**
 * The signed properties, wrapped in the `Target` that PropsDigest
 * covers.
 *
 * One object, returned once, because step 6 hashes exactly what step 7
 * embeds.
 */
export function buildQualifyingProperties(
  certificateDigest: string,
  issuerName: string,
  serialNumber: string,
  signingTime: string,
): Node {
  return {
    Target: SIGNATURE_ID,
    SignedProperties: [{
      Id: SIGNED_PROPERTIES_ID,
      SignedSignatureProperties: [{
        SigningTime: leaf(signingTime),
        SigningCertificate: [{
          Cert: [{
            CertDigest: [{
              DigestMethod: digestMethod(),
              DigestValue: leaf(certificateDigest),
            }],
            IssuerSerial: [{
              X509IssuerName: leaf(issuerName),
              X509SerialNumber: leaf(serialNumber),
            }],
          }],
        }],
      }],
    }],
  };
}

export interface SigningMaterial {
  /** The taxpayer's certificate, PEM. Public; it goes in the document. */
  certificatePem: string;
  /** Its private key, PKCS#8 PEM. Never leaves the edge function. */
  privateKeyPem: string;
}

export interface SignedUblDocument {
  document: Node;
  /** The bytes that were signed, which are the bytes to submit. */
  minified: string;
  documentDigest: string;
  propertiesDigest: string;
  certificateDigest: string;
  signatureValue: string;
  signingTime: string;
  /** When the certificate stops being usable, for the warning on screen. */
  certificateExpiresAt: Date;
}

/**
 * Signs a UBL JSON document, turning a 1.0 document into a signed 1.1
 * one.
 *
 * Refuses a key that does not match the certificate. That pair produces
 * a structurally perfect document which LHDN rejects at validation, and
 * finding out here costs nothing.
 */
export async function signUblJsonDocument(
  document: Node,
  material: SigningMaterial,
  options: { signingTime?: Date | string } = {},
): Promise<SignedUblDocument> {
  const certificate = readCertificate(material.certificatePem);
  const privateKey = await importPrivateKey(material.privateKeyPem);
  const signingTime = signingTimestamp(options.signingTime);

  // An expired certificate signs perfectly well and produces a document
  // LHDN rejects. Refusing here names the date and the renewal, which
  // is what somebody can act on; the rejection names neither.
  //
  // Measured against the signing time rather than against now, so a
  // document being re-signed at a stated time is judged by that time.
  const at = new Date(signingTime);
  if (certificate.notAfter < at) {
    throw new Error(
      `The signing certificate expired on ` +
        `${certificate.notAfter.toISOString().slice(0, 10)}. MyInvois will ` +
        `reject anything signed with it — renew it with your certification ` +
        `authority and load the new one under Settings > e-Invoice.`,
    );
  }
  if (certificate.notBefore > at) {
    throw new Error(
      `The signing certificate is not valid until ` +
        `${certificate.notBefore.toISOString().slice(0, 10)}.`,
    );
  }

  // Steps 1-3.
  const prepared = prepareForDigest(document);
  const minifiedForDigest = JSON.stringify(prepared);
  const documentDigest = await sha256Base64(minifiedForDigest);
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    privateKey,
    encoder.encode(minifiedForDigest) as BufferSource,
  );
  const signatureValue = toBase64(new Uint8Array(signature));

  const matches = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    await importPublicKey(certificate.publicKeyDer),
    base64ToBytes(signatureValue) as BufferSource,
    encoder.encode(minifiedForDigest) as BufferSource,
  );
  if (!matches) {
    throw new Error(
      "The signing key does not match the certificate: the signature it " +
        "produced does not verify against the certificate's public key. " +
        "Both have to come from the same pair.",
    );
  }

  // Steps 4-6.
  const certificateDigest = await sha256Base64(certificate.der);
  const qualifyingProperties = buildQualifyingProperties(
    certificateDigest,
    certificate.issuerName,
    certificate.serialNumber,
    signingTime,
  );
  const propertiesDigest = await sha256Base64(
    JSON.stringify(qualifyingProperties),
  );

  // Step 7.
  const ublExtensions = [{
    UBLExtension: [{
      ExtensionURI: leaf(EXTENSION_URI),
      ExtensionContent: [{
        UBLDocumentSignatures: [{
          SignatureInformation: [{
            ID: leaf(SIGNATURE_INFORMATION_ID),
            ReferencedSignatureID: leaf(REFERENCED_SIGNATURE_ID),
            Signature: [{
              Id: SIGNATURE_ID,
              Object: [{ QualifyingProperties: [qualifyingProperties] }],
              KeyInfo: [{
                X509Data: [{
                  X509Certificate: leaf(toBase64(certificate.der)),
                  X509SubjectName: leaf(certificate.subjectName),
                  X509IssuerSerial: [{
                    X509IssuerName: leaf(certificate.issuerName),
                    X509SerialNumber: leaf(certificate.serialNumber),
                  }],
                }],
              }],
              SignatureValue: leaf(signatureValue),
              SignedInfo: [{
                SignatureMethod: [{ _: "", Algorithm: SIGNATURE_ALGORITHM }],
                Reference: [
                  {
                    Type: SIGNED_PROPERTIES_TYPE,
                    URI: `#${SIGNED_PROPERTIES_ID}`,
                    DigestMethod: digestMethod(),
                    DigestValue: leaf(propertiesDigest),
                  },
                  {
                    Type: "",
                    URI: "",
                    DigestMethod: digestMethod(),
                    DigestValue: leaf(documentDigest),
                  },
                ],
              }],
            }],
          }],
        }],
      }],
    }],
  }];

  const signed: Node = {
    ...prepared,
    Invoice: [{
      ...invoiceBody(prepared),
      UBLExtensions: ublExtensions,
      Signature: [{
        ID: leaf(REFERENCED_SIGNATURE_ID),
        SignatureMethod: leaf(EXTENSION_URI),
      }],
    }],
  };

  return {
    document: signed,
    minified: JSON.stringify(signed),
    documentDigest,
    propertiesDigest,
    certificateDigest,
    signatureValue,
    signingTime,
    certificateExpiresAt: certificate.notAfter,
  };
}

/** The first element of a UBL JSON array, as an object. */
function first(value: unknown): Node | undefined {
  const entry = Array.isArray(value) ? value[0] : value;
  return entry !== null && typeof entry === "object" ? entry as Node : undefined;
}

/** The `_` leaf of a UBL JSON element. */
function text(value: unknown): string {
  const found = first(value)?._;
  return typeof found === "string" ? found : "";
}

/** Walks a chain of element names, unwrapping each array on the way. */
function dig(value: unknown, ...keys: string[]): unknown {
  let current = value;
  for (const key of keys) {
    const entry = first(current);
    if (!entry) return undefined;
    current = entry[key];
  }
  return current;
}

export interface SignatureCheck {
  valid: boolean;
  documentDigestMatches: boolean;
  propertiesDigestMatches: boolean;
  signatureMatches: boolean;
}

/**
 * Recomputes both digests from a signed document and checks the
 * signature against the certificate the document carries.
 *
 * This is the check LHDN performs. Running it here turns a rejection
 * that arrives hours later into an assertion that fails now.
 */
export async function verifySignedUblJsonDocument(
  document: Node,
): Promise<SignatureCheck> {
  const body = invoiceBody(document);
  const signature = first(dig(
    body.UBLExtensions,
    "UBLExtension",
    "ExtensionContent",
    "UBLDocumentSignatures",
    "SignatureInformation",
    "Signature",
  ));
  if (!signature) {
    throw new Error("The document carries no signature under UBLExtensions.");
  }

  const references = first(signature.SignedInfo)?.Reference;
  const list = Array.isArray(references) ? references as Node[] : [];
  // By URI rather than by position. The two references are told apart
  // by what they point at, and a reader that trusts their order would
  // report a clean document as broken if LHDN ever swapped them.
  const propertiesReference = list.find((r) => r.URI === `#${SIGNED_PROPERTIES_ID}`);
  const documentReference = list.find((r) => r.URI === "");

  const minified = JSON.stringify(prepareForDigest(document));
  const documentDigestMatches =
    text(documentReference?.DigestValue) === await sha256Base64(minified);

  const qualifyingProperties = first(dig(signature.Object, "QualifyingProperties")) ?? {};
  const propertiesDigestMatches =
    text(propertiesReference?.DigestValue) ===
      await sha256Base64(JSON.stringify(qualifyingProperties));

  const certificateBase64 = text(
    dig(signature.KeyInfo, "X509Data", "X509Certificate"),
  );
  const certificate = readCertificate(
    `-----BEGIN CERTIFICATE-----\n${certificateBase64}\n-----END CERTIFICATE-----`,
  );
  const signatureMatches = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    await importPublicKey(certificate.publicKeyDer),
    base64ToBytes(text(signature.SignatureValue)) as BufferSource,
    encoder.encode(minified) as BufferSource,
  );

  return {
    valid: documentDigestMatches && propertiesDigestMatches && signatureMatches,
    documentDigestMatches,
    propertiesDigestMatches,
    signatureMatches,
  };
}
