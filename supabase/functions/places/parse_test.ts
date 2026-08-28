import { assertEquals } from "jsr:@std/assert@1";
import {
  addressFromLegacy,
  addressFromNew,
  legacyRefused,
  PlacesRefusal,
  statusOf,
  suggestionsFromLegacy,
  suggestionsFromNew,
  worthFallingBack,
} from "./parse.ts";

// Places API (New) and the legacy Places API answer the same questions
// in different words, and every way of confusing them is quiet:
//
//   * `longText` against `long_name` — read the wrong one and an
//     address comes back with every field null, which looks like a
//     place Google has no components for rather than a bug;
//   * a legacy refusal arrives as HTTP 200 with `REQUEST_DENIED` in the
//     body, so `res.ok` is true and a key problem reads as "no such
//     street";
//   * and falling back on the wrong status turns one refused call into
//     two, on a per-keystroke path that is billed.
//
// The bodies below are the shapes Google actually returns, trimmed to
// the fields this function asks for in its field masks.

const NEW_SUGGESTIONS = {
  suggestions: [
    {
      placePrediction: {
        placeId: "ChIJ_new_1",
        structuredFormat: {
          mainText: { text: "Jalan Ampang" },
          secondaryText: { text: "Kuala Lumpur, Malaysia" },
        },
      },
    },
    {
      // A suggestion that is a query rather than a place: no
      // placePrediction at all. Google sends these and they cannot be
      // looked up, so they must not become a row somebody can tap.
      queryPrediction: { text: { text: "jalan" } },
    },
  ],
};

const LEGACY_SUGGESTIONS = {
  status: "OK",
  predictions: [
    {
      place_id: "ChIJ_old_1",
      description: "Jalan Ampang, Kuala Lumpur, Malaysia",
      structured_formatting: {
        main_text: "Jalan Ampang",
        secondary_text: "Kuala Lumpur, Malaysia",
      },
    },
    {
      // No structured split. The whole line is better than a blank row.
      place_id: "ChIJ_old_2",
      description: "Lorong Ampang, Kuala Lumpur",
    },
  ],
};

const NEW_ADDRESS = {
  formattedAddress: "12 Jalan Ampang, 50450 Kuala Lumpur, Malaysia",
  addressComponents: [
    { longText: "12", shortText: "12", types: ["street_number"] },
    { longText: "Jalan Ampang", shortText: "Jln Ampang", types: ["route"] },
    { longText: "Kuala Lumpur", shortText: "KL", types: ["locality"] },
    { longText: "50450", shortText: "50450", types: ["postal_code"] },
    {
      longText: "Federal Territory of Kuala Lumpur",
      shortText: "WP KL",
      types: ["administrative_area_level_1"],
    },
    { longText: "Malaysia", shortText: "MY", types: ["country"] },
  ],
};

const LEGACY_ADDRESS = {
  status: "OK",
  result: {
    formatted_address: "12 Jalan Ampang, 50450 Kuala Lumpur, Malaysia",
    address_components: [
      { long_name: "12", short_name: "12", types: ["street_number"] },
      { long_name: "Jalan Ampang", short_name: "Jln Ampang", types: ["route"] },
      { long_name: "Kuala Lumpur", short_name: "KL", types: ["locality"] },
      { long_name: "50450", short_name: "50450", types: ["postal_code"] },
      {
        long_name: "Federal Territory of Kuala Lumpur",
        short_name: "WP KL",
        types: ["administrative_area_level_1"],
      },
      { long_name: "Malaysia", short_name: "MY", types: ["country"] },
    ],
  },
};

Deno.test("suggestions from the new API", () => {
  const out = suggestionsFromNew(NEW_SUGGESTIONS);
  assertEquals(out.length, 1, "a query prediction is not a place");
  assertEquals(out[0], {
    id: "ChIJ_new_1",
    line: "Jalan Ampang",
    detail: "Kuala Lumpur, Malaysia",
  });
});

Deno.test("suggestions from the legacy API", () => {
  const out = suggestionsFromLegacy(LEGACY_SUGGESTIONS);
  assertEquals(out.length, 2);
  assertEquals(out[0], {
    id: "ChIJ_old_1",
    line: "Jalan Ampang",
    detail: "Kuala Lumpur, Malaysia",
  });
  assertEquals(
    out[1].line,
    "Lorong Ampang, Kuala Lumpur",
    "a prediction with no structured split falls back to its description",
  );
});

Deno.test("both APIs fill the same boxes", () => {
  // The point of the whole file: whichever answered, the screen gets
  // one shape. If these two ever disagree, an address arrives complete
  // from one API and empty from the other, with nothing on screen
  // saying which one was asked.
  const fromNew = addressFromNew(NEW_ADDRESS);
  const fromLegacy = addressFromLegacy(LEGACY_ADDRESS);

  assertEquals(fromNew, fromLegacy);
  assertEquals(fromNew, {
    line1: "12 Jalan Ampang",
    city: "Kuala Lumpur",
    postcode: "50450",
    state: "Federal Territory of Kuala Lumpur",
    country: "Malaysia",
    formatted: "12 Jalan Ampang, 50450 Kuala Lumpur, Malaysia",
  });
});

Deno.test("a component Google did not send is null, not empty", () => {
  const sparse = addressFromNew({
    formattedAddress: "Somewhere",
    addressComponents: [
      { longText: "Kuala Lumpur", types: ["locality"] },
    ],
  });
  assertEquals(sparse.postcode, null);
  assertEquals(
    sparse.line1,
    null,
    "no number and no route is no line, not a lone space",
  );
  assertEquals(sparse.city, "Kuala Lumpur");
});

Deno.test("the legacy API refuses with a 200", () => {
  // The trap this whole module exists around.
  assertEquals(legacyRefused("REQUEST_DENIED"), true);
  assertEquals(legacyRefused("OVER_QUERY_LIMIT"), true);
  assertEquals(legacyRefused("INVALID_REQUEST"), true);
  assertEquals(legacyRefused("OK"), false);
  assertEquals(
    legacyRefused("ZERO_RESULTS"),
    false,
    "no matches is an answer, not a refusal",
  );
});

Deno.test("only a permission refusal is worth asking the old API", () => {
  assertEquals(worthFallingBack(403), true, "this key may not use this API");
  assertEquals(worthFallingBack(404), true, "the API is not enabled at all");
  assertEquals(worthFallingBack(429), true, "the new API's own quota");
  assertEquals(
    worthFallingBack(400),
    false,
    "a request we built wrong is built wrong for both",
  );
  assertEquals(
    worthFallingBack(500),
    false,
    "Google being down is not our cue",
  );
});

Deno.test("the status a refusal carried decides whether to fall back", () => {
  assertEquals(
    statusOf(new PlacesRefusal("places autocomplete 403 -- DENIED", 403)),
    403,
  );

  // A dropped connection carries no status. Treating "no status" as a
  // permission problem turns a network blip into a second billed call
  // against a second API.
  assertEquals(statusOf(new TypeError("error sending request")), null);
  assertEquals(statusOf(new Error("places autocomplete 403")), null);
  assertEquals(statusOf("not an error at all"), null);

  // The legacy API names its refusal in words and carries no HTTP
  // status, and its message can contain numbers of its own. Neither is
  // a cue to fall back — it *is* the fallback.
  assertEquals(
    statusOf(
      new PlacesRefusal(
        "places autocomplete (legacy) REQUEST_DENIED -- referer 403 blocked",
        null,
      ),
    ),
    null,
  );
});
