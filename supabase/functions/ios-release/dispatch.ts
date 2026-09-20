/**
 * What the console is allowed to ask for, and what GitHub is told.
 *
 * Its own module so it can be tested without starting a server, the
 * same arrangement `send-push/routing.ts` has and for the same reason:
 * `index.ts` calls `serveFunction` at the top level.
 *
 * The decisions here are small and the consequences of getting them
 * wrong are not. This function holds a token that can start a workflow
 * which signs a build with a distribution certificate and hands it to
 * Apple under this company's name. Everything it accepts from a browser
 * is therefore checked against a list written here rather than passed
 * through.
 */

/** The workflow file. Named once, because a typo here is a 404. */
export const WORKFLOW = "ios-release.yml";

/** Where a build may be sent. */
export type Lane = "testflight" | "appstore";

/**
 * The lane, or null if it is not one.
 *
 * An allow-list rather than a cast. `lane` reaches the workflow as a
 * `workflow_dispatch` input and a `choice` input GitHub does not
 * recognise is a 422 — but the reason to check it HERE is that this
 * value also decides what the summary says about App Review, and a
 * value nobody reasoned about should not get that far.
 */
export function laneOf(raw: unknown): Lane | null {
  return raw === "testflight" || raw === "appstore" ? raw : null;
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
  ref: string,
  lane: Lane,
  notes: string,
): Record<string, unknown> {
  return { ref, inputs: { lane, ...(notes ? { notes } : {}) } };
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
