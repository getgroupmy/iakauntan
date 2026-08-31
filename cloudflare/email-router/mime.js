/**
 * Reading a MIME message well enough to file what was in it.
 *
 * Its own module so it can be tested. The worker cannot be — it needs a
 * Cloudflare `message` object and an outbound fetch — and this is the
 * half where being quietly wrong costs somebody a document:
 * `attachmentsIn` returning nothing looks exactly like a message that
 * had no attachment, which is the failure `0354` exists to end.
 *
 * Deliberately shallow throughout. A part this misreads is skipped
 * rather than mangled, because a PDF delivered corrupt looks like a
 * scanning fault and gets chased in the wrong place.
 */

/** Past which a message is not carrying documents any more. */
export const MAX_ATTACHMENTS = 10;
export const MAX_ATTACHMENT_BYTES = 15 * 1024 * 1024;

/** The text, the HTML, and what was attached. */
export function parse(raw) {
  return { ...split(raw), attachments: attachmentsIn(raw) };
}

/**
 * The text and HTML parts, well enough for a screen to show them.
 *
 * A message this misreads is still stored whole.
 */
export function split(raw) {
  const boundary = boundaryOf(raw);
  if (!boundary) {
    const body = raw.split(/\r?\n\r?\n/).slice(1).join("\n\n");
    return /content-type:\s*text\/html/i.test(raw)
      ? { text: null, html: body }
      : { text: body, html: null };
  }

  let text = null;
  let html = null;
  for (const part of raw.split(`--${boundary}`)) {
    const [head, ...rest] = part.split(/\r?\n\r?\n/);
    if (!rest.length) continue;
    // A part that names a file is a document, not the note. Without
    // this a text/plain attachment — a CSV bank statement, say —
    // becomes the body of the message and the real note disappears.
    if (filenameIn(head)) continue;
    const content = rest.join("\n\n").trim();
    if (/content-type:\s*text\/plain/i.test(head)) text ??= content;
    if (/content-type:\s*text\/html/i.test(head)) html ??= content;
  }
  return { text, html };
}

/**
 * Every named part of a multipart message, as base64.
 *
 * A part counts as an attachment when it names a file — in
 * `Content-Disposition: attachment; filename="..."`, or in the `name=`
 * a few clients still put on the Content-Type. An inline image with a
 * filename counts: a photographed receipt pasted into the body is
 * exactly the thing somebody wants back.
 *
 * Only base64 parts are carried. Every mail client sends a binary
 * attachment that way — it is what MIME is for — and a part in another
 * encoding is skipped rather than guessed at.
 */
export function attachmentsIn(raw) {
  const boundary = boundaryOf(raw);
  if (!boundary) return [];

  const out = [];
  let carried = 0;
  for (const part of raw.split(`--${boundary}`)) {
    if (out.length >= MAX_ATTACHMENTS) break;
    const [head, ...rest] = part.split(/\r?\n\r?\n/);
    if (!rest.length) continue;

    const filename = filenameIn(head);
    if (!filename) continue;
    if (!/content-transfer-encoding:\s*base64/i.test(head)) continue;

    // Whitespace is how base64 is wrapped for transport, not data.
    const content = rest.join("\n\n").replace(/\s+/g, "");
    if (!content) continue;

    // Four base64 characters carry three bytes. Near enough to hold a
    // line: the cap is about not melting the worker, not about an exact
    // byte count.
    const bytes = Math.floor((content.length * 3) / 4);
    if (carried + bytes > MAX_ATTACHMENT_BYTES) continue;
    carried += bytes;

    out.push({
      filename,
      content_type: contentTypeIn(head),
      content_base64: content,
    });
  }
  return out;
}

function boundaryOf(raw) {
  return raw.match(/boundary="?([^";\r\n]+)"?/i)?.[1] ?? null;
}

function filenameIn(head) {
  const named = head.match(/filename\s*=\s*"?([^";\r\n]+)"?/i)?.[1] ??
    head.match(/\bname\s*=\s*"?([^";\r\n]+)"?/i)?.[1];
  const trimmed = named?.trim();
  // `name="text.txt"` on a boundary declaration is not a filename, and
  // neither is an empty one.
  return trimmed ? trimmed : null;
}

function contentTypeIn(head) {
  return head.match(/content-type:\s*([^;\r\n]+)/i)?.[1]?.trim() ?? null;
}
