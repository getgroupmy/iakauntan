/**
 * Which token gets which notification.
 *
 * Every failure this file is written against is invisible from the
 * outside. Apple refuses a misrouted push with a four-word reason in a
 * JSON body nobody reads; a PushKit push sent to an app that cannot
 * report it to CallKit gets the app killed by the operating system, and
 * what the person sees is that their phone stopped ringing one day. So
 * the routing decision is a pure function and this asserts it directly
 * rather than through a fetch.
 */
import { assertEquals } from "jsr:@std/assert@1";
import { appleDelivery, Target, transportOf } from "./routing.ts";

const phone = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F";
const other = "11111111-2222-3333-4444-555555555555";

function target(over: Partial<Target> = {}): Target {
  return {
    user_id: "u1",
    token: "t",
    platform: "ios",
    p256dh: null,
    auth: null,
    ...over,
  };
}

Deno.test("a row that predates 0657 is Firebase, unless it is a browser", () => {
  assertEquals(transportOf(target({ transport: undefined })), "fcm");
  assertEquals(
    transportOf(target({ platform: "android", transport: undefined })),
    "fcm",
  );
  assertEquals(
    transportOf(target({ platform: "web", transport: undefined })),
    "web",
  );
});

Deno.test("a stated transport is believed over the platform", () => {
  assertEquals(transportOf(target({ transport: "apns" })), "apns");
  assertEquals(transportOf(target({ transport: "apns_voip" })), "apns_voip");
});

Deno.test("a PushKit token takes a call", () => {
  assertEquals(
    appleDelivery(target({ transport: "apns_voip" }), true, new Set()),
    "voip",
  );
});

Deno.test("and a PushKit token takes NOTHING else", () => {
  // The one that matters most in this file. A message delivered to a
  // VoIP token wakes the app to report an incoming call that does not
  // exist; iOS kills an app that fails to, and kills it often enough to
  // revoke the registration. The cost of this line being wrong is not a
  // missed message, it is a handset that stops receiving calls.
  assertEquals(
    appleDelivery(target({ transport: "apns_voip" }), false, new Set()),
    null,
  );
});

Deno.test("an alert token takes a message", () => {
  assertEquals(
    appleDelivery(target({ transport: "apns" }), false, new Set([phone])),
    "alert",
  );
});

Deno.test("including on a handset that IS ringing for something", () => {
  // `ringing` is built from the PushKit rows in the room, whatever kind
  // of notification this is — so a handset that holds both tokens is in
  // that set even while a MESSAGE is being sent. Suppression must be
  // asked only about a call. Without that the iPhones this whole piece
  // of work exists to reach would be the only ones never told about a
  // message, and a survivor of exactly this mutation is what put this
  // assertion here.
  assertEquals(
    appleDelivery(
      target({ transport: "apns", device_id: phone }),
      false,
      new Set([phone]),
    ),
    "alert",
  );
});

Deno.test("an alert token stays quiet about a call its own handset is ringing for", () => {
  assertEquals(
    appleDelivery(
      target({ transport: "apns", device_id: phone }),
      true,
      new Set([phone]),
    ),
    null,
  );
});

Deno.test("but rings for a call on ANOTHER handset of the same person", () => {
  // The reason the pairing is by handset rather than by person. Someone
  // carrying two iPhones, one on a build that registers PushKit and one
  // on a build that does not, must still hear about the call on the
  // second — suppressing by user would silence its only chance.
  assertEquals(
    appleDelivery(
      target({ transport: "apns", device_id: other }),
      true,
      new Set([phone]),
    ),
    "alert",
  );
});

Deno.test("a handset that cannot be paired is banner-ed rather than silenced", () => {
  // Registered before `0658`, so there is no device_id to pair on. The
  // choice is between a duplicate notification and a missed call, and
  // this errs at the duplicate on purpose.
  assertEquals(
    appleDelivery(
      target({ transport: "apns", device_id: null }),
      true,
      new Set([phone]),
    ),
    "alert",
  );
  assertEquals(
    appleDelivery(target({ transport: "apns" }), true, new Set([phone])),
    "alert",
  );
});

Deno.test("an empty ringing set changes nothing for messages", () => {
  // The control. Every assertion above about suppression would also
  // pass if `appleDelivery` returned "alert" for everything that is not
  // PushKit, so this pins the other half: with nobody ringing, the
  // alert row behaves identically for a call and for a message.
  const row = target({ transport: "apns", device_id: phone });
  assertEquals(appleDelivery(row, true, new Set()), "alert");
  assertEquals(appleDelivery(row, false, new Set()), "alert");
});
