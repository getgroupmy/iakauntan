/**
 * The official SSM Search API, behind the same two methods the interim
 * web provider offers.
 *
 * `provider.ts` says what this had to be: "a second class implementing
 * the same two methods is the whole change, chosen by `SSM_PROVIDER`".
 * This is that class. `search()` and `testLogin()` are the contract;
 * nothing above this file knows which one it is talking to.
 *
 * The thirteen endpoints of CIDP v1.0.1 live on `SsmSearchClient` in
 * `_shared/ssm-search-client.ts` and are reached through the `ssm-api`
 * function. This one wraps a single endpoint — entity search — because
 * that is all the contact lookup asks for, and asking for more would
 * mean paying for more.
 *
 * ---------------------------------------------------------------------
 * Why this does not replace the web provider yet
 *
 * The subscription is under SSM's review and there is no key. Until
 * there is, `SSM_PROVIDER` defaults to `web` and this class is
 * unreachable rather than broken. The day the key arrives is a
 * dashboard secret, not a deploy.
 *
 * ---------------------------------------------------------------------
 * What it costs
 *
 * Every production call is charged against a points balance the whole
 * platform shares. The development host is free and serves fixture
 * data. That is why `testLogin` below makes the smallest call it can
 * and says so: there is no session to establish and no free way to ask
 * whether a key is good.
 */
import {
  normalizeSearchResults,
  SsmApiError,
  SsmSearchClient,
  type SsmSearchHit,
} from "../_shared/ssm-search-client.ts";
import {
  ENTITY_TYPES,
  type SearchResult,
  SsmError,
  type SsmEntity,
} from "./provider.ts";

/**
 * The id the web search uses, and the word CIDP wants.
 *
 * `ENTITY_TYPES` in `provider.ts` is the numbering ssmsearch.com uses
 * and the app's filter is built from it. CIDP names the same four
 * things in words. One map, both directions, so a filter chosen on one
 * provider means the same on the other.
 */
export const CIDP_ENTITY_TYPE: Record<number, string> = {
  1: "company",
  2: "business",
  3: "audit_firm",
  25: "limited_liability_partnerships",
};

/** The reverse, for reading a hit back into the app's own numbering. */
export const ENTITY_TYPE_ID: Record<string, number> = {
  company: 1,
  business: 2,
  audit_firm: 3,
  limited_liability_partnerships: 25,
};

/**
 * One CIDP hit, as the rest of this function already expects an entity.
 *
 * The four fields the search result must save — name, new registration
 * number, old registration number and entity type — are exactly the
 * four `normalizeSearchResults` produces, and they land on the same
 * columns `set_contact_ssm_entity` has always written. `ssm_id` and
 * `slug` are null and honestly so: they are ssmsearch.com's own handles
 * for a record and CIDP has neither.
 */
export function toSsmEntity(hit: SsmSearchHit): SsmEntity {
  const canonical = hit.entityType.trim().toLowerCase().replace(
    /[\s-]+/g,
    "_",
  );
  const typeId = ENTITY_TYPE_ID[canonical] ?? null;
  return {
    ssm_id: null,
    name: hit.name,
    slug: null,
    reg_no: hit.newRegNo || null,
    reg_no_old: hit.oldRegNo || null,
    entity_type_id: typeId,
    // The register's own word where this does not recognise it. A
    // category CIDP adds should arrive as itself rather than as null.
    entity_type: typeId !== null
      ? ENTITY_TYPES[typeId]
      : (hit.entityType || null),
  };
}

/** Anything with `.from()` and `.rpc()`; the service-role client. */
// deno-lint-ignore no-explicit-any
type Db = any;

export class SsmSearchApi {
  readonly name = "ssm_api";

  constructor(
    private readonly db: Db,
    private readonly client: SsmSearchClient,
  ) {}

  /**
   * One page of matches.
   *
   * `perPage` is ignored, and cannot be honoured: CIDP decides its own
   * page size and offers no way to ask for another. What is returned is
   * what arrived, and `per_page` reports that rather than what was
   * asked for — a page claiming twenty rows and carrying eight would
   * make `hasMore` wrong in the app.
   */
  async search(
    query: string,
    typeId: number | null,
    page: number,
    _perPage: number,
  ): Promise<SearchResult> {
    const entityType = typeId === null
      ? undefined
      : CIDP_ENTITY_TYPE[typeId];

    let raw;
    try {
      raw = await this.client.searchEntity({
        // A registration number is a name to CIDP's search as much as a
        // company name is; it takes either in its own field, and the
        // app's one box carries whichever the user typed. Sent as
        // `name`, because `regNo` is matched exactly and a partial
        // number would find nothing at all.
        name: query,
        entityType,
        page: String(page),
      });
    } catch (e) {
      throw asSsmError(e, this.db);
    }

    const hits = normalizeSearchResults(raw);
    const items = hits.map(toSsmEntity);
    const next = (raw.searchEntity?.nextPage ?? "").trim();
    const current = (raw.searchEntity?.currentPage ?? String(page)).trim();
    const more = next !== "" && next !== current && next !== "0" &&
      items.length > 0;

    // CIDP does not say how many matches there are, only whether there
    // is another page. `total` exists so `hasMore` — which the app
    // computes as `page * per_page < total` — can be answered, and the
    // one extra says "at least one more" rather than claiming a count
    // this does not have.
    const perPage = items.length;
    return {
      items,
      total: more ? page * perPage + 1 : (page - 1) * perPage + items.length,
      page,
      per_page: perPage,
    };
  }

  /**
   * Whether the key works, for the admin page's Test login.
   *
   * There is no session and no free way to ask. This makes ONE search,
   * which is a charged call in production, and the operator pressed a
   * button labelled Test — the alternative is finding out when a user's
   * search fails, which `0589` built this button to avoid.
   *
   * `logged_in_as` is the host rather than a person: a key-based API
   * has no user to name, and inventing one would be the screen
   * asserting something it was never told.
   */
  async testLogin(): Promise<{ logged_in_as: string | null }> {
    try {
      await this.client.searchEntity({ name: "BERHAD", page: "1" });
    } catch (e) {
      // An upstream complaint about the query is the key WORKING. Only
      // a refusal of the credential is a failed test.
      if (e instanceof SsmApiError && e.kind !== "auth") {
        return { logged_in_as: `api:${hostOf(this.client.baseUrl)}` };
      }
      throw asSsmError(e, this.db);
    }
    return { logged_in_as: `api:${hostOf(this.client.baseUrl)}` };
  }
}

function hostOf(url: string): string {
  try {
    return new URL(url).host;
  } catch {
    return url;
  }
}

/**
 * A CIDP failure in the words this function already speaks.
 *
 * The codes are the ones `ssm_repository.dart` already switches on, so
 * a failure under the new provider reads to a user exactly as the same
 * failure under the old one did. A 401 is OUR key and never the
 * caller's, so it becomes `SSM_LOGIN_FAILED` — the message an operator
 * can act on — rather than anything that would send somebody to the
 * sign-in screen.
 */
export function asSsmError(e: unknown, db?: Db): SsmError {
  if (!(e instanceof SsmApiError)) {
    return new SsmError(
      "INTERNAL",
      e instanceof Error ? e.message : "The lookup failed.",
      500,
    );
  }
  if (db) noteError(db, `${e.kind}: ${e.message}`);
  switch (e.kind) {
    case "auth":
      return new SsmError(
        "SSM_LOGIN_FAILED",
        "SSM's Search API refused our key. A platform administrator can " +
          "check SSMSEARCH_API_KEY and SSMSEARCH_API_SECRET.",
        502,
      );
    case "network":
      return new SsmError(
        "SSM_UNREACHABLE",
        "SSM's Search API is not answering. Try again shortly.",
        504,
      );
    case "route":
      return new SsmError(
        "SSM_UNREACHABLE",
        "SSM's Search API answered from an address that is not a route. " +
          "Check SSMSEARCH_API_BASE_URL.",
        502,
      );
    default:
      return new SsmError("SSM_SEARCH_FAILED", e.message, 502);
  }
}

/**
 * The same row the web provider writes its failures to, so the admin
 * page shows the last error whichever provider produced it. Fire and
 * forget: a log that will not write is not a reason to lose the error
 * the caller is about to be told about.
 */
function noteError(db: Db, message: string): void {
  try {
    db.from("ssm_session").update({
      last_error: message.slice(0, 500),
      last_error_at: new Date().toISOString(),
    }).eq("id", 1).then(() => {}, () => {});
  } catch { /* never let logging break the call */ }
}

/**
 * The client, or a refusal that says the secrets are not set.
 *
 * `SSM_NOT_CONFIGURED` and not a failure: until SSM approves the
 * subscription there is no key, and "try again" about a thing nobody
 * can try again is worse than saying who to ask.
 */
export function apiClientFromEnv(
  onRequest?: (info: { path: string }) => void,
): SsmSearchClient {
  const key = Deno.env.get("SSMSEARCH_API_KEY");
  const secret = Deno.env.get("SSMSEARCH_API_SECRET");
  if (!key || !secret) {
    throw new SsmError(
      "SSM_NOT_CONFIGURED",
      "The official SSM lookup is not set up yet. A platform " +
        "administrator sets SSMSEARCH_API_KEY and SSMSEARCH_API_SECRET.",
      503,
    );
  }
  return SsmSearchClient.fromEnv(Deno.env, onRequest ? { onRequest } : {});
}

/**
 * Which provider is switched on.
 *
 * `web` until SSM approves the key, and `web` for anything unrecognised
 * — a typo in a dashboard secret must not switch a working lookup off.
 */
export function chosenProvider(
  value: string | undefined,
): "web" | "api" {
  return value?.trim().toLowerCase() === "api" ? "api" : "web";
}
