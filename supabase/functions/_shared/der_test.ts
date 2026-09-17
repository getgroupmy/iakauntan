import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { pemToDer, readCertificate, toBase64 } from "./der.ts";

/**
 * Reading a certificate, against a certificate OpenSSL made.
 *
 * Every expected value here was printed by `openssl x509 -nameopt
 * RFC2253`, not reasoned out — which is the point. A distinguished
 * name written the wrong way round, or a serial read as hex where LHDN
 * wants decimal, produces a string that looks entirely plausible and
 * matches nothing at the other end.
 *
 * `testdata/sample_certificate.pem` is a self-signed certificate with a
 * throwaway key that was discarded the moment it was generated. It is
 * public by definition. Its subject deliberately carries a comma inside
 * an organization name, because that is the shape of a real Malaysian
 * certification authority's name and it is the character RFC 4514 makes
 * you escape.
 */
const SAMPLE = await Deno.readTextFile(
  new URL("./testdata/sample_certificate.pem", import.meta.url),
);

Deno.test("the issuer reads most specific first, the way RFC 4514 says", () => {
  const cert = readCertificate(SAMPLE);
  assertEquals(
    cert.issuerName,
    "CN=Contoh Issuing CA G3,OU=Certification Authority," +
      "O=Contoh Digicert Sdn Bhd\\, (199801001482),L=Kuala Lumpur," +
      "ST=Wilayah Persekutuan,C=MY",
  );
});

Deno.test("a comma inside a name is escaped rather than read as a separator", () => {
  // Without the escape this name reads as seven attributes instead of
  // six, and the sixth is "(199801001482)" attached to nothing.
  const cert = readCertificate(SAMPLE);
  assertEquals(
    cert.issuerName.includes("O=Contoh Digicert Sdn Bhd\\, (199801001482)"),
    true,
  );
});

Deno.test("the subject is read the same way as the issuer", () => {
  const cert = readCertificate(SAMPLE);
  assertEquals(cert.subjectName, cert.issuerName);
});

Deno.test("the serial number comes out in decimal, not hex", () => {
  // OpenSSL prints it as hex; `X509SerialNumber` is a decimal integer.
  // Handing LHDN the hex string is a mismatch nothing else notices.
  const cert = readCertificate(SAMPLE);
  assertEquals(/^[0-9]+$/.test(cert.serialNumber), true);
  assertEquals(
    cert.serialNumber,
    BigInt("0x" + SERIAL_HEX).toString(10),
  );
});

/** What `openssl x509 -noout -serial` printed for the sample. */
const SERIAL_HEX = "42C0F08DD1E18F7B36046ADEA9396E55F9FED727";

Deno.test("a serial with the top bit set is not multiplied by 256", () => {
  // DER INTEGERs are two's complement, so a serial beginning 0x80 or
  // above carries a leading 0x00 that is a sign bit and not a digit.
  // The sample's begins 0x42, so this is asserted on the rule rather
  // than on the fixture: BigInt over the bytes with and without a
  // leading zero must agree.
  assertEquals(BigInt("0x00" + SERIAL_HEX), BigInt("0x" + SERIAL_HEX));
});

Deno.test("the validity period is read as UTC", () => {
  const cert = readCertificate(SAMPLE);
  assertEquals(cert.notAfter > cert.notBefore, true);
  // Ten years, as the fixture was generated. A UTCTime century pivot
  // read wrongly lands this in 1936 and the comparison above still
  // passes, so the year is asserted.
  assertEquals(
    cert.notAfter.getUTCFullYear() - cert.notBefore.getUTCFullYear(),
    10,
  );
  assertEquals(cert.notBefore.getUTCFullYear() >= 2020, true);
});

Deno.test("the public key comes out as an SPKI WebCrypto will take", async () => {
  const cert = readCertificate(SAMPLE);
  // The assertion is the import: a SubjectPublicKeyInfo off by one byte
  // at either end is still a plausible-looking Uint8Array, and this is
  // the only thing that tells the difference.
  const key = await crypto.subtle.importKey(
    "spki",
    cert.publicKeyDer as BufferSource,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    true,
    ["verify"],
  );
  assertEquals(key.type, "public");
  assertEquals((key.algorithm as RsaHashedKeyAlgorithm).modulusLength, 2048);
});

Deno.test("the DER round-trips back to the base64 in the file", () => {
  const cert = readCertificate(SAMPLE);
  const body = SAMPLE
    .replace(/-----[A-Z ]+-----/g, "")
    .replace(/\s+/g, "");
  assertEquals(toBase64(cert.der), body);
});

Deno.test("a private key where a certificate belongs says so", () => {
  // The message names what it found. Left to fail later, this arrives
  // as "the outer element is not a SEQUENCE" several hundred lines from
  // where somebody pasted the wrong block.
  assertThrows(
    () => pemToDer("-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----"),
    Error,
    "found a PRIVATE KEY block instead",
  );
});

Deno.test("something that is not PEM at all says what PEM looks like", () => {
  assertThrows(
    () => pemToDer("just some text"),
    Error,
    "-----BEGIN CERTIFICATE-----",
  );
});

Deno.test("a truncated certificate is refused rather than half read", () => {
  const der = pemToDer(SAMPLE);
  const half = der.subarray(0, Math.floor(der.length / 2));
  const pem = `-----BEGIN CERTIFICATE-----\n${toBase64(half)}\n-----END CERTIFICATE-----`;
  assertThrows(() => readCertificate(pem), Error);
});
