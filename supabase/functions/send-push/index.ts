/**
 * send-push
 *
 * Makes a phone ring when the app is closed.
 *
 * POST { "conversation_id": "…", "kind": "message" | "call",
 *        "call_id": "…"?, "sender_name": "…"? }
 *   -> { sent, failed, forgotten }
 *
 * ---------------------------------------------------------------------
 * Why the client calls this rather than a trigger
 *
 * A database trigger firing `pg_net` would be more robust — it would
 * fire whether or not the sender's app survived the moment. It would
 * also mean putting this function's URL and a service key inside the
 * database, which is the one thing every other decision here has been
 * arranged to avoid.
 *
 * So the sender's own app asks for the fan-out, immediately after the
 * message or the call is committed. The cost is that a phone which dies
 * between `chat_send` and this call sends no notification; the message
 * is still safely in Postgres and still arrives the moment the other
 * person opens the app. That is a much better failure than a service
 * key in a table.
 *
 * The request is not trusted. The caller's own token is used to check
 * they are in that conversation, and the list of devices is read with
 * the service role — a client cannot read `push_targets` at all.
 *
 * ---------------------------------------------------------------------
 * What is deliberately NOT in the payload
 *
 * The message. A notification lands on a lock screen that anybody
 * standing near the desk can read, and this application's chat carries
 * payslips, bank details and things said about staff. So the push says
 * who it is from and where, and the text is fetched when the app is
 * opened by somebody who has authenticated.
 *
 * That is a choice, not an oversight, and it is a stricter default than
 * most chat applications use. Relaxing it means adding the body here and
 * nothing else — but it should be a decision somebody makes on purpose.
 *
 * Secrets, which live only in Edge Functions → Secrets:
 *   FCM_SERVICE_ACCOUNT   the Firebase service account JSON, whole
 */
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, fail, json } from "../_shared/cors.ts";
import { googleAccessToken, ServiceAccount } from "../_shared/google_auth.ts";

const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

interface Target {
  user_id: string;
  token: string;
  platform: "android" | "ios" | "web";
}

/**
 * One message, shaped per platform.
 *
 * A call and a message are not the same kind of interruption and must
 * not be delivered the same way:
 *
 *   - A call is **data-only** and highest priority. A `notification`
 *     block would have the operating system draw a banner, and a banner
 *     is not a ringing phone — the app has to be woken so it can show a
 *     full-screen incoming call. Data-only is what wakes it.
 *   - A message is an ordinary notification, and the system can draw it
 *     without waking anything.
 */
function buildMessage(
  target: Target,
  body: {
    kind: string;
    conversation_id: string;
    call_id?: string;
    sender_name: string;
    title: string;
    video: boolean;
  },
): Record<string, unknown> {
  const isCall = body.kind === "call";

  // Every value in a data payload must be a string. FCM rejects the
  // whole request over a number, with an error that names the field and
  // not the reason.
  const data: Record<string, string> = {
    kind: body.kind,
    conversation_id: body.conversation_id,
    sender_name: body.sender_name,
    title: body.title,
    ...(body.call_id ? { call_id: body.call_id, video: String(body.video) } : {}),
  };

  const message: Record<string, unknown> = {
    token: target.token,
    data,
    android: {
      priority: "high",
      ...(isCall
        ? {
            // Forty-five seconds, matching `chat_calls.ringing_until`.
            // A call notification arriving after that is worse than
            // none: the caller gave up long ago, and the callee gets a
            // phone ringing for somebody who is no longer there.
            ttl: "45s",
          }
        : {
            notification: {
              title: body.title,
              body: `${body.sender_name} sent a message`,
              channel_id: "chat",
            },
          }),
    },
    apns: {
      headers: {
        "apns-priority": "10",
        "apns-push-type": "alert",
        ...(isCall ? { "apns-expiration": "0" } : {}),
      },
      payload: {
        aps: isCall
          ? {
              alert: { title: body.title, body: `${body.sender_name} is calling` },
              sound: "default",
              // Wake the app so it can put a call screen up rather than
              // a banner. Real CallKit ringing needs PushKit, which FCM
              // cannot send — see docs/push-notifications.md.
              "content-available": 1,
              "interruption-level": "time-sensitive",
            }
          : {
              alert: {
                title: body.title,
                body: `${body.sender_name} sent a message`,
              },
              sound: "default",
            },
      },
    },
    webpush: {
      headers: { Urgency: "high" },
      notification: {
        title: body.title,
        body: isCall
          ? `${body.sender_name} is calling`
          : `${body.sender_name} sent a message`,
        icon: "/icons/Icon-192.png",
      },
    },
  };

  return message;
}

/** FCM's way of saying "this handset is gone". */
function isDeadToken(status: number, payload: unknown): boolean {
  if (status === 404) return true;
  const error = (payload as { error?: { details?: { errorCode?: string }[] } })
    ?.error;
  const code = error?.details?.find((d) => d.errorCode)?.errorCode;
  return code === "UNREGISTERED" || code === "INVALID_ARGUMENT";
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return fail("Missing Authorization header", 401);

    const raw = Deno.env.get("FCM_SERVICE_ACCOUNT");
    if (!raw) {
      // Said plainly and with a 503, because the alternative is silence:
      // messages arrive, notifications do not, and nothing anywhere says
      // why.
      return fail(
        "Push is not configured. Set FCM_SERVICE_ACCOUNT in the project's " +
          "function secrets — see docs/push-notifications.md.",
        503,
      );
    }

    let account: ServiceAccount & { project_id?: string };
    try {
      account = JSON.parse(raw);
    } catch {
      return fail("FCM_SERVICE_ACCOUNT is not valid JSON", 500);
    }
    if (!account.project_id) {
      return fail(
        "FCM_SERVICE_ACCOUNT has no project_id: it is not a Firebase " +
          "service account JSON.",
        500,
      );
    }

    const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
    const conversationId = body.conversation_id as string | undefined;
    const kind = (body.kind as string | undefined) ?? "message";
    if (!conversationId) return fail("conversation_id is required");
    if (kind !== "message" && kind !== "call") {
      return fail(`Unknown kind: ${kind}`);
    }

    const url = Deno.env.get("SUPABASE_URL")!;
    const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: userData } = await userClient.auth.getUser();
    if (!userData?.user) return fail("Not authenticated", 401);
    const senderId = userData.user.id;

    // Under the caller's own token, so row level security answers the
    // question. Somebody who is not in this conversation reads no row
    // and is refused — they cannot use this to make other people's
    // phones ring.
    const { data: mine } = await userClient
      .from("chat_participants")
      .select("conversation_id")
      .eq("conversation_id", conversationId)
      .eq("user_id", senderId)
      .maybeSingle();

    if (!mine) return fail("You are not in that conversation", 403);

    const admin = createClient(
      url,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: targets, error: targetsError } = await admin.rpc(
      "push_targets",
      { p_conversation_id: conversationId, p_exclude_user: senderId },
    );
    if (targetsError) return fail(targetsError.message, 500);

    const list = (targets ?? []) as Target[];
    if (list.length === 0) {
      return json({ sent: 0, failed: 0, forgotten: 0, targets: 0 });
    }

    // The name is looked up rather than taken from the request: it is
    // shown on somebody's lock screen, and a name the caller chooses is
    // a name the caller can choose to be somebody else's.
    const { data: profile } = await admin
      .from("profiles")
      .select("full_name, email")
      .eq("id", senderId)
      .maybeSingle();
    const senderName = profile?.full_name ?? profile?.email ?? "Somebody";

    const { data: conversation } = await admin
      .from("chat_conversations")
      .select("title, is_direct")
      .eq("id", conversationId)
      .maybeSingle();

    const accessToken = await googleAccessToken(account, FCM_SCOPE);
    const endpoint =
      `https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`;

    const payload = {
      kind,
      conversation_id: conversationId,
      call_id: body.call_id as string | undefined,
      sender_name: senderName,
      // A group is named; a direct conversation is titled by whoever is
      // in it, which from the recipient's side is the sender.
      title: (conversation?.is_direct === false && conversation?.title)
        ? String(conversation.title)
        : senderName,
      video: body.video === true,
    };

    let sent = 0;
    let failed = 0;
    let forgotten = 0;

    // In parallel: a room of a dozen, one round trip each, and a call
    // that rings on the last phone a second after the first is a call
    // somebody has already missed.
    await Promise.all(
      list.map(async (target) => {
        try {
          const res = await fetch(endpoint, {
            method: "POST",
            headers: {
              Authorization: `Bearer ${accessToken}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ message: buildMessage(target, payload) }),
          });

          if (res.ok) {
            sent += 1;
            return;
          }

          const problem = await res.json().catch(() => null);
          if (isDeadToken(res.status, problem)) {
            // An app that was uninstalled, or a token Google has
            // rotated. Left on the register it is retried on every
            // message forever.
            await admin.rpc("forget_device_token", { p_token: target.token });
            forgotten += 1;
            return;
          }
          failed += 1;
          console.error(
            JSON.stringify({
              event: "push.refused",
              status: res.status,
              platform: target.platform,
              problem,
            }),
          );
        } catch (error) {
          failed += 1;
          console.error(
            JSON.stringify({
              event: "push.failed",
              error: (error as Error).message,
            }),
          );
        }
      }),
    );

    return json({ sent, failed, forgotten, targets: list.length });
  } catch (error) {
    return fail((error as Error).message ?? "Unexpected error", 500);
  }
});
