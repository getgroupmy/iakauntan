/**
 * Request context shared by every MyInvois action: resolves the caller,
 * checks their membership of the target organization, and hands back
 * both a user-scoped client (RLS applies) and a service-role client
 * (for credentials the client must never see).
 */
import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2.117.0";
import { requireEnv } from "./env.ts";
import { ApiCall, MyInvoisEnv } from "./myinvois.ts";
import { SigningMaterial } from "./xades.ts";

export interface Ctx {
  userClient: SupabaseClient;
  admin: SupabaseClient;
  userId: string;
  orgId: string;
  role: string;
  body: Record<string, unknown>;
}

export class HttpError extends Error {
  constructor(readonly status: number, message: string, readonly details?: unknown) {
    super(message);
  }
}

const POSTING_ROLES = ["owner", "admin", "accountant"];

export async function buildContext(req: Request): Promise<Ctx> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) throw new HttpError(401, "Missing Authorization header");

  const url = requireEnv("SUPABASE_URL");
  const anonKey = requireEnv("SUPABASE_ANON_KEY");
  const serviceKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");

  const userClient = createClient(url, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const admin = createClient(url, serviceKey);

  const { data: userData } = await userClient.auth.getUser();
  if (!userData?.user) throw new HttpError(401, "Not authenticated");

  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  const orgId = body.org_id as string | undefined;
  if (!orgId) throw new HttpError(400, "org_id is required");

  // Read membership through the caller's own client so a forged org_id
  // cannot get past RLS.
  const { data: membership } = await userClient
    .from("org_members")
    .select("role, status")
    .eq("org_id", orgId)
    .eq("user_id", userData.user.id)
    .maybeSingle();

  if (!membership || membership.status !== "active") {
    throw new HttpError(403, "Not a member of this organization");
  }

  return {
    userClient,
    admin,
    userId: userData.user.id,
    orgId,
    role: membership.role,
    body,
  };
}

export function requirePostingRole(ctx: Ctx, action: string): void {
  if (!POSTING_ROLES.includes(ctx.role)) {
    throw new HttpError(403, `Your role (${ctx.role}) cannot ${action}`);
  }
}

export interface Credentials {
  clientId: string;
  clientSecret: string;
  environment: MyInvoisEnv;
}

export async function loadCredentials(ctx: Ctx): Promise<Credentials> {
  // Which environment is in force is the organization's setting, not a
  // property of the credentials. Since 0107 an organization holds both
  // sandbox and production at once — so this has to say which one it
  // wants. Selecting on `org_id` alone, as this did, would now match two
  // rows and `maybeSingle()` would throw on the second one somebody
  // configured.
  const { data: org } = await ctx.admin
    .from("organizations")
    .select("einvoice_environment")
    .eq("id", ctx.orgId)
    .maybeSingle();

  const environment = (org?.einvoice_environment ?? "sandbox") as MyInvoisEnv;

  const { data } = await ctx.admin
    .from("einvoice_credentials")
    .select("client_id, client_secret, environment")
    .eq("org_id", ctx.orgId)
    .eq("environment", environment)
    .maybeSingle();

  if (!data) {
    throw new HttpError(
      400,
      `MyInvois ${environment} credentials are not configured. Add them ` +
        "under Settings > e-Invoice.",
    );
  }

  return {
    clientId: data.client_id,
    clientSecret: data.client_secret,
    environment: data.environment as MyInvoisEnv,
  };
}

/**
 * The certificate an organization signs its 1.1 documents with, or null.
 *
 * Read with the service role and never returned to a caller. The
 * private key is in `einvoice_credentials`, a table with RLS and no
 * policies and no grants at all -- so this is the only code in the
 * product that can see it, and nothing it returns leaves the function.
 *
 * Null rather than an error when there is no certificate. A company on
 * version 1.0 is a company that does not need one, and `submit` decides
 * what to do about a 1.1 document without one -- which is a refusal
 * naming the setup step, not a stack trace here.
 */
export async function loadSigningMaterial(
  ctx: Ctx,
  environment: MyInvoisEnv,
): Promise<SigningMaterial | null> {
  const { data } = await ctx.admin
    .from("einvoice_credentials")
    .select("cert_pem, cert_private_key_pem")
    .eq("org_id", ctx.orgId)
    .eq("environment", environment)
    .maybeSingle();

  // Both or neither. A certificate without its key cannot sign, and a
  // key without its certificate has nothing to put in the document --
  // either alone is a half-finished setup rather than a usable one.
  if (!data?.cert_pem || !data?.cert_private_key_pem) return null;
  return {
    certificatePem: data.cert_pem,
    privateKeyPem: data.cert_private_key_pem,
  };
}

/** Persists the API call trail LHDN expects to be retained for 7 years. */
export async function persistLogs(
  ctx: Ctx,
  // `ApiCall[]`, which is what every caller actually passes.
  // `Record<string, unknown>[]` looked more permissive and was in fact
  // narrower: an interface without an index signature does not satisfy
  // it, so all four MyInvois actions were type errors nothing was
  // checking. Naming the real type fixes them and documents the
  // contract.
  calls: ApiCall[],
  extra: { submissionId?: string; einvoiceId?: string } = {},
): Promise<void> {
  if (calls.length === 0) return;
  await ctx.admin.from("einvoice_logs").insert(
    calls.map((c) => ({
      org_id: ctx.orgId,
      submission_id: extra.submissionId ?? null,
      einvoice_id: extra.einvoiceId ?? null,
      operation: c.operation,
      endpoint: c.endpoint,
      http_method: c.method,
      http_status: c.status,
      request_body: c.requestBody ?? null,
      response_body: c.responseBody ?? null,
      duration_ms: c.durationMs,
      error_message: c.error ?? null,
    })),
  );
}
