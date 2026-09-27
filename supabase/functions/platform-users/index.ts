/**
 * platform-users
 *
 * The three things the console can ask about a person that SQL cannot
 * do: create the account, set a password, and suspend or restore it.
 *
 * POST { "action": "create",  email, password, full_name? }
 *   -> { user_id }
 * POST { "action": "password", user_id, password }
 *   -> { ok: true }
 * POST { "action": "suspend", user_id, suspended: boolean }
 *   -> { ok: true }
 *
 * ## Why this is not a SQL function
 *
 * All three live in `auth.users`, and the only supported way to write
 * that table is the Admin API with the SERVICE ROLE KEY. Writing the
 * columns directly is how you end up with an account that exists and
 * cannot sign in: the password is not a column you can set, it is a
 * hash in a format GoTrue owns and changes.
 *
 * That key can read and write every row in the database with no policy
 * in its way. So it exists here and nowhere else -- not in the app, not
 * in the schema, not in any payload a client can read.
 *
 * ## Holding the key is not being allowed to use it
 *
 * Every action checks `am_i_platform_admin` THROUGH THE CALLER'S OWN
 * CLIENT before the admin client is touched. The caller's JWT decides;
 * the service role only carries out what that decision allowed. A
 * function that read its own service key and acted on the request would
 * be an open door with a lock painted on it.
 *
 * ## The password is the admin's choice, and that was decided on purpose
 *
 * Asked for as "create with a password the admin sets" rather than an
 * invitation, which is faster for onboarding somebody over the phone
 * and means an administrator has briefly known their credentials. The
 * account is created ALREADY CONFIRMED, because an administrator who
 * has just typed somebody's password is not going to be helped by a
 * confirmation e-mail.
 *
 * What is NOT done here: the password is never logged, never returned,
 * and never written to `audit_logs`. The trail records that a password
 * was set and by whom, which is the part anybody needs afterwards.
 */
import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2.117.0";
import { fail, json, serveFunction } from "../_shared/cors.ts";
import { requireEnv } from "../_shared/env.ts";
// Every decision made before the service role key is touched lives in
// `rules.ts`, which imports nothing, so `rules_test.ts` can assert them
// on a machine that cannot reach jsr.io.
import {
  action,
  banDuration,
  normalizeEmail,
  passwordProblem,
  suspendProblem,
  text,
} from "./rules.ts";

interface Caller {
  userClient: SupabaseClient;
  admin: SupabaseClient;
  userId: string;
  body: Record<string, unknown>;
}

/**
 * Resolves the caller and refuses anybody who is not platform staff.
 *
 * The membership question every other function asks is about one
 * organization. This one is not scoped to a company at all -- a person
 * is not owned by one -- so the only gate is platform staff, and it is
 * asked of the database rather than decided here.
 */
async function callerOrThrow(req: Request): Promise<Caller | Response> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return fail("Missing Authorization header", 401);

  const url = requireEnv("SUPABASE_URL");
  const anonKey = requireEnv("SUPABASE_ANON_KEY");
  const serviceKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");

  const userClient = createClient(url, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: userData } = await userClient.auth.getUser();
  if (!userData?.user) return fail("Not authenticated", 401);

  // Asked through the CALLER's client, so their own JWT decides. The
  // admin client below is only ever the hands.
  const { data: isAdmin, error } = await userClient.rpc("am_i_platform_admin");
  if (error) return fail("Could not check your access", 403);
  if (isAdmin !== true) return fail("Platform administrators only", 403);

  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  return {
    userClient,
    admin: createClient(url, serviceKey),
    userId: userData.user.id,
    body,
  };
}

/**
 * What was done, in the platform's own trail.
 *
 * `org_id` null: creating a person is not something one of their
 * companies did. The password never appears -- what anybody needs
 * afterwards is that one was set and by whom.
 */
async function note(
  c: Caller,
  userId: string,
  action: string,
  event: string,
  detail: Record<string, unknown> = {},
): Promise<void> {
  await c.admin.from("audit_logs").insert({
    org_id: null,
    user_id: c.userId,
    table_name: "auth.users",
    record_id: userId,
    action,
    new_data: { event, ...detail },
  });
}

async function createUser(c: Caller): Promise<Response> {
  const email = normalizeEmail(c.body.email);
  const password = text(c.body.password);
  const fullName = text(c.body.full_name);

  if (!email.includes("@")) return fail("That is not an e-mail address.");
  const weak = passwordProblem(password, { creating: true });
  if (weak) return fail(weak);

  const { data, error } = await c.admin.auth.admin.createUser({
    email,
    password,
    // Already confirmed: an administrator who has just typed somebody's
    // password is not helped by a confirmation e-mail, and an account
    // that cannot sign in is not an account.
    email_confirm: true,
    user_metadata: fullName ? { full_name: fullName } : {},
  });

  if (error || !data?.user) {
    // GoTrue says "A user with this email address has already been
    // registered", which is the one failure worth passing through
    // whole -- it tells the administrator to go and look for them.
    return fail(error?.message ?? "The account was not created.", 400);
  }

  // The profile row is made by a trigger on `auth.users`; the name is
  // written here because `user_metadata` is not where this app reads it.
  if (fullName) {
    await c.admin
      .from("profiles")
      .update({ full_name: fullName })
      .eq("id", data.user.id);
  }

  await note(c, data.user.id, "insert", "platform_create_user", { email });
  return json({ user_id: data.user.id });
}

async function setPassword(c: Caller): Promise<Response> {
  const userId = text(c.body.user_id);
  const password = text(c.body.password);
  if (!userId) return fail("Which person?");
  const weak = passwordProblem(password);
  if (weak) return fail(weak);

  const { error } = await c.admin.auth.admin.updateUserById(userId, {
    password,
  });
  if (error) return fail(error.message, 400);

  await note(c, userId, "update", "platform_set_password");
  return json({ ok: true });
}

async function setSuspended(c: Caller): Promise<Response> {
  const userId = text(c.body.user_id);
  const suspended = c.body.suspended === true;

  const refused = suspendProblem(userId, c.userId, suspended);
  if (refused) return fail(refused, 400);

  const { error } = await c.admin.auth.admin.updateUserById(userId, {
    ban_duration: banDuration(suspended),
  });
  if (error) return fail(error.message, 400);

  await note(c, userId, "update", "platform_set_suspended", { suspended });
  return json({ ok: true });
}

serveFunction("platform-users", async (req) => {
  const c = await callerOrThrow(req);
  if (c instanceof Response) return c;

  switch (action(c.body.action)) {
    case "create":
      return await createUser(c);
    case "password":
      return await setPassword(c);
    case "suspend":
      return await setSuspended(c);
    default:
      return fail("Say what to do: create, password or suspend.");
  }
});
