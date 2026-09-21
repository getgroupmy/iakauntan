/**
 * What the console may ask for.
 *
 * This function holds a token that starts a workflow which signs a
 * build with a distribution certificate and hands it to Apple under
 * this company's name. Everything it takes from a browser is checked
 * against a list, and these are the assertions that say so.
 */
import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
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

Deno.test("the two lanes, and nothing else", () => {
  assertEquals(laneOf("testflight"), "testflight");
  assertEquals(laneOf("appstore"), "appstore");
});

Deno.test("a lane nobody wrote a workflow for is refused", () => {
  // An allow-list rather than a cast. GitHub would answer 422 for an
  // unrecognised `choice` input anyway — but this value also decides
  // what the summary says about App Review, and a value nobody
  // reasoned about should not reach that.
  assertEquals(laneOf("production"), null);
  assertEquals(laneOf("TestFlight"), null);
  assertEquals(laneOf(""), null);
  assertEquals(laneOf(null), null);
  assertEquals(laneOf(7), null);
  assertEquals(laneOf({ lane: "appstore" }), null);
});

Deno.test("a note is one line and bounded", () => {
  assertEquals(noteOf("  fixed the ring  "), "fixed the ring");
  assertEquals(noteOf("two\nlines\r\nhere"), "two lines here");
  assertEquals(noteOf("x".repeat(500)).length, 200);
});

Deno.test("and anything that is not a string is no note at all", () => {
  assertEquals(noteOf(undefined), "");
  assertEquals(noteOf(null), "");
  assertEquals(noteOf(42), "");
  assertEquals(noteOf(["a"]), "");
});

Deno.test("the dispatch body carries the ref and the lane", () => {
  assertEquals(dispatchBody("main", "appstore", "a note"), {
    ref: "main",
    inputs: { lane: "appstore", notes: "a note" },
  });
});

Deno.test("and leaves `notes` out when there is none", () => {
  // Rather than sending an empty string. GitHub records inputs on the
  // run, and a blank note is noise in a list somebody reads to find
  // out what a build was.
  assertEquals(dispatchBody("main", "testflight", ""), {
    ref: "main",
    inputs: { lane: "testflight" },
  });
});

Deno.test("the workflow is named once", () => {
  // A typo here is a 404 from GitHub rather than anything that reads
  // like "the workflow does not exist", so it is a constant and this
  // pins it to the file on disk.
  assertEquals(WORKFLOW, "ios-release.yml");
});

Deno.test("runs come back trimmed to what a console needs", () => {
  const runs = runsFrom({
    workflow_runs: [{
      id: 42,
      run_number: 7,
      status: "completed",
      conclusion: "success",
      run_started_at: "2026-09-20T12:00:00Z",
      html_url: "https://github.com/o/r/actions/runs/42",
      head_commit: { message: "should not survive" },
      actor: { login: "somebody" },
    }],
  });
  assertEquals(runs, [{
    id: 42,
    number: 7,
    status: "completed",
    conclusion: "success",
    lane: null,
    startedAt: "2026-09-20T12:00:00Z",
    url: "https://github.com/o/r/actions/runs/42",
  }]);
});

Deno.test("a running one has no conclusion yet, and says so", () => {
  // Null rather than a word. "pending" would be this code inventing a
  // status GitHub does not have, and the console draws a spinner off
  // exactly this.
  const runs = runsFrom({
    workflow_runs: [{ id: 1, run_number: 2, status: "in_progress" }],
  });
  assertEquals(runs[0].conclusion, null);
  assertEquals(runs[0].status, "in_progress");
});

Deno.test("the lane is null, because GitHub does not echo inputs", () => {
  // Worth an assertion of its own: it would be easy to read
  // `display_title` and call it the lane, and it is the workflow's
  // name for a dispatch. A console that displayed that would be
  // showing "iOS release" where it promised to show where the build
  // went.
  const runs = runsFrom({
    workflow_runs: [{ id: 1, run_number: 2, display_title: "iOS release" }],
  });
  assertEquals(runs[0].lane, null);
});

Deno.test("and a payload that is not a run list is simply nothing", () => {
  assertEquals(runsFrom(null), []);
  assertEquals(runsFrom({}), []);
  assertEquals(runsFrom({ workflow_runs: "no" }), []);
  assertEquals(runsFrom({ message: "Bad credentials" }), []);
});

Deno.test("a 422 about workflow_dispatch names the real cause", () => {
  // The one refusal worth translating. GitHub says the workflow has no
  // `workflow_dispatch` trigger; the file plainly does have one. What
  // it lacks is a copy on the REF BEING DISPATCHED — this function
  // sends the repository's default branch, or GITHUB_RELEASE_REF when
  // it is set — so the message sends somebody to edit a trigger that
  // was never wrong.
  //
  // The first version of this said the file must be ON the default
  // branch, repeating the usual folklore. It is wrong here: this
  // repository's default branch is not `main`, the workflow was on the
  // default branch the whole time, and the dispatch still failed
  // because `main` did not have it. The REF is what matters.
  const said = dispatchRefusal(
    422,
    '{"message":"Workflow does not have \'workflow_dispatch\' trigger"}',
  );
  assertStringIncludes(said, "GITHUB_RELEASE_REF");
  assertStringIncludes(said, WORKFLOW);
  // It must explain the REF, which is the actual mechanism.
  assertStringIncludes(said, "ref");
  // And it must not repeat the folklore that cost an evening — that a
  // workflow_dispatch is only registered from the default branch.
  //
  // This was once `said.includes("default branch") === false`, which
  // worked while the function assumed `main`. It no longer
  // distinguishes anything: the function now READS the default branch
  // and the sentence says so, correctly. The claim being guarded
  // against is that the file must BE there, so that is what is
  // asserted.
  assertEquals(said.includes("must be on"), false);
  assertEquals(said.includes("only"), false);
  // And it must not simply repeat GitHub's wording, which is the
  // behaviour being replaced.
  assertEquals(said.includes("does not have"), false);
});

Deno.test("but another 422 is not given that explanation", () => {
  // `lane` is a `choice` input, so an unrecognised value is also a 422.
  // Telling somebody to merge a branch for that would be worse than
  // saying nothing.
  const said = dispatchRefusal(422, '{"message":"Unexpected inputs"}');
  assertStringIncludes(said, "422");
  assertEquals(said.includes("GITHUB_RELEASE_REF"), false);
});

Deno.test("a 404 points at the repository and the token", () => {
  const said = dispatchRefusal(404, "");
  assertStringIncludes(said, "GITHUB_REPOSITORY");
  assertStringIncludes(said, WORKFLOW);
});

Deno.test("and anything else keeps its status and whatever was said", () => {
  assertStringIncludes(dispatchRefusal(500, "boom"), "500");
  assertStringIncludes(dispatchRefusal(500, "boom"), "boom");
  // No trailing space when GitHub said nothing at all.
  assertEquals(
    dispatchRefusal(503, "   "),
    "GitHub refused to start the build (503).",
  );
});

Deno.test("the default branch is read, not assumed", () => {
  assertEquals(
    defaultBranchOf({ default_branch: "claude/iakauntan-accounting-crm-8snun0" }),
    "claude/iakauntan-accounting-crm-8snun0",
  );
  assertEquals(defaultBranchOf({ default_branch: "  main  " }), "main");

  // Null rather than a guess, so the caller refuses instead of
  // dispatching something plausible.
  assertEquals(defaultBranchOf({}), null);
  assertEquals(defaultBranchOf({ default_branch: "" }), null);
  assertEquals(defaultBranchOf({ default_branch: 7 }), null);
  assertEquals(defaultBranchOf(null), null);
});

Deno.test("the ref is the override, else the default branch, else nothing", () => {
  // The explicit setting wins, because releasing from a specific ref on
  // purpose has to stay possible.
  assertEquals(refToBuild("release/1.2", "main"), "release/1.2");
  assertEquals(refToBuild("  release/1.2  ", "main"), "release/1.2");

  // Unset — including set-to-blank, which is what an emptied secret
  // looks like — falls through to what GitHub said.
  assertEquals(refToBuild(undefined, "some-branch"), "some-branch");
  assertEquals(refToBuild("", "some-branch"), "some-branch");
  assertEquals(refToBuild("   ", "some-branch"), "some-branch");

  // And with neither, NULL rather than `main`.
  //
  // This is the whole point of the change. `GITHUB_RELEASE_REF ||
  // "main"` is what this used to be, and `main` here is a months-old
  // snapshot that is not the default branch — so the console button
  // built a tree with none of the signing fixes in it and failed at
  // xcodebuild, twenty-five macOS minutes later, looking exactly like
  // a signing problem.
  assertEquals(refToBuild(undefined, null), null);
  assertEquals(refToBuild("", null), null);
});
