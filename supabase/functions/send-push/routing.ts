/**
 * Which token a notification may go to, and which it must not.
 *
 * Its own module so it can be tested without starting a server:
 * `index.ts` calls `serveFunction` at the top level, and the decisions
 * below are the part of this function whose mistakes are invisible from
 * the outside — a wrongly routed push is answered by Apple, not by
 * anybody looking at the app.
 */
export interface Target {
  user_id: string;
  token: string;
  platform: "android" | "ios" | "web";
  /**
   * Which service this token belongs to. `0657`.
   *
   * Read rather than inferred from the platform, because an iOS row is
   * either — and defaulted here only so a payload from a database that
   * predates `0657` behaves as it did, which is Firebase for anything
   * that is not a browser.
   */
  transport?: "web" | "fcm" | "apns" | "apns_voip";
  /**
   * Which handset this token came from, where the platform can say.
   * `0658`. An iPhone writes the same value on its alert row and its
   * PushKit row, which is the only thing that lets this function ring a
   * phone through CallKit without also banner-ing it about that call.
   * Null for a browser and for anything registered before `0658`.
   */
  device_id?: string | null;
  /** Browsers only: what the payload is encrypted to. See 0143. */
  p256dh: string | null;
  auth: string | null;
}

export type Transport = "web" | "fcm" | "apns" | "apns_voip";

/** The service a row goes to, with the pre-`0657` default applied. */
export function transportOf(target: Target): Transport {
  return target.transport ?? (target.platform === "web" ? "web" : "fcm");
}

/**
 * What, if anything, an Apple row should be sent for this notification.
 *
 * The two Apple transports are not two ways of doing the same thing and
 * the wrong one is worse than nothing — see `0658`. This is the whole
 * decision, in one pure function, because the consequences of getting
 * it wrong are invisible from here:
 *
 *   * A PushKit token takes a CALL and only a call. An app woken by a
 *     VoIP push that does not then report an incoming call to CallKit
 *     is KILLED by iOS, and killed often enough has its PushKit
 *     registration revoked. So a message sent to a VoIP token does not
 *     merely fail, it degrades the handset's ability to receive calls.
 *
 *   * An alert token takes a call too — as a banner — but must not,
 *     when the SAME handset is already being rung through CallKit.
 *     `ringing` holds the device_ids that are, and pairing is by
 *     handset rather than by person because somebody may carry one
 *     iPhone on a build that registers PushKit and one on a build that
 *     does not.
 *
 *   * A row with no device_id cannot be paired, so it gets the banner.
 *     A duplicate notification is a smaller harm than a missed call,
 *     and that is the direction this errs in on purpose.
 */
export function appleDelivery(
  target: Target,
  isCall: boolean,
  ringing: ReadonlySet<string>,
): "alert" | "voip" | null {
  if (transportOf(target) === "apns_voip") return isCall ? "voip" : null;
  if (!isCall) return "alert";
  const handset = target.device_id;
  return handset && ringing.has(handset) ? null : "alert";
}
