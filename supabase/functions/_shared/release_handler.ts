/**
 * The half of a release function that has to talk to something.
 *
 * `release.ts` holds the decisions and is unit tested; this holds the
 * requests and is only type-checked, which is the same split
 * `send-push` makes. Between them, `ios-release/index.ts` and
 * `android-release/index.ts` are four lines each.
 *
 * Deliberately NOT calling `serveFunction` here. That runs at the top
 * level, and a module that starts a server cannot be imported by two
 * functions — which is the whole point of this file.
 *
 * ---------------------------------------------------------------------
 * Why the token lives here and not in the console
 *
 * A token that can dispatch a workflow can start any workflow in the
 * repository, and the browser is not a place to keep one. So the
 * console never sees it: it calls with its own session, this checks
 * that the session belongs to a platform administrator, and only then
 * is the token used — read from the function secrets, the same
 * arrangement `APNS_KEY_P8` has.
 *
 * The check is `am_i_platform_admin()` through the CALLER'S client, so
 * it goes through the same function the console's own screen does and
 * cannot be talked past by a forged body. There is no org_id here and
 * `_shared/context.ts` is not used for that reason: releasing the app
 * is not something an organization does, it is something this company
 * does.
 *
 * ---------------------------------------------------------------------
 * Secrets, shared by both platforms
 *
 *   GITHUB_RELEASE_TOKEN  a fine-grained PAT with Actions: read+write
 *                         on this repository and nothing else
 *   GITHUB_REPOSITORY     "owner/name"
 *   GITHUB_RELEASE_REF    optional; the ref to build. Unset, this asks
 *                         GitHub for the repository's OWN default
 *                         branch rather than assuming one.
 */
import { createClient } from "jsr:@supabase/supabase-js@2.117.0";
import { fail, json } from "./cors.ts";
import { requireEnv } from "./env.ts";
import {
  choiceOf,
  defaultBranchOf,
  dispatchBody,
  dispatchRefusal,
  noteOf,
  refToBuild,
  type ReleasePlatform,
  runsFrom,
} from "./release.ts";

const API = "https://api.github.com";

export async function handleRelease(
  req: Request,
  platform: ReleasePlatform,
): Promise<Response> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return fail("Missing Authorization header", 401);

  const userClient = createClient(
    requireEnv("SUPABASE_URL"),
    requireEnv("SUPABASE_ANON_KEY"),
    { global: { headers: { Authorization: authHeader } } },
  );

  const { data: user } = await userClient.auth.getUser();
  if (!user?.user) return fail("Not authenticated", 401);

  // The same RPC the console's own screen asks. A second copy of the
  // rule here would be a second place for it to be wrong.
  const { data: admin } = await userClient.rpc("am_i_platform_admin");
  if (admin !== true) {
    return fail("Only a platform administrator can release the app", 403);
  }

  const token = Deno.env.get("GITHUB_RELEASE_TOKEN");
  const repo = Deno.env.get("GITHUB_REPOSITORY");
  if (!token || !repo) {
    // 503 and a sentence, rather than a 500: nobody has set this up
    // yet, which is a different thing from it being broken. The same
    // posture `send-push` takes about a missing VAPID pair.
    return fail(
      "Releasing from here is not configured. It needs " +
        "GITHUB_RELEASE_TOKEN and GITHUB_REPOSITORY in the function " +
        `secrets — see docs/${platform.fn}.md.`,
      503,
    );
  }

  const headers = {
    "authorization": `Bearer ${token}`,
    "accept": "application/vnd.github+json",
    "x-github-api-version": "2022-11-28",
    "user-agent": "iakauntan-console",
  };

  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;

  // Reading is the default, because the console asks for this on every
  // visit to the page and starting a build is the thing that has to be
  // asked for by name.
  if (body.action !== "release") {
    const res = await fetch(
      `${API}/repos/${repo}/actions/workflows/${platform.workflow}/runs?per_page=5`,
      { headers },
    );
    if (!res.ok) {
      return fail(`GitHub answered ${res.status} for the run list`, 502);
    }
    return json({ runs: runsFrom(await res.json()) });
  }

  const choice = choiceOf(platform, body[platform.input]);
  if (!choice) {
    return fail(
      `${platform.input} must be one of ${platform.choices.join(", ")}`,
      400,
    );
  }

  // Which ref to build. `GITHUB_RELEASE_REF` when it is set, and
  // otherwise whatever GitHub says this repository's default branch is
  // — asked rather than assumed, because the constant that used to be
  // here (`main`) was a months-old snapshot of a branch that is not the
  // default, and the button cheerfully built it.
  let defaultBranch: string | null = null;
  if (!Deno.env.get("GITHUB_RELEASE_REF")) {
    const repoRes = await fetch(`${API}/repos/${repo}`, { headers });
    if (repoRes.ok) defaultBranch = defaultBranchOf(await repoRes.json());
  }

  const ref = refToBuild(Deno.env.get("GITHUB_RELEASE_REF"), defaultBranch);
  if (!ref) {
    // Deliberately not falling back to a guess. Dispatching the wrong
    // tree wastes a runner's time and fails in a way that looks like a
    // signing problem.
    return fail(
      "Could not read this repository's default branch from GitHub, so " +
        "there is no safe ref to build. Set GITHUB_RELEASE_REF in the " +
        "function secrets to release anyway.",
      502,
    );
  }

  const res = await fetch(
    `${API}/repos/${repo}/actions/workflows/${platform.workflow}/dispatches`,
    {
      method: "POST",
      headers: { ...headers, "content-type": "application/json" },
      body: JSON.stringify(
        dispatchBody(platform, ref, choice, noteOf(body.notes)),
      ),
    },
  );

  // 204 and nothing else. GitHub does not hand back the run it just
  // created, which is why the console polls the list afterwards rather
  // than being given an id here.
  if (res.status !== 204) {
    const said = await res.text().catch(() => "");
    return fail(dispatchRefusal(platform, res.status, said), 502);
  }

  return json({ started: true, [platform.input]: choice, ref });
}
