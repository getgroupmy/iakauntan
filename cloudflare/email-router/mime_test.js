import { assertEquals } from "jsr:@std/assert@1.0.19";
import { attachmentsIn, parse, split } from "./mime.js";

/**
 * Reading a message well enough to file what was in it.
 *
 * The fixture below is the shape a mail client actually sends a note
 * with a document on it: a multipart/mixed with a text part, an HTML
 * part and a base64 attachment. What is asserted is mostly the ways
 * this can be quietly wrong, because `attachmentsIn` returning nothing
 * looks exactly like a message that had no attachment — which is the
 * failure `0354` exists to end.
 */
const withPdf = [
  "From: supplier@example.test",
  "Subject: Invoice 4471",
  'Content-Type: multipart/mixed; boundary="XX"',
  "",
  "--XX",
  "Content-Type: text/plain; charset=utf-8",
  "",
  "See attached.",
  "--XX",
  "Content-Type: text/html; charset=utf-8",
  "",
  "<p>See attached.</p>",
  "--XX",
  'Content-Type: application/pdf; name="invoice-4471.pdf"',
  'Content-Disposition: attachment; filename="invoice-4471.pdf"',
  "Content-Transfer-Encoding: base64",
  "",
  "JVBERi0xLjQK",
  "CiUlRU9GCg==",
  "--XX--",
].join("\r\n");

Deno.test("the note and the document both come out", () => {
  const got = parse(withPdf);
  assertEquals(got.text, "See attached.");
  assertEquals(got.html, "<p>See attached.</p>");
  assertEquals(got.attachments.length, 1);
  assertEquals(got.attachments[0].filename, "invoice-4471.pdf");
  assertEquals(got.attachments[0].content_type, "application/pdf");
});

Deno.test("base64 comes out without the wrapping it travelled in", () => {
  // Wrapped across lines is how base64 is sent. Left in, the decode
  // either throws or produces the wrong bytes.
  assertEquals(attachmentsIn(withPdf)[0].content_base64, "JVBERi0xLjQKCiUlRU9GCg==");
});

Deno.test("a document is not mistaken for the body of the message", () => {
  // A text/plain part that names a file is a CSV bank statement, not
  // the covering note. Without the filename check it becomes the body
  // and the real note disappears.
  const csv = [
    'Content-Type: multipart/mixed; boundary="YY"',
    "",
    "--YY",
    "Content-Type: text/plain",
    "",
    "Statement attached.",
    "--YY",
    'Content-Type: text/plain; name="jan.csv"',
    'Content-Disposition: attachment; filename="jan.csv"',
    "Content-Transfer-Encoding: base64",
    "",
    "ZGF0ZSxhbW91bnQK",
    "--YY--",
  ].join("\r\n");

  const got = parse(csv);
  assertEquals(got.text, "Statement attached.");
  assertEquals(got.attachments.length, 1);
  assertEquals(got.attachments[0].filename, "jan.csv");
});

Deno.test("even when the document is sent before the note", () => {
  // `text ??=` keeps the first text part it sees, so a message that
  // leads with a text/plain attachment hands the screen the attachment
  // as the body and loses the note entirely. Some clients do send them
  // in that order.
  const attachmentFirst = [
    'Content-Type: multipart/mixed; boundary="YZ"',
    "",
    "--YZ",
    'Content-Type: text/plain; name="jan.csv"',
    'Content-Disposition: attachment; filename="jan.csv"',
    "Content-Transfer-Encoding: base64",
    "",
    "ZGF0ZSxhbW91bnQK",
    "--YZ",
    "Content-Type: text/plain",
    "",
    "Statement attached.",
    "--YZ--",
  ].join("\r\n");

  const got = parse(attachmentFirst);
  assertEquals(got.text, "Statement attached.");
  assertEquals(got.attachments.map((a) => a.filename), ["jan.csv"]);
});

Deno.test("a part that names nothing is not a document", () => {
  // `filename=""` is what a few clients send on a part that is not an
  // attachment at all. Treated as a name it produces a file called
  // nothing, stored under a path ending in a dash.
  const empty = [
    'Content-Type: multipart/mixed; boundary="EE"',
    "",
    "--EE",
    "Content-Type: text/plain",
    "",
    "Nothing attached.",
    "--EE",
    'Content-Type: application/octet-stream; filename=""',
    "Content-Transfer-Encoding: base64",
    "",
    "AAAA",
    "--EE--",
  ].join("\r\n");

  assertEquals(attachmentsIn(empty), []);
  assertEquals(parse(empty).text, "Nothing attached.");

  // And the same part with a space where the name should be, which is
  // the version the regular expression does match. Trimmed it is
  // nothing, and nothing is not a filename — a file called "" is
  // stored under a path ending in a dash and offered to somebody as a
  // download with no name on it.
  const blank = empty.replace('filename=""', 'filename=" "');
  assertEquals(attachmentsIn(blank), []);
});

Deno.test("a part in an encoding we cannot trust is skipped, not guessed", () => {
  // quoted-printable through a base64 decoder is a corrupt file that
  // looks like a scanning fault.
  const qp = withPdf.replace(
    "Content-Transfer-Encoding: base64",
    "Content-Transfer-Encoding: quoted-printable",
  );
  assertEquals(attachmentsIn(qp).length, 0);
});

Deno.test("a message with nothing attached says so, and still reads", () => {
  const plain = [
    "Subject: Just asking",
    "Content-Type: text/plain",
    "",
    "Do you deliver on Sundays?",
  ].join("\r\n");

  const got = parse(plain);
  assertEquals(got.attachments, []);
  assertEquals(got.text, "Do you deliver on Sundays?");
});

Deno.test("a filename on the content type alone still counts", () => {
  // Some clients put `name=` on Content-Type and no Content-Disposition
  // at all. Dropping those loses real documents.
  const nameOnly = [
    'Content-Type: multipart/mixed; boundary="ZZ"',
    "",
    "--ZZ",
    "Content-Type: text/plain",
    "",
    "Here.",
    "--ZZ",
    'Content-Type: image/jpeg; name="receipt.jpg"',
    "Content-Transfer-Encoding: base64",
    "",
    "/9j/4AAQSkZJRg==",
    "--ZZ--",
  ].join("\r\n");

  assertEquals(attachmentsIn(nameOnly).map((a) => a.filename), ["receipt.jpg"]);
});

Deno.test("ten is as many as one message carries", () => {
  const parts = [];
  for (let i = 0; i < 15; i++) {
    parts.push(
      "--AA",
      `Content-Type: application/pdf; name="f${i}.pdf"`,
      "Content-Transfer-Encoding: base64",
      "",
      "AAAA",
    );
  }
  const many = [
    'Content-Type: multipart/mixed; boundary="AA"',
    "",
    ...parts,
    "--AA--",
  ].join("\r\n");

  assertEquals(attachmentsIn(many).length, 10);
});

Deno.test("and more than a worker can hold is left behind, not truncated", () => {
  // Half a file is worse than no file: it stores, it opens, and it is
  // wrong.
  const big = "A".repeat(21 * 1024 * 1024);
  const heavy = [
    'Content-Type: multipart/mixed; boundary="BB"',
    "",
    "--BB",
    'Content-Type: application/zip; name="everything.zip"',
    "Content-Transfer-Encoding: base64",
    "",
    big,
    "--BB--",
  ].join("\r\n");

  assertEquals(attachmentsIn(heavy).length, 0);
});

Deno.test("a boundary declaration is not a filename", () => {
  // `boundary="XX"` and `name="XX"` are both `name=`-shaped to a
  // careless regular expression, and a header block that matched would
  // turn every part into an attachment.
  const got = split(withPdf);
  assertEquals(got.text, "See attached.");
});
