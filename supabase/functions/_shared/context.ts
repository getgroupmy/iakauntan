/**
 * Request context shared by every MyInvois action: resolves the caller,
 * checks their membership of the target organization, and hands back
 * both a user-scoped client (RLS applies) and a service-role client
 * (for credentials the client must never see).
 */
import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { MyInvoisEnv } from "./myinvois.ts";

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

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

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
  const { data } = await ctx.admin
    .from("einvoice_credentials")
    .select("client_id, client_secret, environment")
    .eq("org_id", ctx.orgId)
    .maybeSingle();

  if (!data) {
    throw new HttpError(
      400,
      "MyInvois credentials are not configured. Add them under Settings > e-Invoice.",
    );
  }

  return {
    clientId: data.client_id,
    clientSecret: data.client_secret,
    environment: data.environment as MyInvoisEnv,
  };
}

/** Persists the API call trail LHDN expects to be retained for 7 years. */
export async function persistLogs(
  ctx: Ctx,
  calls: Array<Record<string, unknown>>,
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
