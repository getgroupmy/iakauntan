/**
 * Thin client for the LHDN MyInvois API.
 *
 * Endpoints and payload shapes follow the LHDN SDK published at
 * https://sdk.myinvois.hasil.gov.my. Access tokens are cached in memory
 * for the life of the edge function instance because MyInvois rate
 * limits the identity service hard.
 */

export type MyInvoisEnv = "sandbox" | "production";

const HOSTS: Record<MyInvoisEnv, { identity: string; api: string }> = {
  sandbox: {
    identity: "https://preprod-api.myinvois.hasil.gov.my/connect/token",
    api: "https://preprod-api.myinvois.hasil.gov.my/api/v1.0",
  },
  production: {
    identity: "https://api.myinvois.hasil.gov.my/connect/token",
    api: "https://api.myinvois.hasil.gov.my/api/v1.0",
  },
};

interface CachedToken {
  token: string;
  expiresAt: number;
}

const tokenCache = new Map<string, CachedToken>();

export interface MyInvoisCredentials {
  clientId: string;
  clientSecret: string;
  environment: MyInvoisEnv;
  /** Set when acting on behalf of another taxpayer (intermediary flow). */
  onBehalfOf?: string;
}

export interface ApiCall {
  operation: string;
  endpoint: string;
  method: string;
  status: number;
  requestBody?: unknown;
  responseBody?: unknown;
  durationMs: number;
  error?: string;
}

/** Every call made during a request, so the caller can persist an audit trail. */
export class CallLog {
  readonly calls: ApiCall[] = [];
  add(call: ApiCall) {
    this.calls.push(call);
  }
}

export class MyInvoisClient {
  constructor(
    private readonly creds: MyInvoisCredentials,
    private readonly log = new CallLog(),
  ) {}

  get calls(): ApiCall[] {
    return this.log.calls;
  }

  private get hosts() {
    return HOSTS[this.creds.environment];
  }

  async getToken(): Promise<string> {
    const key = `${this.creds.environment}:${this.creds.clientId}:${this.creds.onBehalfOf ?? ""}`;
    const cached = tokenCache.get(key);
    // Refresh a minute early so a token never expires mid-flight.
    if (cached && cached.expiresAt > Date.now() + 60_000) return cached.token;

    const body = new URLSearchParams({
      grant_type: "client_credentials",
      client_id: this.creds.clientId,
      client_secret: this.creds.clientSecret,
      scope: "InvoicingAPI",
    });

    const headers: Record<string, string> = {
      "Content-Type": "application/x-www-form-urlencoded",
    };
    if (this.creds.onBehalfOf) headers["onbehalfof"] = this.creds.onBehalfOf;

    const started = Date.now();
    const res = await fetch(this.hosts.identity, {
      method: "POST",
      headers,
      body,
    });
    const text = await res.text();
    const duration = Date.now() - started;

    let parsed: Record<string, unknown> = {};
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = { raw: text };
    }

    this.log.add({
      operation: "token",
      endpoint: this.hosts.identity,
      method: "POST",
      status: res.status,
      // Never log the client secret.
      requestBody: { grant_type: "client_credentials", scope: "InvoicingAPI" },
      responseBody: res.ok ? { token_type: parsed.token_type } : parsed,
      durationMs: duration,
      error: res.ok ? undefined : text.slice(0, 500),
    });

    if (!res.ok) {
      throw new Error(
        `MyInvois authentication failed (${res.status}): ${text.slice(0, 300)}`,
      );
    }

    const token = String(parsed.access_token);
    const expiresIn = Number(parsed.expires_in ?? 3600);
    tokenCache.set(key, {
      token,
      expiresAt: Date.now() + expiresIn * 1000,
    });
    return token;
  }

  private async request(
    operation: string,
    method: string,
    path: string,
    body?: unknown,
  ): Promise<{ status: number; data: unknown }> {
    const token = await this.getToken();
    const url = `${this.hosts.api}${path}`;
    const headers: Record<string, string> = {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      Accept: "application/json",
    };
    if (this.creds.onBehalfOf) headers["onbehalfof"] = this.creds.onBehalfOf;

    const started = Date.now();
    const res = await fetch(url, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    const duration = Date.now() - started;

    let data: unknown;
    try {
      data = text ? JSON.parse(text) : null;
    } catch {
      data = { raw: text };
    }

    this.log.add({
      operation,
      endpoint: url,
      method,
      status: res.status,
      requestBody: body,
      responseBody: data,
      durationMs: duration,
      error: res.ok ? undefined : text.slice(0, 500),
    });

    return { status: res.status, data };
  }

  /** POST /documentsubmissions — up to 100 documents, 5 MB per batch. */
  submitDocuments(documents: SubmissionDocument[]) {
    return this.request("submit", "POST", "/documentsubmissions", {
      documents,
    });
  }

  /** GET /documentsubmissions/{uid} — batch level status. */
  getSubmission(submissionUid: string, page = 1, pageSize = 100) {
    return this.request(
      "submission_status",
      "GET",
      `/documentsubmissions/${submissionUid}?pageNo=${page}&pageSize=${pageSize}`,
    );
  }

  /** GET /documents/{uuid}/details — per document validation results. */
  getDocumentDetails(uuid: string) {
    return this.request("status", "GET", `/documents/${uuid}/details`);
  }

  /**
   * PUT /documents/state/{uuid}/state
   * Suppliers cancel; buyers reject. Both are only allowed within 72
   * hours of validation.
   */
  setDocumentState(uuid: string, status: "cancelled" | "rejected", reason: string) {
    return this.request("cancel", "PUT", `/documents/state/${uuid}/state`, {
      status,
      reason,
    });
  }

  /** GET /taxpayer/validate/{tin} — confirms a TIN matches an identifier. */
  validateTin(tin: string, idType: string, idValue: string) {
    return this.request(
      "validate_tin",
      "GET",
      `/taxpayer/validate/${encodeURIComponent(tin)}?idType=${encodeURIComponent(idType)}&idValue=${encodeURIComponent(idValue)}`,
    );
  }
}

export interface SubmissionDocument {
  format: "JSON";
  document: string;      // base64 of the UBL JSON
  documentHash: string;  // SHA-256 hex of the raw UBL JSON
  codeNumber: string;    // our internal document number
}

/** SHA-256 as lowercase hex, which is what MyInvois expects. */
export async function sha256Hex(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/** Base64 that is safe for multi-byte characters in names and addresses. */
export function toBase64(input: string): string {
  const bytes = new TextEncoder().encode(input);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary);
}

/**
 * The validation link a buyer scans from the QR code on the printed
 * invoice. Format: <portal>/uuid-of-document/share/<longId>.
 */
export function validationLink(env: MyInvoisEnv, uuid: string, longId: string): string {
  const portal = env === "production"
    ? "https://myinvois.hasil.gov.my"
    : "https://preprod.myinvois.hasil.gov.my";
  return `${portal}/${uuid}/share/${longId}`;
}
