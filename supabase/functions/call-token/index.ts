/**
 * call-token
 *
 * Hands a caller the two things a signalling row deliberately does not
 * carry: where the media server is, and proof they are allowed into the
 * room. `chat_calls.room_name` is opaque and random, but a room name is
 * not a credential — anybody who could read one could otherwise walk
 * into the room. So the room name buys nothing on its own, and this is
 * what buys entry.
 *
 * POST { "call_id": "<uuid>" }
 *   -> { url, room, peer_id, display_name, token, ice_servers, expires_at }
 *
 * Two secrets are involved and neither may exist anywhere else:
 *
 *   CALL_SFU_SECRET   signs the room token the mediasoup server checks
 *   CALL_TURN_SECRET  the coturn `static-auth-secret`, from which the
 *                     REST username/password pair is derived
 *
 * Both are HMAC keys. Either one in the database or in the Flutter
 * bundle would let anybody mint their own entry to any room, which is
 * the whole reason this function exists rather than a SQL function.
 *
 * Configuration, none of it secret:
 *   CALL_SFU_URL      wss://sfu.example.my  (the signalling socket)
 *   CALL_TURN_URLS    comma separated, e.g.
 *                     "turn:turn.example.my:3478?transport=udp,
 *                      turns:turn.example.my:5349?transport=tcp"
 *   CALL_STUN_URLS    comma separated, optional; defaults to the TURN
 *                     hosts' STUN ports if unset and nothing else.
 *
 * The protocol the token is presented to — and everything the server on
 * the other end has to implement — is written down in
 * `docs/call-signalling.md`. mediasoup is a library, not a server, so
 * that document is the contract rather than a description of one.
 */
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, fail, json } from "../_shared/cors.ts";

/**
 * How long the credentials are good for.
 *
 * Long enough for a long meeting, short enough that a leaked token is
 * not a standing invitation. It bounds entry, not the call: a token
 * checked at the door does not expire the media once you are through
 * it, which is the behaviour we want — nobody is thrown out of an
 * hour-and-a-half call because the clock ran out.
 */
const TTL_SECONDS = 60 * 90;

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

async function hmac(
  secret: string,
  message: string,
  hash: "SHA-256" | "SHA-1",
): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(message),
  );
  return new Uint8Array(sig);
}

/** A compact HS256 JWT. The SFU verifies it with the same secret. */
async function signRoomToken(
  secret: string,
  claims: Record<string, unknown>,
): Promise<string> {
  const encode = (o: unknown) =>
    base64url(new TextEncoder().encode(JSON.stringify(o)));
  const body = `${encode({ alg: "HS256", typ: "JWT" })}.${encode(claims)}`;
  return `${body}.${base64url(await hmac(secret, body, "SHA-256"))}`;
}

/**
 * coturn's REST API credentials, which are not stored anywhere.
 *
 * The username is `<expiry unix seconds>:<anything>` and the password is
 * the base64 of HMAC-SHA1 of that username under the shared secret.
 * coturn recomputes it on each request, so no account is created and
 * nothing has to be revoked — the pair simply stops working. This is
 * RFC 7635 in the form coturn actually implements (`use-auth-secret`).
 */
async function turnCredentials(
  secret: string,
  peerId: string,
  expiresAt: number,
): Promise<{ username: string; credential: string }> {
  const username = `${expiresAt}:${peerId}`;
  const digest = await hmac(secret, username, "SHA-1");
  return { username, credential: btoa(String.fromCharCode(...digest)) };
}

function list(name: string): string[] {
  return (Deno.env.get(name) ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return fail("Missing Authorization header", 401);

    const sfuUrl = Deno.env.get("CALL_SFU_URL");
    const sfuSecret = Deno.env.get("CALL_SFU_SECRET");
    if (!sfuUrl || !sfuSecret) {
      // Said plainly, because the alternative is a call that fails with
      // a network error and a week spent looking at the wrong end.
      return fail(
        "Calling is not configured. Set CALL_SFU_URL and CALL_SFU_SECRET " +
          "in the project's function secrets.",
        503,
      );
    }

    const body = (await req.json().catch(() => ({}))) as
      Record<string, unknown>;
    const callId = body.call_id as string | undefined;
    if (!callId) return fail("call_id is required");

    // Everything below reads through the caller's own token, so row
    // level security decides what they can see. A forged call_id gets
    // nothing back and is refused two lines later.
    const userClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );

    const { data: userData } = await userClient.auth.getUser();
    if (!userData?.user) return fail("Not authenticated", 401);
    const userId = userData.user.id;

    const { data: call } = await userClient
      .from("chat_calls")
      .select("id, room_name, status, kind, conversation_id")
      .eq("id", callId)
      .maybeSingle();

    if (!call) return fail("No such call, or you are not in it", 403);
    if (call.status !== "ringing" && call.status !== "live") {
      return fail(`That call is ${call.status}`, 409);
    }

    // Seeing a call and being in it are different things — the select
    // policy shows every call in a conversation you belong to, which is
    // right for a thread that says "call in progress" and wrong as a
    // key. Entry needs a participant row that has actually joined, which
    // is what `chat_join_call` writes. So the client joins first and
    // asks for credentials second; asking in the other order is refused
    // rather than quietly handed a token.
    const { data: me } = await userClient
      .from("chat_call_participants")
      .select("state")
      .eq("call_id", callId)
      .eq("user_id", userId)
      .maybeSingle();

    if (!me || me.state !== "joined") {
      return fail(
        "Join the call before asking for its credentials",
        403,
      );
    }

    // The display name is looked up rather than taken from the request:
    // it is shown to everybody else in the room, and a name a client
    // chooses for itself is a name a client can choose to be somebody
    // else's.
    const { data: profile } = await userClient
      .from("profiles")
      .select("full_name, email")
      .eq("id", userId)
      .maybeSingle();

    const expiresAt = Math.floor(Date.now() / 1000) + TTL_SECONDS;

    const token = await signRoomToken(sfuSecret, {
      sub: userId,
      room: call.room_name,
      kind: call.kind,
      name: profile?.full_name ?? profile?.email ?? "Somebody",
      iat: Math.floor(Date.now() / 1000),
      exp: expiresAt,
    });

    const iceServers: Record<string, unknown>[] = [];
    const stun = list("CALL_STUN_URLS");
    if (stun.length > 0) iceServers.push({ urls: stun });

    const turn = list("CALL_TURN_URLS");
    const turnSecret = Deno.env.get("CALL_TURN_SECRET");
    if (turn.length > 0 && turnSecret) {
      const { username, credential } = await turnCredentials(
        turnSecret,
        userId,
        expiresAt,
      );
      iceServers.push({ urls: turn, username, credential });
    }

    return json({
      url: sfuUrl,
      room: call.room_name,
      peer_id: userId,
      display_name: profile?.full_name ?? profile?.email ?? "Somebody",
      token,
      ice_servers: iceServers,
      expires_at: new Date(expiresAt * 1000).toISOString(),
    });
  } catch (error) {
    return fail((error as Error).message ?? "Unexpected error", 500);
  }
});
