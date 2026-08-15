/**
 * Generate the VAPID key pair that turns web notifications on.
 *
 *   deno run supabase/functions/_shared/web_push_keygen.ts
 *
 * No account anywhere. That is the whole point of web push: the key pair
 * *is* the identity, and it is made here rather than granted by Google
 * or Apple.
 *
 * Run it once. Regenerating invalidates every subscription every browser
 * has already made — they were made against the old public key, and a
 * push signed with a different one is refused — so every person would
 * have to press "Turn on" again, with nothing on screen explaining why
 * their notifications stopped.
 */
function b64url(bytes: Uint8Array): string {
  return btoa(Array.from(bytes, (b) => String.fromCharCode(b)).join(""))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

const pair = await crypto.subtle.generateKey(
  { name: "ECDSA", namedCurve: "P-256" },
  true,
  ["sign", "verify"],
);

const publicKey = b64url(
  new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey)),
);

// The private half comes out as a JWK because WebCrypto will not export
// a raw scalar. `d` is that scalar, base64url, which is the form
// `_shared/web_push.ts` reads.
const jwk = await crypto.subtle.exportKey("jwk", pair.privateKey);

console.log(`
Two secrets, set under Edge Functions → Secrets:

  WEB_PUSH_PUBLIC_KEY   ${publicKey}
  WEB_PUSH_PRIVATE_KEY  ${jwk.d}

And the public one again at build time, because the browser subscribes
with it:

  flutter build web --dart-define=WEB_PUSH_PUBLIC_KEY=${publicKey}

The private key is a secret in the ordinary sense — anybody holding it
can send notifications as this application. It belongs in the function
secrets and nowhere else: not in the repository, not in a migration, not
in the Flutter bundle.
`);
