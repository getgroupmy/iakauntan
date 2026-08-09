/**
 * Confirms a TIN belongs to the identifier a customer gave us, so an
 * invoice is not rejected at validation time. Results are cached because
 * LHDN rate limits this endpoint hard.
 *
 * Payload: { tin, id_type: 'NRIC'|'BRN'|'PASSPORT'|'ARMY', id_value,
 *            contact_id?, force? }
 */
import { Ctx, HttpError, loadCredentials, persistLogs } from "../_shared/context.ts";
import { MyInvoisClient } from "../_shared/myinvois.ts";

const CACHE_TTL_DAYS = 30;
const ID_TYPES = ["NRIC", "BRN", "PASSPORT", "ARMY"];

export async function validateTin(ctx: Ctx) {
  const tin = String(ctx.body.tin ?? "").trim().toUpperCase();
  const idType = String(ctx.body.id_type ?? "BRN").toUpperCase();
  const idValue = String(ctx.body.id_value ?? "").trim();
  const contactId = ctx.body.contact_id as string | undefined;

  if (!tin) throw new HttpError(400, "tin is required");
  if (!idValue) throw new HttpError(400, "id_value is required");
  if (!ID_TYPES.includes(idType)) {
    throw new HttpError(400, `id_type must be one of ${ID_TYPES.join(", ")}`);
  }

  if (!ctx.body.force) {
    const { data: cached } = await ctx.admin
      .from("tin_validations")
      .select("is_valid, validated_at")
      .eq("tin", tin)
      .eq("id_type", idType)
      .eq("id_value", idValue)
      .maybeSingle();

    if (cached) {
      const age = Date.now() - new Date(cached.validated_at).getTime();
      if (age < CACHE_TTL_DAYS * 86_400_000) {
        if (contactId && cached.is_valid) await markVerified(ctx, contactId);
        return { valid: cached.is_valid, cached: true, tin, id_type: idType };
      }
    }
  }

  const creds = await loadCredentials(ctx);
  const client = new MyInvoisClient(creds);
  const { status, data } = await client.validateTin(tin, idType, idValue);

  // MyInvois answers 200 when the pair matches and 404 when it does not.
  if (status !== 200 && status !== 404) {
    throw new HttpError(502, `TIN validation service returned HTTP ${status}`, data);
  }
  const isValid = status === 200;

  await ctx.admin.from("tin_validations").upsert({
    org_id: ctx.orgId,
    tin,
    id_type: idType,
    id_value: idValue,
    is_valid: isValid,
    validated_at: new Date().toISOString(),
    response: data as Record<string, unknown>,
  }, { onConflict: "tin,id_type,id_value" });

  if (contactId && isValid) await markVerified(ctx, contactId);

  await persistLogs(ctx, client.calls);
  return { valid: isValid, cached: false, tin, id_type: idType };
}

async function markVerified(ctx: Ctx, contactId: string) {
  await ctx.admin
    .from("contacts")
    .update({ is_tin_verified: true, tin_verified_at: new Date().toISOString() })
    .eq("id", contactId)
    .eq("org_id", ctx.orgId);
}
