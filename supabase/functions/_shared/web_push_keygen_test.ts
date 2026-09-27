import { assert, assertEquals, assertMatch, assertStringIncludes } from "jsr:@std/assert@1.0.19";
import { b64urlDecode, vapidAuthorization } from "./web_push.ts";

/**
 * The script that makes the VAPID pair, checked against the code that
 * consumes it.
 *
 * `web_push_test.ts` already asserts the consumer end thoroughly,
 * including what happens when the two halves are not a pair. Nothing
 * asserted that THIS script produces a pair that end accepts -- and the
 * two are as far apart in time as software gets. It is run once, by
 * hand, by an operator setting up a project; if it printed a key in the
 * wrong format the failure would surface weeks later as a browser
 * refusing to subscribe, or as every push answering 403, with no
 * remaining connection to the afternoon somebody ran a keygen.
 *
 * So this runs it for real and feeds what it printed into
 * `vapidAuthorization`, which is the production consumer and performs
 * the pairing check itself. A regression in the export format fails
 * here with that consumer's own message.
 *
 * Running it IS importing it: the script is top-level statements, so
 * console.log is captured around the import.
 */

const printed: string[] = [];
const realLog = console.log;
console.log = (...args: unknown[]) => void printed.push(args.map(String).join(" "));
try {
  await import("./web_push_keygen.ts");
} finally {
  console.log = realLog;
}
const output = printed.join("\n");

function secret(name: string): string {
  const match = output.match(new RegExp(`${name}\\s+(\\S+)`));
  assert(match, `${name} was not printed at all:\n${output}`);
  return match[1];
}

const PUBLIC_KEY = secret("WEB_PUSH_PUBLIC_KEY");
const PRIVATE_KEY = secret("WEB_PUSH_PRIVATE_KEY");

Deno.test("the public key is the form a browser will subscribe with", () => {
  // `applicationServerKey` must be the uncompressed P-256 point: 65
  // bytes beginning 0x04. Export "spki" instead of "raw" and you get a
  // longer, well-formed, base64url string that every browser refuses.
  const bytes = b64urlDecode(PUBLIC_KEY);
  assertEquals(bytes.length, 65);
  assertEquals(bytes[0], 0x04);
  // base64url, not base64: a `+` or a `/` in a dart-define is a
  // different kind of bad day.
  assertMatch(PUBLIC_KEY, /^[A-Za-z0-9_-]+$/);
});

Deno.test("the private key is the raw scalar web_push.ts reads", () => {
  // WebCrypto will not export a raw EC scalar, so the script takes `d`
  // out of the JWK. `d` is 32 bytes; anything else and the consumer
  // refuses it by length.
  const bytes = b64urlDecode(PRIVATE_KEY);
  assertEquals(bytes.length, 32);
  assertMatch(PRIVATE_KEY, /^[A-Za-z0-9_-]+$/);
});

Deno.test("the two halves are a pair, according to the code that uses them", async () => {
  // Not a re-implementation of the check: this is the production path.
  // `vapidAuthorization` imports both halves, signs with one, verifies
  // with the other, and throws "are not a pair" if they disagree.
  const header = await vapidAuthorization(
    { publicKey: PUBLIC_KEY, privateKey: PRIVATE_KEY, subject: "mailto:ops@example.test" },
    "https://fcm.googleapis.com/fcm/send/abc123",
  );
  assertStringIncludes(header, "vapid t=");
  // The header carries the public key the push service checks the
  // signature with, and it must be the one that was printed.
  assertStringIncludes(header, `k=${PUBLIC_KEY}`);
});

Deno.test("every run is a new pair", async () => {
  // Regenerating invalidates every subscription every browser has
  // already made, which is why the script's own text says to run it
  // once. A generator that returned a fixed key would make that
  // warning false and hand every project the same identity.
  const second: string[] = [];
  const realLog = console.log;
  console.log = (...args: unknown[]) => void second.push(args.map(String).join(" "));
  try {
    // A query string defeats the module cache, so the script runs again.
    await import("./web_push_keygen.ts?again");
  } finally {
    console.log = realLog;
  }
  const other = second.join("\n").match(/WEB_PUSH_PUBLIC_KEY\s+(\S+)/);
  assert(other, "the second run printed nothing");
  assert(other[1] !== PUBLIC_KEY, "two runs produced the same key");
});

Deno.test("the build-time copy is the public key, and only that", () => {
  // The browser subscribes with the public key, so it is also a
  // dart-define -- and that value goes into a bundle anybody can read.
  // The script prints it twice; the two copies being different would
  // silently break subscription, and the private one appearing here at
  // all would put the sending identity in the Flutter bundle.
  const define = output.match(/--dart-define=WEB_PUSH_PUBLIC_KEY=(\S+)/);
  assert(define, `no dart-define line was printed:\n${output}`);
  assertEquals(define[1], PUBLIC_KEY);

  // The private key appears ONCE in the whole output, in the secrets
  // block. Checking only inside the public define is not enough: a
  // SECOND --dart-define carrying the private key would pass that and
  // put the sending identity in a bundle anybody can read. Counted over
  // the entire output so there is nowhere for it to be.
  assertEquals(
    output.split(PRIVATE_KEY).length - 1,
    1,
    "the private key is printed more than once, so it is somewhere it " +
      "does not belong",
  );
  const build = output.match(/flutter build web[^\n]*/);
  assert(build, "no build command was printed");
  assert(
    !build[0].includes(PRIVATE_KEY),
    `the private key reached the build command: ${build[0]}`,
  );
  assertStringIncludes(build[0], PUBLIC_KEY);

  // And the instructions still name where the secrets go, since the
  // whole output is what the operator acts on. Unwrapped first: the
  // text is hard-wrapped, so "not in the Flutter bundle" is not a
  // substring of it as printed.
  const prose = output.replace(/\s+/g, " ");
  assertStringIncludes(prose, "Edge Functions");
  assertStringIncludes(prose, "not in the Flutter bundle");
});
