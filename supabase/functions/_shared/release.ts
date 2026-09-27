/**
 * What the console is allowed to ask for, and what GitHub is told.
 *
 * Shared by `ios-release` and `android-release`, which differ in three
 * things and nothing else: which workflow file to dispatch, what the
 * destination input is called, and which destinations are allowed.
 * Everything around that — checking the caller is a platform
 * administrator, holding the token, resolving the ref, trimming the
 * run list, translating a refusal — is one implementation because a
 * second copy is a second place for it to be wrong. That is the
 * reasoning `index.ts` already gave for not re-implementing
 * `am_i_platform_admin`.
 *
 * Its own module so it can be tested without starting a server, the
 * same arrangement `send-push/routing.ts` has and for the same reason:
 * `index.ts` calls `serveFunction` at the top level. Nothing here
 * imports supabase-js either, which keeps the tested half free of a
 * dependency the local checker can only stub.
 *
 * The decisions here are small and the consequences of getting them
 * wrong are not. These functions hold a token that can start a workflow
 * which signs a build with a distribution certificate or an upload key
 * and hands it to Apple or Google under this company's name.
 * Everything accepted from a browser is checked against a list written
 * here rather than passed through.
 */

/** Which app, which workflow, and where a build may be sent. */
export interface ReleasePlatform {
  /** The edge function's name, and what a failure is tagged with. */
  readonly fn: string;
  /** The workflow file. Named once, because a typo here is a 404. */
  readonly workflow: string;
  /** What the destination input is called in that workflow. */
  readonly input: string;
  /** Every value that input accepts. */
  readonly choices: readonly string[];
  /** For the sentence about where an unset ref comes from. */
  readonly label: string;
}

export const IOS: ReleasePlatform = {
  fn: "ios-release",
  workflow: "ios-release.yml",
  input: "lane",
  choices: ["testflight", "appstore"],
  label: "iOS",
};

export const ANDROID: ReleasePlatform = {
  fn: "android-release",
  workflow: "android-release.yml",
  input: "track",
  // The same four `android-release.yml` offers, in the same order.
  // `scripts/check_release_choices.py` holds them to that.
  choices: ["internal", "alpha", "beta", "production"],
  label: "Android",
};

/**
 * The destination, or null if it is not one this platform offers.
 *
 * An allow-list rather than a cast. The value reaches the workflow as a
 * `workflow_dispatch` input and a `choice` input GitHub does not
 * recognise is a 422 — but the reason to check it HERE is that it also
 * decides what the console says about review, and a value nobody
 * reasoned about should not get that far.
 */
export function choiceOf(
  platform: ReleasePlatform,
  raw: unknown,
): string | null {
  return typeof raw === "string" && platform.choices.includes(raw)
    ? raw
    : null;
}

/**
 * The note, trimmed and bounded.
 *
 * It is typed by a person and ends up in a workflow input, a step
 * summary and a shell interpolation. Length is the only thing worth
 * enforcing — GitHub bounds inputs at 64KB and a note is a line — and
 * newlines are removed because the summary writes it as a bullet.
 */
export function noteOf(raw: unknown): string {
  if (typeof raw !== "string") return "";
  return raw.replace(/[\r\n]+/g, " ").trim().slice(0, 200);
}

/** The body GitHub's dispatch endpoint takes. */
export function dispatchBody(
  platform: ReleasePlatform,
  ref: string,
  choice: string,
  notes: string,
): Record<string, unknown> {
  return {
    ref,
    inputs: { [platform.input]: choice, ...(notes ? { notes } : {}) },
  };
}

export interface RunSummary {
  id: number;
  number: number;
  /** `queued`, `in_progress` or `completed`. */
  status: string;
  /** `success`, `failure`, `cancelled` … or null while it runs. */
  conclusion: string | null;
  lane: string | null;
  startedAt: string | null;
  url: string;
}

/**
 * The runs, as the console needs them.
 *
 * Trimmed deliberately rather than passed through. GitHub's run object
 * carries the whole head commit, the actor, the repository and a dozen
 * URLs; none of it belongs on a screen that is asking "did the release
 * work", and forwarding an upstream shape wholesale is how a console
 * ends up depending on fields nobody chose.
 */
/**
 * The repository's own default branch, out of a `GET /repos/{repo}`.
 *
 * Null when the payload does not carry one, so the caller can refuse
 * rather than guess.
 */
export function defaultBranchOf(payload: unknown): string | null {
  const branch = (payload as { default_branch?: unknown })?.default_branch;
  return typeof branch === "string" && branch.trim() ? branch.trim() : null;
}

/**
 * Which ref to build.
 *
 * `GITHUB_RELEASE_REF` when somebody has set it, and otherwise the
 * repository's ACTUAL default branch — read from the API, not assumed.
 *
 * This used to be `GITHUB_RELEASE_REF || "main"`, and that constant was
 * wrong in the most expensive way available. This repository's default
 * branch is not `main`; `main` is a months-old snapshot. So the console
 * button dispatched a tree in which none of the signing fixes existed,
 * and failed at `xcodebuild` with errors that had been fixed hours
 * earlier — a button that worked perfectly, against code that did not.
 *
 * Asking GitHub removes the guess and the secret at once: nobody has to
 * set `GITHUB_RELEASE_REF` for the button to build the right thing, and
 * if the default branch ever moves the function follows it without an
 * edit. The override stays for releasing from somewhere else on purpose.
 */
export function refToBuild(
  configured: string | undefined | null,
  defaultBranch: string | null,
): string | null {
  const explicit = (configured ?? "").trim();
  if (explicit) return explicit;
  return defaultBranch;
}

export function runsFrom(payload: unknown): RunSummary[] {
  const runs = (payload as { workflow_runs?: unknown })?.workflow_runs;
  if (!Array.isArray(runs)) return [];
  return runs.map((raw) => {
    const r = raw as Record<string, unknown>;
    return {
      id: Number(r.id ?? 0),
      number: Number(r.run_number ?? 0),
      status: typeof r.status === "string" ? r.status : "unknown",
      conclusion: typeof r.conclusion === "string" ? r.conclusion : null,
      // `display_title` is the workflow name for a dispatch, so it says
      // nothing useful. The lane is not on the run object at all —
      // GitHub does not echo dispatch inputs — so this is null and the
      // console does not claim otherwise.
      lane: null,
      startedAt: typeof r.run_started_at === "string" ? r.run_started_at : null,
      url: typeof r.html_url === "string" ? r.html_url : "",
    };
  });
}

/**
 * What to say when GitHub refuses to start the build.
 *
 * One case deserves its own sentence, because the raw answer sends
 * somebody looking in the wrong place entirely:
 *
 *     422 {"message":"Workflow does not have 'workflow_dispatch' trigger"}
 *
 * The workflow DOES have one. What it does not have is a copy on the
 * REF BEING DISPATCHED. A dispatch names a ref, and GitHub looks for
 * the workflow file on that ref — so a file living on some other
 * branch produces this, however correct its trigger is.
 *
 * Said carefully because the obvious reading is wrong twice over.
 * "It must be on the default branch" is the usual folklore and was
 * written here first; it is not what bit this repository, whose
 * default branch is not `main` at all. Reading either the message or
 * the folklore at face value leads to editing a trigger that was
 * always correct.
 *
 * Everything else is passed through with its status, because the
 * status is the useful part and guessing at the rest would be this
 * function inventing a diagnosis.
 */
export function dispatchRefusal(
  platform: ReleasePlatform,
  status: number,
  said: string,
): string {
  if (status === 422 && said.includes("workflow_dispatch")) {
    return "GitHub will not start this build because " +
      `${platform.workflow} is not on the branch it was asked to build. ` +
      "A dispatch names a ref — this function uses the repository's " +
      "own default branch, or GITHUB_RELEASE_REF when that is set — " +
      "and the workflow file has to exist THERE, whatever branch it " +
      "was written on. Merge it to that branch, or point " +
      "GITHUB_RELEASE_REF at the branch that has it. See " +
      "docs/ios-release.md.";
  }
  if (status === 404) {
    return `GitHub cannot find ${platform.workflow} in this repository. ` +
      "Check GITHUB_REPOSITORY, and that the token can see it.";
  }
  const tail = said.trim();
  return `GitHub refused to start the build (${status}).${
    tail ? ` ${tail}` : ""
  }`;
}
