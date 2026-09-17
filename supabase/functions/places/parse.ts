// Two Google APIs, two shapes, one screen.
//
// Places API (New) and the legacy Places API answer the same questions
// in different words: `longText` against `long_name`, `suggestions`
// against `predictions`, an HTTP status against a `status` string in a
// 200 body. Mixing them up does not throw — it yields an empty address
// behind a suggestion somebody just picked, which looks like Google
// having no data rather than us reading the wrong field.
//
// So the reading lives here, apart from the fetching, where a test can
// hold a real response of each shape against it.

/// One suggestion, as the screen wants it: a line to show in bold and a
/// line under it. Google's own split, not one we compute.
export interface Suggestion {
  id: string;
  line: string;
  detail: string;
}

/// The pieces a form has boxes for.
///
/// A `null` is a component Google did not return, which is common and
/// not an error — plenty of real addresses have no postcode.
export interface Address {
  line1: string | null;
  city: string | null;
  postcode: string | null;
  state: string | null;
  country: string | null;
  formatted: string | null;
}

/// Whether a refusal from the new API is worth asking the old one.
///
/// Only for "this key may not use this API": 403 is the permission
/// refusal, 404 is the API not being enabled on the project at all, and
/// 429 is its quota rather than the account's. A 400 is a request we
/// built wrong, and sending the same wrong question to a second API
/// buys a second identical refusal and one more billed call.
export function worthFallingBack(status: number): boolean {
  return status === 403 || status === 404 || status === 429;
}

/// A refusal from Google, carrying the status that decides what next.
///
/// The status is a field rather than something read back out of the
/// message. The first version of this parsed it out of the string with
/// a regular expression, which works until a message happens to
/// contain a number — and the thing it decides is whether to spend a
/// second billed call on a second API, so it should not depend on how
/// a sentence is worded.
export class PlacesRefusal extends Error {
  constructor(message: string, readonly status: number | null) {
    super(message);
    this.name = "PlacesRefusal";
  }
}

/// The status a refusal carried, or null for anything that is not one.
///
/// Null for a `TypeError` from a dropped connection: a network blip is
/// not a permission problem, and retrying it against a second API turns
/// one failed call into two.
export function statusOf(e: unknown): number | null {
  return e instanceof PlacesRefusal ? e.status : null;
}

/// The legacy API answers 200 and puts the refusal in the body.
///
/// This is the trap in the whole file. `REQUEST_DENIED` arrives with an
/// HTTP 200, so code that checks `res.ok` and moves on reads a denial as
/// an empty result and shows "no such street" for a key problem.
/// `ZERO_RESULTS` is the one status that really does mean no matches.
export function legacyRefused(status: string | undefined): boolean {
  return status !== undefined && status !== "OK" && status !== "ZERO_RESULTS";
}

function text(v: unknown): string {
  return typeof v === "string" ? v : "";
}

/// Suggestions from Places API (New).
export function suggestionsFromNew(
  data: Record<string, unknown>,
): Suggestion[] {
  const raw = (data.suggestions ?? []) as Array<Record<string, unknown>>;
  const out: Suggestion[] = [];
  for (const s of raw) {
    const p = s.placePrediction as Record<string, unknown> | undefined;
    if (!p) continue;
    const f = (p.structuredFormat ?? {}) as Record<string, unknown>;
    const main = (f.mainText ?? {}) as Record<string, unknown>;
    const secondary = (f.secondaryText ?? {}) as Record<string, unknown>;
    out.push({
      id: text(p.placeId),
      line: text(main.text),
      detail: text(secondary.text),
    });
  }
  return out.filter((s) => s.id.length > 0);
}

/// Suggestions from the legacy Places API.
///
/// `predictions` rather than `suggestions`, `place_id` rather than
/// `placeId`, and `structured_formatting` with `main_text` under it. A
/// prediction without the structured split falls back to `description`,
/// which is the whole address on one line — worse than the split and
/// far better than a blank row.
export function suggestionsFromLegacy(
  data: Record<string, unknown>,
): Suggestion[] {
  const raw = (data.predictions ?? []) as Array<Record<string, unknown>>;
  const out: Suggestion[] = [];
  for (const p of raw) {
    const f = (p.structured_formatting ?? {}) as Record<string, unknown>;
    const main = text(f.main_text);
    out.push({
      id: text(p.place_id),
      line: main.length > 0 ? main : text(p.description),
      detail: text(f.secondary_text),
    });
  }
  return out.filter((s) => s.id.length > 0 && s.line.length > 0);
}

function pick(
  components: Array<Record<string, unknown>>,
  type: string,
  long: string,
  short: string,
): string | null {
  for (const c of components) {
    const types = (c.types ?? []) as string[];
    if (Array.isArray(types) && types.includes(type)) {
      const v = c[long] ?? c[short];
      return typeof v === "string" ? v : null;
    }
  }
  return null;
}

function assemble(
  components: Array<Record<string, unknown>>,
  formatted: unknown,
  long: string,
  short: string,
): Address {
  const at = (type: string) => pick(components, type, long, short);

  const number = at("street_number");
  const route = at("route");

  return {
    // The street address: a number and a road, which are two components
    // and one box.
    line1: [number, route].filter((p) => p).join(" ") || null,
    // `locality` is the town or city; `postal_town` is what the UK and
    // a few others use instead, and an address with neither falls back
    // to the administrative area below it rather than to nothing.
    city: at("locality") ?? at("postal_town") ??
      at("administrative_area_level_2"),
    postcode: at("postal_code"),
    state: at("administrative_area_level_1"),
    country: at("country"),
    formatted: typeof formatted === "string" ? formatted : null,
  };
}

/// An address from Places API (New): `addressComponents`, `longText`.
export function addressFromNew(place: Record<string, unknown>): Address {
  return assemble(
    (place.addressComponents ?? []) as Array<Record<string, unknown>>,
    place.formattedAddress,
    "longText",
    "shortText",
  );
}

/// An address from the legacy Places API: `address_components`,
/// `long_name`, and the whole thing wrapped in `result`.
export function addressFromLegacy(data: Record<string, unknown>): Address {
  const result = (data.result ?? {}) as Record<string, unknown>;
  return assemble(
    (result.address_components ?? []) as Array<Record<string, unknown>>,
    result.formatted_address,
    "long_name",
    "short_name",
  );
}
