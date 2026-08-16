// Environment variables a function cannot do its job without.

/// Read a variable, or refuse.
///
/// The three Supabase variables — `SUPABASE_URL`, `SUPABASE_ANON_KEY`,
/// `SUPABASE_SERVICE_ROLE_KEY` — are injected by the edge runtime and
/// are always there in a deployed function. The point of this is the
/// case where they are not: a `!` hands `undefined` to `createClient`,
/// which fails several frames later with a message about a malformed
/// URL, and the person reading that log has no way to tell it from a
/// network problem. This one says which variable, at the point it was
/// wanted.
///
/// It throws rather than returning a `Response`, so the caller cannot
/// forget to check it. `serveFunction` catches, logs it with a
/// reference, and answers 500 — the name of the missing variable stays
/// in the log and never reaches the caller, because which secrets a
/// service is missing is not a thing to tell the internet.
export function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}
