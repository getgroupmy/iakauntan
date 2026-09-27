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
 * ---------------------------------------------------------------------
 * Three transports, configured independently
 *
 * A browser is not reached through Firebase. `pushManager.subscribe`
 * hands back an endpoint and two keys, and anybody with a VAPID key
 * pair can post to it — no Google project, no third party. So web push
 * goes straight out from `_shared/web_push.ts`, encrypted under RFC 8291
 * to keys only that browser holds.
 *
 * An iPhone need not go through Firebase either. `0657` and
 * `_shared/apns.ts` address APNs directly with a `.p8`, which is both
 * one fewer party in the middle and the only way to send the PushKit
 * VoIP push a real CallKit incoming-call screen needs — FCM cannot, and
 * a banner is not a ringing phone. Which service an iOS row uses is
 * `device_tokens.transport`, because the tokens are not interchangeable
 * and sending one to the other service fails silently.
 *
 * Apple is TWO of those transports, not one. `apns` is the alert token
 * and `apns_voip` is the PushKit token, one handset holds both, and
 * which of them a given notification may go to is `appleDelivery` — see
 * `0658`, and see that function for why sending to the wrong one costs
 * more than a dropped notification.
 *
 * Android is Firebase and nothing else. There is no direct equivalent.
 *
 * None of the three is required. A deployment with only the VAPID pair
 * reaches every browser and reports the phones as skipped, and the
 * response says which — a half-configured system that looks like it
 * worked is the failure this whole function is arranged to avoid.
 *
 * Secrets, which live only in Edge Functions → Secrets:
 *   WEB_PUSH_PUBLIC_KEY   VAPID public key, base64url  (browsers)
 *   WEB_PUSH_PRIVATE_KEY  VAPID private key, base64url (browsers)
 *   WEB_PUSH_SUBJECT      mailto: or https: contact    (optional)
 *   FCM_SERVICE_ACCOUNT   the Firebase service account JSON, whole
 *   APNS_KEY_P8           the .p8 auth key, PEM            (iPhones)
 *   APNS_KEY_ID           its 10-character Key ID          (iPhones)
 *   APNS_TEAM_ID          the Apple team identifier        (iPhones)
 *   APNS_TOPIC            the app's bundle identifier      (iPhones)
 *   APNS_PRODUCTION       "true" for the production host, else sandbox
 */
import { createClient } from "jsr:@supabase/supabase-js@2.117.0";
import {
  fail,
  failUnexpected,
  json,
  logFailure,
  serveFunction,
} from "../_shared/cors.ts";
import { requireEnv } from "../_shared/env.ts";
import { googleAccessToken, ServiceAccount } from "../_shared/google_auth.ts";
import { sendWebPush, vapidFromEnv } from "../_shared/web_push.ts";
import {
  apnsFromEnv,
  ApnsKeys,
  apnsPushType,
  sendApns,
} from "../_shared/apns.ts";

import { appleDelivery, Target, transportOf } from "./routing.ts";

const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

/**
 * One Firebase message, shaped per platform.
 *
 * Android and iOS only. A browser never comes through here — it is
 * encrypted and posted directly, further down.
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

serveFunction("send-push.failed", async (req: Request) => {
  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return fail("Missing Authorization header", 401);

    // The two transports are configured independently, and a deployment
    // that has only one of them is the normal case rather than a broken
    // one: web push needs nothing but a key pair generated locally,
    // while Firebase needs a Google project. So neither is required
    // here — what is refused, further down, is having nobody reachable
    // by anything.
    const vapid = vapidFromEnv();

    // `0657`. Throws rather than answering null when it is HALF set,
    // which is somebody midway through a job — see `apnsFromEnv`.
    let apns: ApnsKeys | null;
    try {
      apns = apnsFromEnv();
    } catch (error) {
      return fail((error as Error).message, 500);
    }

    const raw = Deno.env.get("FCM_SERVICE_ACCOUNT");
    let account: (ServiceAccount & { project_id?: string }) | null = null;
    if (raw) {
      try {
        account = JSON.parse(raw);
      } catch {
        return fail("FCM_SERVICE_ACCOUNT is not valid JSON", 500);
      }
      if (!account?.project_id) {
        return fail(
          "FCM_SERVICE_ACCOUNT has no project_id: it is not a Firebase " +
            "service account JSON.",
          500,
        );
      }
    }

    const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
    const conversationId = body.conversation_id as string | undefined;
    const kind = (body.kind as string | undefined) ?? "message";
    if (!conversationId) return fail("conversation_id is required");
    if (kind !== "message" && kind !== "call") {
      return fail(`Unknown kind: ${kind}`);
    }

    const url = requireEnv("SUPABASE_URL");
    const userClient = createClient(url, requireEnv("SUPABASE_ANON_KEY"), {
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
      requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
    );

    const { data: targets, error: targetsError } = await admin.rpc(
      "push_targets",
      { p_conversation_id: conversationId, p_exclude_user: senderId },
    );
    if (targetsError) {
      const ref = logFailure(targetsError, "send-push.targets-failed");
      return fail("Could not work out who to notify.", 500, { ref });
    }

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

    // A browser subscription is encrypted to its own keys and posted to
    // its own push service; a phone goes to Firebase. 0143's constraint
    // means a web row always has both keys, so a web target without them
    // cannot exist — but this is the code that would encrypt to nothing
    // if it ever did, so it checks.
    const web = list.filter(
      (t) => transportOf(t) === "web" && t.p256dh && t.auth,
    );
    // `0657`. Firebase and APNs are both "a phone", and which one a row
    // is on is the row's own business rather than its platform's.
    const mobile = list.filter((t) => transportOf(t) === "fcm");
    // `0658`. Both Apple transports need the same four secrets, so they
    // are one question for configuration and two for routing.
    const apple = list.filter(
      (t) => transportOf(t) === "apns" || transportOf(t) === "apns_voip",
    );
    // The handsets that will be rung through CallKit, so the alert row
    // belonging to each of them can stay quiet about the same call.
    const ringing = new Set(
      list
        .filter((t) => transportOf(t) === "apns_voip")
        .map((t) => t.device_id)
        .filter((id): id is string => Boolean(id)),
    );

    if (
      (web.length === 0 || !vapid) &&
      (mobile.length === 0 || !account) &&
      (apple.length === 0 || !apns)
    ) {
      // Said plainly and with a 503, because the alternative is silence:
      // messages arrive, notifications do not, and nothing anywhere says
      // why. Which secret is missing depends on who was in the room.
      const missing = [
        web.length > 0 && !vapid
          ? "WEB_PUSH_PUBLIC_KEY and WEB_PUSH_PRIVATE_KEY (browsers)"
          : null,
        mobile.length > 0 && !account
          ? "FCM_SERVICE_ACCOUNT (Android, and iOS through Firebase)"
          : null,
        apple.length > 0 && !apns
          ? "APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID and APNS_TOPIC (iOS)"
          : null,
      ].filter(Boolean).join(", ");

      return fail(
        `Push is not configured for the devices in this conversation. Set ${missing} ` +
          "in the project's function secrets — see docs/push-notifications.md.",
        503,
      );
    }

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
    // Devices whose transport nobody has configured. Reported rather
    // than counted as sent, so a half-configured deployment is visible
    // in the response instead of looking like it worked.
    let skipped = 0;
    // `0658`. A registration that exists and is healthy but is the
    // wrong token for THIS notification: a PushKit token during a
    // message, or the alert token of a handset already being rung.
    // Counted separately from `skipped`, which means nobody configured
    // the transport, because the two need opposite responses.
    let unsuited = 0;

    const isCall = kind === "call";

    /** Firebase, for phones. */
    const toMobile = async (target: Target, accessToken: string) => {
      const endpoint =
        `https://fcm.googleapis.com/v1/projects/${account!.project_id}/messages:send`;
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
        // An app that was uninstalled, or a token Google has rotated.
        // Left on the register it is retried on every message forever.
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
    };

    /** Straight to the browser's push service, encrypted to its keys. */
    const toBrowser = async (target: Target) => {
      const result = await sendWebPush(
        {
          endpoint: target.token,
          p256dh: target.p256dh!,
          auth: target.auth!,
        },
        // The same payload the phones get, and the same omission: the
        // message text is not in it. The service worker composes what
        // the notification says from these fields alone.
        JSON.stringify(payload),
        vapid!,
        isCall
          // Forty-five seconds, matching `chat_calls.ringing_until`. A
          // call notification arriving after that is worse than none.
          ? { ttl: 45, urgency: "high" }
          : { ttl: 86400, urgency: "normal" },
      );

      if (result.ok) {
        sent += 1;
        return;
      }
      if (result.gone) {
        await admin.rpc("forget_device_token", { p_token: target.token });
        forgotten += 1;
        return;
      }
      failed += 1;
      console.error(
        JSON.stringify({
          event: "push.refused",
          status: result.status,
          platform: "web",
          problem: result.detail,
        }),
      );
    };

    /**
     * Straight to Apple, with no Google in the middle. `0657`.
     *
     * A call goes as a VoIP push, which is the entire reason this path
     * exists: `apns-push-type: voip` to the `.voip` topic is what wakes
     * the app to draw a full-screen CallKit ring. FCM cannot send one,
     * so through Firebase the best an iPhone gets is a banner.
     */
    const toApple = async (target: Target, delivery: "alert" | "voip") => {
      // `0658`. Not `apnsPushType(kind)`: what this row can carry is
      // decided by which of Apple's two services issued its token, and
      // a call reaching an alert token is a banner rather than a ring.
      const pushType = delivery === "voip" ? apnsPushType("call") : "alert";
      const result = await sendApns(
        apns!,
        target.token,
        pushType === "voip"
          // A VoIP payload is not an alert and must not carry an `aps`
          // alert block: the OS hands the whole thing to the app, which
          // is what lets it ring rather than draw a banner.
          ? payload
          : {
            aps: {
              alert: {
                title: payload.title,
                // A handset with no PushKit token still hears about the
                // call, and "sent a message" would be a lie about it.
                body: isCall
                  ? `${payload.sender_name} is calling`
                  : `${payload.sender_name} sent a message`,
              },
              sound: "default",
            },
            // The same fields the other two transports carry, and the
            // same omission: the message text is not among them.
            ...payload,
          },
        {
          pushType,
          // Forty-five seconds for a call, matching
          // `chat_calls.ringing_until` — except that APNs counts an
          // expiry as an absolute time, and 0 means "now or never".
          // A ring arriving after the caller gave up is worse than none.
          expiration: isCall
            ? Math.floor(Date.now() / 1000) + 45
            : Math.floor(Date.now() / 1000) + 86400,
          priority: 10,
        },
      );

      if (result.ok) {
        sent += 1;
        return;
      }
      if (result.dead) {
        await admin.rpc("forget_device_token", { p_token: target.token });
        forgotten += 1;
        return;
      }
      failed += 1;
      console.error(
        JSON.stringify({
          event: "push.refused",
          status: result.status,
          platform: target.platform,
          transport: transportOf(target),
          // Apple's own word, and worth logging by name: half of them
          // are configuration rather than the handset. `BadDeviceToken`
          // in particular means the sandbox and production hosts have
          // been crossed, which no amount of retrying fixes.
          problem: result.reason,
        }),
      );
    };

    // One access token for every phone in the room rather than one each.
    const accessToken = (account && mobile.length > 0)
      ? await googleAccessToken(account, FCM_SCOPE)
      : null;

    // In parallel: a room of a dozen, one round trip each, and a call
    // that rings on the last phone a second after the first is a call
    // somebody has already missed.
    await Promise.all(
      list.map(async (target) => {
        const transport = transportOf(target);
        const isApple = transport === "apns" || transport === "apns_voip";
        const ready = transport === "web"
          ? Boolean(vapid && target.p256dh)
          : isApple
          ? Boolean(apns)
          : Boolean(accessToken);
        if (!ready) {
          skipped += 1;
          return;
        }
        // Decided before the send rather than inside it, so that "this
        // token is not for this" is an outcome of its own rather than a
        // rejection from Apple that reads like a broken handset.
        const delivery = isApple ? appleDelivery(target, isCall, ringing) : null;
        if (isApple && delivery === null) {
          unsuited += 1;
          return;
        }
        try {
          if (transport === "web") await toBrowser(target);
          else if (isApple) await toApple(target, delivery!);
          else await toMobile(target, accessToken!);
        } catch (error) {
          failed += 1;
          console.error(
            JSON.stringify({
              event: "push.failed",
              platform: target.platform,
              transport,
              error: (error as Error).message,
            }),
          );
        }
      }),
    );

    return json({
      sent,
      failed,
      forgotten,
      skipped,
      unsuited,
      targets: list.length,
    });
  } catch (error) {
    return failUnexpected(error, "send-push.failed", req);
  }
});
