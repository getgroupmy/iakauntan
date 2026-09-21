/**
 * Start an Android release, and say how the last few went.
 *
 * The counterpart of `ios-release`, and deliberately the same code:
 * `_shared/release_handler.ts` does the work and `_shared/release.ts`
 * holds what differs, which is the workflow file, the name of the
 * destination input and the destinations it accepts.
 *
 * Unlike the iOS one this builds on Ubuntu, so it is roughly a tenth
 * of the cost and a third of the time — but the console asks before
 * starting either, because both put a signed build in front of a store
 * under this company's name.
 *
 * `android-release.yml` also has a build-only mode, which attaches the
 * bundle to the run instead of uploading it. That is deliberately NOT
 * offered here: it exists for the one manual upload Play requires
 * before its API will accept anything, which is a setup step done once
 * from the Actions tab, not a thing to press from a console.
 */
import { failUnexpected, serveFunction } from "../_shared/cors.ts";
import { ANDROID } from "../_shared/release.ts";
import { handleRelease } from "../_shared/release_handler.ts";

serveFunction("android-release", async (req) => {
  try {
    return await handleRelease(req, ANDROID);
  } catch (error) {
    return failUnexpected(error, "android-release.failed", req);
  }
});
