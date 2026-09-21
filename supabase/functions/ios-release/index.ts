/**
 * Start an iOS release, and say how the last few went.
 *
 * The console's "Release to the App Store" button reaches this, and
 * this reaches `.github/workflows/ios-release.yml` — which is where the
 * build actually happens, on a macOS runner, because Xcode runs on
 * Apple hardware and this function does not.
 *
 * ---------------------------------------------------------------------
 * Why the token lives here and not in the console
 *
 * A token that can dispatch a workflow can start any workflow in the
 * repository, and the browser is not a place to keep one. So the
 * console never sees it: it calls this with its own session, this
 * checks that the session belongs to a platform administrator, and only
 * then does this use the token — which it reads from the function
 * secrets, the same arrangement `APNS_KEY_P8` has.
 *
 * The check is `am_i_platform_admin()` through the CALLER'S client, so
 * it goes through the same function the console's own screen does and
 * cannot be talked past by a forged body. There is no org_id here and
 * `_shared/context.ts` is not used for that reason: releasing the app
 * is not something an organization does, it is something this company
 * does.
 *
 * ---------------------------------------------------------------------
 * Secrets
 *
 *   GITHUB_RELEASE_TOKEN  a fine-grained PAT with Actions: read+write
 *                         on this repository and nothing else
 *   GITHUB_REPOSITORY     "owner/name"
 *   GITHUB_RELEASE_REF    optional; the ref to build. Unset, this asks
 *                         GitHub for the repository's OWN default
 *                         branch rather than assuming one — see
 *                         `refToBuild`, and the evening that constant
 *                         cost.
 */
import { createClient } from "jsr:@supabase/supabase-js@2";
import { fail, failUnexpected, json, serveFunction } from "../_shared/cors.ts";
import { requireEnv } from "../_shared/env.ts";
import {
  defaultBranchOf,
  dispatchBody,
  dispatchRefusal,
  laneOf,
  noteOf,
  refToBuild,
  runsFrom,
  WORKFLOW,
} from "./dispatch.ts";

const API = "https://api.github.com";

serveFunction("ios-release", async (req) => {
  try {
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
          "secrets — see docs/ios-release.md.",
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

    // Reading is the default, because the console asks for this on
    // every visit to the page and starting a build is the thing that
    // has to be asked for by name.
    if (body.action !== "release") {
      const res = await fetch(
        `${API}/repos/${repo}/actions/workflows/${WORKFLOW}/runs?per_page=5`,
        { headers },
      );
      if (!res.ok) {
        return fail(`GitHub answered ${res.status} for the run list`, 502);
      }
      return json({ runs: runsFrom(await res.json()) });
    }

    const lane = laneOf(body.lane);
    if (!lane) return fail("lane must be testflight or appstore", 400);

    // Which ref to build. `GITHUB_RELEASE_REF` when it is set, and
    // otherwise whatever GitHub says this repository's default branch
    // is — asked rather than assumed, because the constant that used to
    // be here (`main`) was a months-old snapshot of a branch that is
    // not the default, and the button cheerfully built it.
    let defaultBranch: string | null = null;
    if (!Deno.env.get("GITHUB_RELEASE_REF")) {
      const repoRes = await fetch(`${API}/repos/${repo}`, { headers });
      if (repoRes.ok) {
        defaultBranch = defaultBranchOf(await repoRes.json());
      }
    }

    const ref = refToBuild(Deno.env.get("GITHUB_RELEASE_REF"), defaultBranch);
    if (!ref) {
      // Deliberately not falling back to a guess. Dispatching the wrong
      // tree wastes twenty-five minutes on a macOS runner and fails in
      // a way that looks like a signing problem.
      return fail(
        "Could not read this repository's default branch from GitHub, " +
          "so there is no safe ref to build. Set GITHUB_RELEASE_REF in " +
          "the function secrets to release anyway.",
        502,
      );
    }
    const res = await fetch(
      `${API}/repos/${repo}/actions/workflows/${WORKFLOW}/dispatches`,
      {
        method: "POST",
        headers: { ...headers, "content-type": "application/json" },
        body: JSON.stringify(dispatchBody(ref, lane, noteOf(body.notes))),
      },
    );

    // 204 and nothing else. GitHub does not hand back the run it just
    // created, which is why the console polls the list afterwards
    // rather than being given an id here.
    if (res.status !== 204) {
      const said = await res.text().catch(() => "");
      return fail(dispatchRefusal(res.status, said), 502);
    }

    return json({ started: true, lane, ref });
  } catch (error) {
    return failUnexpected(error, "ios-release.failed", req);
  }
});
