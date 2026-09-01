/**
 * A `createClient` shaped hole, for type-checking without a network.
 *
 * `deno check` resolves `jsr:@supabase/supabase-js@2` over the network,
 * and there are machines this repository gets worked on from where
 * jsr.io is unreachable. That left the twelve function entry points
 * type-checked in CI and nowhere else, and a `boolean` handed to a
 * parameter typed `Record<string, string>` reached the branch before
 * anything noticed.
 *
 * `check_locally.sh` maps the real module onto this one so the rest of
 * a function -- every local call, every shared helper, every type this
 * repository owns -- is checked on the machine it was written on.
 *
 * **What this deliberately does not check.** The client is `any`. Every
 * `.from()`, `.rpc()`, `.schema()` and `.storage` call off it is
 * unchecked, and a green run of `check_locally.sh` says nothing at all
 * about whether supabase-js is being used correctly. CI checks that
 * against the real package, and CI is the authority. This is a faster,
 * narrower question asked earlier.
 */

// deno-lint-ignore no-explicit-any
type Unchecked = any;

export function createClient(
  _url: string,
  _key: string,
  _options?: unknown,
): Unchecked {
  throw new Error(
    "supabase_js_stub is for type-checking only and must never run",
  );
}

/// The type three functions annotate a client with. Unchecked for the
/// same reason and to the same extent as what `createClient` returns.
export type SupabaseClient = Unchecked;
