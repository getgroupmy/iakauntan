/**
 * Start an iOS release, and say how the last few went.
 *
 * The console's "Release the iOS app" button reaches this, and this
 * reaches `.github/workflows/ios-release.yml` — which is where the
 * build actually happens, on a macOS runner, because Xcode runs on
 * Apple hardware and this function does not.
 *
 * Everything it does is in `_shared/release_handler.ts`, shared with
 * `android-release`; the only thing that differs is the platform, and
 * that is a record in `_shared/release.ts`. See those two for the
 * reasoning about the token, the admin check and the ref.
 */
import { failUnexpected, serveFunction } from "../_shared/cors.ts";
import { IOS } from "../_shared/release.ts";
import { handleRelease } from "../_shared/release_handler.ts";

serveFunction("ios-release", async (req) => {
  try {
    return await handleRelease(req, IOS);
  } catch (error) {
    return failUnexpected(error, "ios-release.failed", req);
  }
});
