import { assertEquals } from "jsr:@std/assert@1";
import { attachmentPath, decodeBase64, safeName } from "./mail_files.ts";

Deno.test("a name storage will take", () => {
  assertEquals(safeName("invoice-4471.pdf"), "invoice-4471.pdf");
  assertEquals(safeName("Invoice 4471.pdf"), "Invoice-4471.pdf");
  assertEquals(safeName("resit (2).jpg"), "resit-2-.jpg");
});

Deno.test("and one it will not", () => {
  // A name in a script storage cannot round-trip leaves nothing behind,
  // and a file with no key is one the caller must skip rather than
  // store under a path ending in a dash.
  assertEquals(safeName("发票.pdf"), ".pdf");
  assertEquals(safeName("发票"), "");
  assertEquals(safeName("   "), "");
  assertEquals(safeName(""), "");
});

Deno.test("a very long name is cut rather than refused", () => {
  const long = "a".repeat(200) + ".pdf";
  assertEquals(safeName(long).length, 80);
});

Deno.test("base64 survives the wrapping it travelled in", () => {
  // Wrapped at 76 characters is how base64 is sent, and `atob` throws
  // on the newlines. A throw is a file skipped, which looks from
  // outside exactly like a message that had no attachment.
  const wrapped = "SGVsbG8s\r\nIHdvcmxk\n";
  assertEquals(new TextDecoder().decode(decodeBase64(wrapped)), "Hello, world");
});

Deno.test("bytes come back as bytes, not as characters", () => {
  // %PDF- is the first five bytes of every PDF. Getting this wrong
  // produces a file that stores, opens, and is not a PDF.
  const pdf = decodeBase64("JVBERi0=");
  assertEquals(Array.from(pdf), [0x25, 0x50, 0x44, 0x46, 0x2d]);
});

Deno.test("a path starts with the company that owns the mailbox", () => {
  // The storage policy reads the owning company out of the first
  // segment, and `record_inbound_attachment` refuses anything else. A
  // path built the wrong way round hands one company's post to another.
  const org = "11111111-1111-1111-1111-111111111111";
  const mail = "22222222-2222-2222-2222-222222222222";
  assertEquals(
    attachmentPath(org, mail, 1, "invoice 4471.pdf"),
    `${org}/${mail}/1-invoice-4471.pdf`,
  );
});

Deno.test("two files of the same name on one message stay apart", () => {
  const org = "o";
  const mail = "m";
  assertEquals(attachmentPath(org, mail, 1, "scan.pdf"), "o/m/1-scan.pdf");
  assertEquals(attachmentPath(org, mail, 2, "scan.pdf"), "o/m/2-scan.pdf");
});

Deno.test("and a file with no usable name has no path at all", () => {
  assertEquals(attachmentPath("o", "m", 1, "发票"), null);
});
