/**
 * Turning what arrived in an e-mail into something storage will take.
 *
 * Its own module so it can be tested: `receive-email` imports the
 * Supabase client and cannot be, and these two are where a document
 * gets quietly ruined rather than loudly lost.
 */

/**
 * A filename storage will accept as part of a key.
 *
 * The original is kept in `inbound_email_attachments.filename` and is
 * what the reader sees. This is only the key, the same split
 * `Repo._safeName` makes for chat files — a name typed on a phone, or
 * written in Jawi, is not a key.
 *
 * Returns an empty string when nothing usable is left, and the caller
 * skips the file rather than storing it under a path ending in a dash.
 */
export function safeName(name: string): string {
  const cleaned = name
    .replace(/[^A-Za-z0-9._-]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  if (!cleaned) return "";
  return cleaned.length > 80 ? cleaned.slice(0, 80) : cleaned;
}

/**
 * Base64 to bytes.
 *
 * Whitespace first: base64 travels wrapped at 76 characters and `atob`
 * throws on the newlines. A throw here would be a file skipped, which
 * looks from the outside exactly like a message that had no attachment.
 */
export function decodeBase64(b64: string): Uint8Array {
  const binary = atob(b64.replace(/\s+/g, ""));
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

/**
 * Where one attachment goes.
 *
 * The first segment is what the storage policy reads the owning company
 * out of, and `record_inbound_attachment` refuses a path that says
 * anything else — so this is the one part of the key that is not
 * cosmetic. The index keeps two files of the same name on one message
 * apart.
 */
export function attachmentPath(
  orgId: string,
  emailId: string,
  index: number,
  filename: string,
): string | null {
  const name = safeName(filename);
  if (!name) return null;
  return `${orgId}/${emailId}/${index}-${name}`;
}
