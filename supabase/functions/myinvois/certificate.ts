/**
 * Puts a XAdES signing certificate on file, and says what it is.
 *
 * Payload: { certificate_pem, private_key_pem, environment? }
 * With `check_only: true`, it reads the pair and reports on it without
 * storing anything -- which is what the screen does while somebody is
 * still pasting.
 *
 * ## Why this is an edge function and not an RPC
 *
 * Because something has to READ the certificate. The serial number,
 * the issuer's distinguished name and the expiry are in the DER, and
 * `der.ts` is the one place in this product that parses one. A second
 * parser in PL/pgSQL would be a second answer to "what is this
 * certificate's issuer" that can disagree with the first -- and the
 * first is the one that goes in the signature.
 *
 * It is also the only place that can answer the question worth asking
 * at upload time: does this key match this certificate. A mismatched
 * pair produces a structurally perfect document that LHDN rejects at
 * validation, hours later, with a code that names neither half. Caught
 * here it is a sentence on the screen of the person holding both files.
 *
 * Nothing is returned that was not already public. The certificate is
 * public by definition; the private key is read, used once to prove the
 * pair, and never echoed.
 */
import { Ctx, HttpError } from "../_shared/context.ts";
import { readCertificate } from "../_shared/der.ts";
import { signUblJsonDocument } from "../_shared/xades.ts";
import { MyInvoisEnv } from "../_shared/myinvois.ts";

const ADMIN_ROLES = ["owner", "admin"];

/**
 * A document with nothing in it, used to prove the pair.
 *
 * Signing something is the only way to find out whether a key matches
 * a certificate, and it costs a millisecond. This is never submitted
 * and never stored.
 */
function aTestDocument(): Record<string, unknown> {
  return {
    _D: "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2",
    Invoice: [{
      ID: [{ _: "CERTIFICATE-CHECK" }],
      InvoiceTypeCode: [{ _: "01", listVersionID: "1.0" }],
    }],
  };
}

export async function saveCertificate(ctx: Ctx) {
  if (!ADMIN_ROLES.includes(ctx.role)) {
    throw new HttpError(
      403,
      `Your role (${ctx.role}) cannot change the e-Invoice signing ` +
        `certificate`,
    );
  }

  const certificatePem = String(ctx.body.certificate_pem ?? "").trim();
  const privateKeyPem = String(ctx.body.private_key_pem ?? "").trim();
  const checkOnly = ctx.body.check_only === true;

  if (!certificatePem || !privateKeyPem) {
    throw new HttpError(
      400,
      "Both the certificate and its private key are needed. A certification " +
        "authority usually sends one .p12 file holding both; convert it with " +
        "`openssl pkcs12 -in signing.p12 -nodes -legacy -out signing.pem` and " +
        "paste the two blocks from that file.",
    );
  }

  // Read it first, so a mistyped PEM is named as a PEM problem rather
  // than reaching the database and failing as something else.
  let certificate;
  try {
    certificate = readCertificate(certificatePem);
  } catch (err) {
    throw new HttpError(
      400,
      `Could not read the certificate: ${(err as Error).message}`,
    );
  }

  // And prove the pair, which is what this call is really for.
  try {
    await signUblJsonDocument(aTestDocument(), {
      certificatePem,
      privateKeyPem,
    });
  } catch (err) {
    throw new HttpError(400, (err as Error).message);
  }

  const described = {
    issuer: certificate.issuerName,
    subject: certificate.subjectName,
    serial_number: certificate.serialNumber,
    valid_from: certificate.notBefore.toISOString(),
    expires_at: certificate.notAfter.toISOString(),
    // Named separately from the expiry so a screen can say "renew this"
    // without doing date arithmetic of its own.
    days_until_expiry: Math.floor(
      (certificate.notAfter.getTime() - Date.now()) / 86_400_000,
    ),
  };

  if (checkOnly) return { checked: true, certificate: described };

  const { data: org } = await ctx.admin
    .from("organizations")
    .select("einvoice_environment")
    .eq("id", ctx.orgId)
    .maybeSingle();

  const environment = String(
    ctx.body.environment ?? org?.einvoice_environment ?? "sandbox",
  ) as MyInvoisEnv;

  // Through the caller's own client, so `app.can_admin` is checked
  // against the person rather than against the service role. The edge
  // function holds the service key and must not spend it on an
  // authorization it has already been asked to make.
  const { error } = await ctx.userClient.rpc(
    "set_einvoice_signing_certificate",
    {
      p_org_id: ctx.orgId,
      p_environment: environment,
      p_cert_pem: certificatePem,
      p_cert_private_key_pem: privateKeyPem,
      p_cert_serial_number: certificate.serialNumber,
      p_cert_issuer_name: certificate.issuerName,
      p_cert_expires_at: certificate.notAfter.toISOString(),
    },
  );
  if (error) throw new HttpError(400, error.message);

  return { saved: true, environment, certificate: described };
}
