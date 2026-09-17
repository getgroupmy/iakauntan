// ssm-search-client.ts — complete client for the SSM Search API (CIDP) v1.0.1.
// Runtime: Deno (Supabase Edge Functions). No dependencies beyond fetch.
// Types come from ./ssm-search-api.types.ts (generated from the OpenAPI spec).
//
// Every one of the 13 documented endpoints has a method on SsmSearchClient:
//   searchEntity            POST /get-search-entity
//   businessProfile         POST /get-bizprofile-document
//   companyProfile          POST /get-company-profile-document
//   directorsOfficers       POST /get-company-roc-business-officers
//   shareCapital            POST /get-company-sharecapital-particular
//   shareholders            POST /get-company-shareholder-particular
//   registeredAddressChanges POST /get-company-roc-changes-registered-address
//   companySecretary        POST /get-company-cosec-particular
//   companyCharges          POST /get-company-charges
//   auditFirmProfile        POST /get-auditfirm-particular
//   llpCurrentProfile       POST /get-llp-current-profile
//   imageView               POST /get-image-view
//   image                   POST /get-image
// plus helpers: call() (generic), searchAll() (follows nextPage), profileFor() (dispatch by
// entityType), normalizeSearchResults() (→ name / newRegNo / oldRegNo / entityType).

import type {
  SsmEndpointMap,
  SsmEntityType,
  SsmGatewayError,
  SsmRouteError,
  GetSearchEntityRequest,
  GetBizprofileDocumentRequest,
  GetCompanyProfileDocumentRequest,
  GetCompanyRocBusinessOfficersRequest,
  GetCompanySharecapitalParticularRequest,
  GetCompanyShareholderParticularRequest,
  GetCompanyRocChangesRegisteredAddressRequest,
  GetCompanyCosecParticularRequest,
  GetCompanyChargesRequest,
  GetAuditfirmParticularRequest,
  GetLlpCurrentProfileRequest,
  GetImageViewRequest,
  GetImageRequest,
  getSearchEntity,
  getBizProfile,
  getCompProfile,
  getRocBusinessOfficers,
  getDetailsOfShareCapital,
  getDetailsOfShareholders,
  getRocChangesRegisteredAddress,
  getParticularsOfCosec,
  getInfoCharges,
  getParticularsOfAdtFirm,
  getLlpCurrentProfile,
  getImageView,
  getImage,
} from "./ssm-search-api.types.ts";

export { SSM_DEV_BASE_URL, SSM_PROD_BASE_URL } from "./ssm-search-api.types.ts";

// ---------------------------------------------------------------------------
// Endpoint table (path → key of the single-key 200 wrapper). Verbatim from the spec.
// ---------------------------------------------------------------------------
export type SsmPath = keyof SsmEndpointMap;

export const SSM_WRAPPER_KEY = {
  "/get-search-entity": "getSearchEntity",
  "/get-bizprofile-document": "getBizProfile",
  "/get-company-profile-document": "getCompProfile",
  "/get-company-roc-business-officers": "getRocBusinessOfficers",
  "/get-company-sharecapital-particular": "getDetailsOfShareCapital",
  "/get-company-shareholder-particular": "getDetailsOfShareholders",
  "/get-company-roc-changes-registered-address": "getRocChangesRegisteredAddress",
  "/get-company-cosec-particular": "getParticularsOfCosec",
  "/get-company-charges": "getInfoCharges",
  "/get-auditfirm-particular": "getParticularsOfAdtFirm",
  "/get-llp-current-profile": "getLlpCurrentProfile",
  "/get-image-view": "getImageView",
  "/get-image": "getImage",
} as const satisfies Record<SsmPath, string>;

export const SSM_PATHS = Object.keys(SSM_WRAPPER_KEY) as SsmPath[];

/** Unwrapped payload type for a path, e.g. Payload<"/get-search-entity"> = getSearchEntity. */
export type SsmPayload<P extends SsmPath> = NonNullable<
  Omit<SsmEndpointMap[P]["response"], "message">[keyof Omit<SsmEndpointMap[P]["response"], "message">]
>;

/** Fields shared by every response payload (see handoff §4.2). */
export interface SsmEnvelope {
  clientRefNo?: string;
  requestRefNo?: string;
  errorMsg?: string;
  infoId?: string;
  successCode?: string;
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------
export type SsmErrorKind =
  | "auth" // 401 from the gateway (missing/invalid key or secret)
  | "http" // any other non-2xx
  | "route" // 404 {message, error, statusCode}
  | "payload" // 200 but no wrapper key / bare {message}
  | "upstream" // 200 with non-empty errorMsg inside the payload
  | "network" // fetch threw / timeout
  | "parse"; // body was not JSON

export class SsmApiError extends Error {
  readonly kind: SsmErrorKind;
  readonly status: number | null;
  readonly path: string;
  readonly clientRefNo: string | null;
  /** Gateway error_code, or successCode from the payload, when present. */
  readonly code: string | number | null;
  readonly body: unknown;
  constructor(init: {
    kind: SsmErrorKind;
    message: string;
    status?: number | null;
    path: string;
    clientRefNo?: string | null;
    code?: string | number | null;
    body?: unknown;
    cause?: unknown;
  }) {
    super(init.message, init.cause !== undefined ? { cause: init.cause } : undefined);
    this.name = "SsmApiError";
    this.kind = init.kind;
    this.status = init.status ?? null;
    this.path = init.path;
    this.clientRefNo = init.clientRefNo ?? null;
    this.code = init.code ?? null;
    this.body = init.body;
  }
  /** Safe to show to an end user / log without leaking headers. */
  toJSON() {
    return { name: this.name, kind: this.kind, status: this.status, path: this.path, code: this.code, message: this.message, clientRefNo: this.clientRefNo };
  }
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------
export interface SsmSearchClientOptions {
  apiKey: string;
  apiSecret: string;
  /** Defaults to the free development host. Use SSM_PROD_BASE_URL in production (charged). */
  baseUrl?: string;
  /** Per-request timeout. Default 30 000 ms. */
  timeoutMs?: number;
  /** Override fetch (tests, tracing). */
  fetch?: typeof fetch;
  /** Called after every request with timing + outcome; wire this to your audit log. */
  onRequest?: (info: SsmRequestInfo) => void | Promise<void>;
  /** Prefix for auto-generated x-Client-Ref-No values (e.g. the org id). */
  clientRefPrefix?: string;
}

export interface SsmCallOptions {
  /** Explicit x-Client-Ref-No; otherwise `${clientRefPrefix}:${uuid}` is generated. */
  clientRefNo?: string;
  signal?: AbortSignal;
}

export interface SsmRequestInfo {
  path: SsmPath;
  clientRefNo: string;
  requestRefNo: string | null;
  status: number | null;
  ok: boolean;
  errorKind: SsmErrorKind | null;
  durationMs: number;
  baseUrl: string;
}

/** Normalised search hit — the four fields iAkauntan stores. */
export interface SsmSearchHit {
  name: string;
  newRegNo: string;
  oldRegNo: string;
  entityType: string;
}

export class SsmSearchClient {
  readonly baseUrl: string;
  private readonly apiKey: string;
  private readonly apiSecret: string;
  private readonly timeoutMs: number;
  private readonly fetchImpl: typeof fetch;
  private readonly onRequest?: SsmSearchClientOptions["onRequest"];
  private readonly clientRefPrefix: string;

  constructor(opts: SsmSearchClientOptions) {
    if (!opts.apiKey || !opts.apiSecret) throw new Error("SsmSearchClient: apiKey and apiSecret are required");
    this.apiKey = opts.apiKey;
    this.apiSecret = opts.apiSecret;
    this.baseUrl = (opts.baseUrl ?? "https://cidp.ssmsearch.com/").replace(/\/?$/, "/");
    this.timeoutMs = opts.timeoutMs ?? 30_000;
    this.fetchImpl = opts.fetch ?? fetch;
    this.onRequest = opts.onRequest;
    this.clientRefPrefix = opts.clientRefPrefix ?? "iak";
  }

  /** Build a client from Deno env: SSMSEARCH_API_KEY, SSMSEARCH_API_SECRET, SSMSEARCH_API_BASE_URL. */
  static fromEnv(env: { get(name: string): string | undefined }, extra: Partial<SsmSearchClientOptions> = {}): SsmSearchClient {
    return new SsmSearchClient({
      apiKey: env.get("SSMSEARCH_API_KEY") ?? "",
      apiSecret: env.get("SSMSEARCH_API_SECRET") ?? "",
      baseUrl: env.get("SSMSEARCH_API_BASE_URL") ?? undefined,
      ...extra,
    });
  }

  // ---- the 13 endpoints ---------------------------------------------------

  /** 1. Search Entity — name / regNo / entityType / page. Returns one page. */
  searchEntity(body: GetSearchEntityRequest, opts?: SsmCallOptions): Promise<getSearchEntity> {
    return this.call("/get-search-entity", body, opts);
  }

  /** 2. Business Profile (ROB — sole proprietorship / partnership). */
  businessProfile(body: GetBizprofileDocumentRequest, opts?: SsmCallOptions): Promise<getBizProfile> {
    return this.call("/get-bizprofile-document", body, opts);
  }

  /** 3. Company Profile (ROC — Sdn Bhd / Bhd): company info, addresses, officers, shares, charges, financials. */
  companyProfile(body: GetCompanyProfileDocumentRequest, opts?: SsmCallOptions): Promise<getCompProfile> {
    return this.call("/get-company-profile-document", body, opts);
  }

  /** 4. Particulars of Directors/Officers (current + changes). */
  directorsOfficers(body: GetCompanyRocBusinessOfficersRequest, opts?: SsmCallOptions): Promise<getRocBusinessOfficers> {
    return this.call("/get-company-roc-business-officers", body, opts);
  }

  /** 5. Particular of Share Capital (summary + allotments). */
  shareCapital(body: GetCompanySharecapitalParticularRequest, opts?: SsmCallOptions): Promise<getDetailsOfShareCapital> {
    return this.call("/get-company-sharecapital-particular", body, opts);
  }

  /** 6. Particular of Shareholders (current list + changes). */
  shareholders(body: GetCompanyShareholderParticularRequest, opts?: SsmCallOptions): Promise<getDetailsOfShareholders> {
    return this.call("/get-company-shareholder-particular", body, opts);
  }

  /** 7. Particulars of Registered Address (current + history of changes). */
  registeredAddressChanges(body: GetCompanyRocChangesRegisteredAddressRequest, opts?: SsmCallOptions): Promise<getRocChangesRegisteredAddress> {
    return this.call("/get-company-roc-changes-registered-address", body, opts);
  }

  /** 8. Particular of Company Secretary. */
  companySecretary(body: GetCompanyCosecParticularRequest, opts?: SsmCallOptions): Promise<getParticularsOfCosec> {
    return this.call("/get-company-cosec-particular", body, opts);
  }

  /** 9. Company Charges (Form 40 etc.). */
  companyCharges(body: GetCompanyChargesRequest, opts?: SsmCallOptions): Promise<getInfoCharges> {
    return this.call("/get-company-charges", body, opts);
  }

  /** 10. Audit Firm Profile — body key is adtFirmNo (e.g. AF0301). */
  auditFirmProfile(body: GetAuditfirmParticularRequest, opts?: SsmCallOptions): Promise<getParticularsOfAdtFirm> {
    return this.call("/get-auditfirm-particular", body, opts);
  }

  /** 11. LLP Current Profile — body key is entityNoOldFormat (OLD format, e.g. LLP0012345-LGN). */
  llpCurrentProfile(body: GetLlpCurrentProfileRequest, opts?: SsmCallOptions): Promise<getLlpCurrentProfile> {
    return this.call("/get-llp-current-profile", body, opts);
  }

  /** 12. Image View — list of lodged documents (formType, documentDate, totalPage, verId). */
  imageView(body: GetImageViewRequest, opts?: SsmCallOptions): Promise<getImageView> {
    return this.call("/get-image-view", body, opts);
  }

  /** 13. Image — scanned document contents for one verId (docContent: string). */
  image(body: GetImageRequest, opts?: SsmCallOptions): Promise<getImage> {
    return this.call("/get-image", body, opts);
  }

  // ---- helpers --------------------------------------------------------------

  /**
   * Follow `searchEntity.nextPage` until exhausted or `maxPages` reached.
   * Each page is a paid call in production — keep maxPages small in UI code.
   */
  async searchAll(
    body: Omit<GetSearchEntityRequest, "page">,
    { maxPages = 3, ...opts }: SsmCallOptions & { maxPages?: number } = {},
  ): Promise<{ hits: SsmSearchHit[]; pagesFetched: number; exhausted: boolean; raw: getSearchEntity[] }> {
    const raw: getSearchEntity[] = [];
    const hits: SsmSearchHit[] = [];
    let page = "1";
    let exhausted = false;
    for (let i = 0; i < maxPages; i++) {
      const res = await this.searchEntity({ ...body, page }, opts);
      raw.push(res);
      hits.push(...normalizeSearchResults(res));
      const next = (res.searchEntity?.nextPage ?? "").trim();
      const current = (res.searchEntity?.currentPage ?? page).trim();
      if (!next || next === current || next === "0" || !(res.searchEntity?.data?.length)) {
        exhausted = true;
        break;
      }
      page = next;
    }
    return { hits, pagesFetched: raw.length, exhausted, raw };
  }

  /**
   * Fetch the right "profile" document for an entity type, using the ids captured from search.
   * company → companyProfile(regNo); business → businessProfile(regNo);
   * limited_liability_partnerships → llpCurrentProfile(entityNoOldFormat = oldRegNo);
   * audit_firm → auditFirmProfile(adtFirmNo = newRegNo || oldRegNo).
   */
  profileFor(
    entityType: SsmEntityType | string,
    ids: { newRegNo?: string; oldRegNo?: string },
    opts?: SsmCallOptions,
  ): Promise<getCompProfile | getBizProfile | getLlpCurrentProfile | getParticularsOfAdtFirm> {
    const kind = normalizeEntityType(entityType);
    const regNo = ids.newRegNo || ids.oldRegNo || "";
    switch (kind) {
      case "company":
        return this.companyProfile({ regNo }, opts);
      case "business":
        return this.businessProfile({ regNo }, opts);
      case "limited_liability_partnerships": {
        const old = ids.oldRegNo || ids.newRegNo || "";
        return this.llpCurrentProfile({ entityNoOldFormat: old }, opts);
      }
      case "audit_firm":
        return this.auditFirmProfile({ adtFirmNo: regNo }, opts);
      default:
        return Promise.reject(new SsmApiError({ kind: "payload", path: "/get-search-entity", message: `Unknown entityType "${entityType}"` }));
    }
  }

  /** Generic typed call — every endpoint method above goes through here. */
  async call<P extends SsmPath>(path: P, body: SsmEndpointMap[P]["request"], opts: SsmCallOptions = {}): Promise<SsmPayload<P>> {
    const clientRefNo = opts.clientRefNo ?? `${this.clientRefPrefix}:${crypto.randomUUID()}`;
    const url = new URL(path.replace(/^\//, ""), this.baseUrl);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(new Error(`SSM request timed out after ${this.timeoutMs} ms`)), this.timeoutMs);
    if (opts.signal) opts.signal.addEventListener("abort", () => controller.abort(opts.signal?.reason), { once: true });

    const started = Date.now();
    let status: number | null = null;
    let requestRefNo: string | null = null;
    let errorKind: SsmErrorKind | null = null;
    const finish = async () => {
      clearTimeout(timer);
      if (this.onRequest) {
        try {
          await this.onRequest({ path, clientRefNo, requestRefNo, status, ok: errorKind === null, errorKind, durationMs: Date.now() - started, baseUrl: this.baseUrl });
        } catch { /* logging must never break the call */ }
      }
    };

    let res: Response;
    try {
      res = await this.fetchImpl(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "x-Gateway-APIKey": this.apiKey,
          "x-Gateway-APISecret": this.apiSecret,
          "x-Client-Ref-No": clientRefNo,
        },
        body: JSON.stringify(stripUndefined(body ?? {})),
        signal: controller.signal,
      });
    } catch (cause) {
      errorKind = "network";
      await finish();
      throw new SsmApiError({ kind: "network", path, clientRefNo, message: `SSM ${path}: ${(cause as Error)?.message ?? "network error"}`, cause });
    }

    status = res.status;
    const text = await res.text();
    let json: unknown;
    try {
      json = text ? JSON.parse(text) : {};
    } catch (cause) {
      errorKind = "parse";
      await finish();
      throw new SsmApiError({ kind: "parse", path, status, clientRefNo, message: `SSM ${path}: non-JSON response (HTTP ${status})`, body: text.slice(0, 500), cause });
    }

    if (!res.ok) {
      const g = json as Partial<SsmGatewayError> & Partial<SsmRouteError>;
      const msg = g.error ?? g.message ?? `HTTP ${status}`;
      errorKind = status === 401 ? "auth" : status === 404 && typeof g.statusCode === "number" ? "route" : "http";
      await finish();
      throw new SsmApiError({ kind: errorKind, path, status, clientRefNo, code: g.error_code ?? g.statusCode ?? null, message: `SSM ${path}: ${msg}`, body: json });
    }

    const key = SSM_WRAPPER_KEY[path];
    const wrapper = (json as Record<string, unknown>)[key] as (SsmPayload<P> & SsmEnvelope) | undefined;
    if (!wrapper || typeof wrapper !== "object") {
      const bare = json as { message?: string };
      errorKind = "payload";
      await finish();
      throw new SsmApiError({ kind: "payload", path, status, clientRefNo, message: `SSM ${path}: ${bare?.message ?? `response has no "${key}" key`}`, body: json });
    }
    requestRefNo = wrapper.requestRefNo ?? null;
    if (wrapper.errorMsg && wrapper.errorMsg.trim() !== "") {
      errorKind = "upstream";
      await finish();
      throw new SsmApiError({ kind: "upstream", path, status, clientRefNo, code: wrapper.successCode ?? null, message: `SSM ${path}: ${wrapper.errorMsg}`, body: json });
    }
    await finish();
    return wrapper as SsmPayload<P>;
  }
}

// ---------------------------------------------------------------------------
// Pure helpers (exported for tests / the edge function)
// ---------------------------------------------------------------------------

/** Map a search response to the four fields iAkauntan persists. Empty strings, never undefined. */
export function normalizeSearchResults(res: getSearchEntity): SsmSearchHit[] {
  return (res.searchEntity?.data ?? []).map((d) => ({
    name: (d.companyName ?? "").trim(),
    newRegNo: (d.companyNo ?? "").trim(),
    oldRegNo: (d.oldCompanyNo ?? "").trim(),
    entityType: (d.entityType ?? "").trim(),
  }));
}

/** Accepts the documented request values plus common synonyms; returns the canonical request value. */
export function normalizeEntityType(v: string): "company" | "business" | "limited_liability_partnerships" | "audit_firm" | "unknown" {
  const s = v.trim().toLowerCase().replace(/[\s-]+/g, "_");
  if (["company", "roc", "sdn_bhd", "sdn._bhd.", "bhd", "berhad", "corporation"].includes(s)) return "company";
  if (["business", "rob", "sole_proprietor", "sole_proprietorship", "partnership", "enterprise", "trading"].includes(s)) return "business";
  if (["limited_liability_partnerships", "limited_liability_partnership", "llp", "plt"].includes(s)) return "limited_liability_partnerships";
  if (["audit_firm", "auditfirm", "audit", "af"].includes(s)) return "audit_firm";
  return "unknown";
}

/** Loose validators for the ids you will send (do not reject on failure — SSM is the authority). */
export const looksLike = {
  /** New 12-digit format: yyyy + 2-digit entity code + 6-digit sequence, e.g. 199301012345. */
  newRegNo: (s: string) => /^\d{12}$/.test(s.trim()),
  /** Old ROC format 123456-X, old ROB 001234567-A / SA0123456-M, LLP LLP0012345-LGN, audit AF0123. */
  oldRegNo: (s: string) => /^[A-Z]{0,3}\d{4,9}(-[A-Z]{1,3})?$/i.test(s.trim()),
  llpOldFormat: (s: string) => /^LLP\d{7}-[A-Z]{3}$/i.test(s.trim()),
  auditFirmNo: (s: string) => /^AF\d{3,6}$/i.test(s.trim()),
};

function stripUndefined<T extends object>(o: T): T {
  return Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined)) as T;
}
