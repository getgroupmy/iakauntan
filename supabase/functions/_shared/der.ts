/**
 * Just enough ASN.1 to read an X.509 certificate.
 *
 * Deno has WebCrypto and no certificate parser, and the four things a
 * XAdES signature needs off a certificate -- the serial number, the
 * issuer's distinguished name, when it stops being valid, and the
 * public key -- are all in the first hundred bytes of a structure that
 * has not changed since 1988. A dependency for that is a dependency for
 * a hundred lines.
 *
 * It reads. It does not verify: nothing here checks a chain, a
 * revocation list or a signature over the certificate itself. That is
 * LHDN's job and it is done at submission, against a list of Malaysian
 * certification authorities this code has no copy of.
 */

/** A DER element: its tag, where its contents are, and where it ends. */
interface Element {
  tag: number;
  start: number;
  end: number;
  contentStart: number;
  contentEnd: number;
}

const SEQUENCE = 0x30;
const SET = 0x31;
const INTEGER = 0x02;
const OID = 0x06;
const UTC_TIME = 0x17;
const GENERALIZED_TIME = 0x18;

function fail(what: string): never {
  throw new Error(`Not a certificate this can read: ${what}`);
}

/**
 * Reads one element at [offset].
 *
 * Long-form lengths only up to four bytes, which is 4GB and about four
 * million times the size of any certificate. Indefinite length (0x80)
 * is BER rather than DER and a certificate carrying it is not a
 * certificate.
 */
function read(bytes: Uint8Array, offset: number): Element {
  if (offset + 2 > bytes.length) fail("it ends in the middle of an element");
  const tag = bytes[offset];
  let length = bytes[offset + 1];
  let contentStart = offset + 2;

  if (length === 0x80) fail("it uses indefinite lengths, which is BER not DER");
  if (length > 0x80) {
    const count = length - 0x80;
    if (count > 4) fail("an element claims to be larger than 4GB");
    length = 0;
    for (let i = 0; i < count; i++) {
      length = length * 256 + bytes[contentStart + i];
    }
    contentStart += count;
  }

  const contentEnd = contentStart + length;
  if (contentEnd > bytes.length) fail("an element runs past the end of the file");
  return { tag, start: offset, end: contentEnd, contentStart, contentEnd };
}

/** Every element directly inside [parent]. */
function children(bytes: Uint8Array, parent: Element): Element[] {
  const out: Element[] = [];
  let at = parent.contentStart;
  while (at < parent.contentEnd) {
    const child = read(bytes, at);
    out.push(child);
    at = child.end;
  }
  return out;
}

function contents(bytes: Uint8Array, el: Element): Uint8Array {
  return bytes.subarray(el.contentStart, el.contentEnd);
}

/** The element and its tag and length, which is what `spki` has to be. */
function whole(bytes: Uint8Array, el: Element): Uint8Array {
  return bytes.slice(el.start, el.end);
}

/**
 * An OID as dotted decimal.
 *
 * The first byte carries two arcs; every arc after it is base-128 with
 * the top bit set on all but the last byte.
 */
function oid(bytes: Uint8Array, el: Element): string {
  const data = contents(bytes, el);
  if (data.length === 0) return "";
  const parts = [Math.floor(data[0] / 40), data[0] % 40];
  let value = 0;
  for (let i = 1; i < data.length; i++) {
    value = value * 128 + (data[i] & 0x7f);
    if ((data[i] & 0x80) === 0) {
      parts.push(value);
      value = 0;
    }
  }
  return parts.join(".");
}

/**
 * The short names RFC 4514 defines, and nothing else.
 *
 * An attribute type outside this list is written as its OID, which is
 * what the RFC says to do -- inventing a short name for it would
 * produce a string no other implementation agrees with, and the whole
 * point of this string is that LHDN compares it with one of their own.
 */
const SHORT_NAMES: Record<string, string> = {
  "2.5.4.3": "CN",
  "2.5.4.6": "C",
  "2.5.4.7": "L",
  "2.5.4.8": "ST",
  "2.5.4.9": "STREET",
  "2.5.4.10": "O",
  "2.5.4.11": "OU",
  "0.9.2342.19200300.100.1.25": "DC",
  "0.9.2342.19200300.100.1.1": "UID",
};

/**
 * The characters RFC 4514 says to escape, escaped.
 *
 * A comma inside an organization's name -- "Pos Digicert Sdn Bhd,
 * (199801001482)" is the shape of a real one -- would otherwise read as
 * the separator between two attributes.
 */
function escapeValue(value: string): string {
  let out = value.replace(/([\\",+;<>=])/g, "\\$1");
  if (out.startsWith("#") || out.startsWith(" ")) out = "\\" + out;
  if (out.endsWith(" ")) out = out.slice(0, -1) + "\\ ";
  return out;
}

const decoder = new TextDecoder();

/**
 * A distinguished name, most specific attribute first.
 *
 * DER stores an RDNSequence least-specific first -- country, then
 * organization, then common name -- and RFC 4514 prints it the other
 * way round. Getting this backwards produces a string that looks
 * entirely reasonable and matches nothing.
 */
function distinguishedName(bytes: Uint8Array, name: Element): string {
  const rdns: string[] = [];
  for (const rdn of children(bytes, name)) {
    if (rdn.tag !== SET) continue;
    const pairs: string[] = [];
    for (const attribute of children(bytes, rdn)) {
      const parts = children(bytes, attribute);
      if (parts.length < 2 || parts[0].tag !== OID) continue;
      const type = oid(bytes, parts[0]);
      const label = SHORT_NAMES[type] ?? type;
      const value = decoder.decode(contents(bytes, parts[1]));
      pairs.push(`${label}=${escapeValue(value)}`);
    }
    // Multi-valued RDNs join with `+`, which is rare and is in the RFC.
    if (pairs.length > 0) rdns.push(pairs.join("+"));
  }
  return rdns.reverse().join(",");
}

/**
 * A certificate's notBefore/notAfter.
 *
 * UTCTime is two-digit years, and RFC 5280 fixes the pivot at 50: 49
 * means 2049 and 50 means 1950. A certificate issued today expires
 * inside that window; one that does not uses GeneralizedTime, which
 * spells the century out.
 */
function time(bytes: Uint8Array, el: Element): Date {
  const text = decoder.decode(contents(bytes, el));
  let year: number;
  let rest: string;
  if (el.tag === UTC_TIME) {
    const yy = Number(text.slice(0, 2));
    year = yy < 50 ? 2000 + yy : 1900 + yy;
    rest = text.slice(2);
  } else if (el.tag === GENERALIZED_TIME) {
    year = Number(text.slice(0, 4));
    rest = text.slice(4);
  } else {
    fail("a validity field is neither UTCTime nor GeneralizedTime");
  }
  const month = Number(rest.slice(0, 2));
  const day = Number(rest.slice(2, 4));
  const hour = Number(rest.slice(4, 6));
  const minute = Number(rest.slice(6, 8));
  const second = Number(rest.slice(8, 10)) || 0;
  return new Date(Date.UTC(year, month - 1, day, hour, minute, second));
}

export interface CertificateFields {
  /** The whole certificate, DER. What `X509Certificate` carries, base64ed. */
  der: Uint8Array;
  /** Decimal, as `X509SerialNumber` wants it. Certificates print it in hex. */
  serialNumber: string;
  /** RFC 4514, most specific first. `X509IssuerName`. */
  issuerName: string;
  subjectName: string;
  notBefore: Date;
  notAfter: Date;
  /** SubjectPublicKeyInfo, DER — what `importKey("spki", …)` takes. */
  publicKeyDer: Uint8Array;
}

/**
 * The DER inside a PEM block.
 *
 * Tolerant of CRLF, of a missing trailing newline and of leading
 * whitespace, because a certificate arrives by being pasted into a text
 * box. Not tolerant of the wrong block: a private key where a
 * certificate was expected parses as an unreadable certificate several
 * hundred lines later, and the message it produces there names the
 * wrong thing.
 */
export function pemToDer(pem: string, label = "CERTIFICATE"): Uint8Array {
  const pattern = new RegExp(
    `-----BEGIN ${label}-----([\\s\\S]*?)-----END ${label}-----`,
  );
  const match = pattern.exec(pem);
  if (!match) {
    const other = /-----BEGIN ([A-Z0-9 ]+)-----/.exec(pem);
    throw new Error(
      other
        ? `Expected a ${label} block and found a ${other[1]} block instead`
        : `No ${label} block found. A PEM file begins "-----BEGIN ${label}-----".`,
    );
  }
  const body = match[1].replace(/\s+/g, "");
  const binary = atob(body);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

/** Reads the fields a signature needs off a PEM certificate. */
export function readCertificate(pem: string): CertificateFields {
  const der = pemToDer(pem);
  const certificate = read(der, 0);
  if (certificate.tag !== SEQUENCE) fail("the outer element is not a SEQUENCE");

  const top = children(der, certificate);
  if (top.length < 1) fail("it is empty");
  const tbs = top[0];
  const fields = children(der, tbs);

  // The version is an optional [0]-tagged element. Everything after it
  // shifts by one when it is there, which it is on every certificate
  // issued this century.
  let at = 0;
  if (fields[at] && fields[at].tag === 0xa0) at++;

  const serial = fields[at++];
  if (!serial || serial.tag !== INTEGER) fail("the serial number is missing");
  at++; // the signature algorithm, which is on the certificate, not ours

  const issuer = fields[at++];
  const validity = fields[at++];
  const subject = fields[at++];
  const spki = fields[at++];
  if (!issuer || !validity || !subject || !spki) {
    fail("it stops before the public key");
  }

  const validityParts = children(der, validity);
  if (validityParts.length < 2) fail("the validity period is incomplete");

  // A leading zero byte is the sign bit, not part of the number: DER
  // INTEGERs are two's complement, so a serial whose top bit is set
  // carries a 0x00 in front of it. Reading it as a digit would multiply
  // the number by 256.
  let hex = "";
  for (const byte of contents(der, serial)) {
    hex += byte.toString(16).padStart(2, "0");
  }
  const serialNumber = BigInt("0x" + (hex || "0")).toString(10);

  return {
    der,
    serialNumber,
    issuerName: distinguishedName(der, issuer),
    subjectName: distinguishedName(der, subject),
    notBefore: time(der, validityParts[0]),
    notAfter: time(der, validityParts[1]),
    publicKeyDer: whole(der, spki),
  };
}

/** Base64 of arbitrary bytes, without the line breaks PEM uses. */
export function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}
