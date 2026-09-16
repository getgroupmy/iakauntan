/**
 * Reading what a clock on a wall said.
 *
 * Separate from `index.ts` because that file calls `Deno.serve` at
 * import time: a test that imported it would start a listener rather
 * than run assertions. `bar_provider.ts` is split for the same reason.
 */

/**
 * A punch's time, as a device writes it.
 *
 * ISO with an offset is unambiguous and is taken as itself. A device
 * that sends a bare local time is read as Malaysian, because that is
 * where the wall is — and reading it as UTC would file the morning
 * shift as the night before, which is a whole day out rather than a
 * plausible eight hours.
 */
export function punchTime(raw: string | undefined): string | null {
  if (!raw) return null;
  const s = raw.trim();
  if (!s) return null;

  const hasZone = /(?:Z|[+-]\d{2}:?\d{2})$/.test(s);
  const iso = hasZone ? s : `${s.replace(" ", "T")}+08:00`;
  const when = new Date(iso);
  if (Number.isNaN(when.getTime())) return null;

  // A device with a dead battery reports 1970 or 2000-01-01. Filing
  // those as attendance puts a clock-in twenty years ago on somebody's
  // record, which nothing downstream is built to notice.
  const year = when.getUTCFullYear();
  if (year < 2015 || year > 2100) return null;

  return when.toISOString();
}

/** 'in', 'out', or nothing — which is what most devices send. */
export function punchDirection(raw: string | undefined): string | null {
  const s = (raw ?? "").trim().toLowerCase();
  if (s === "in" || s === "i" || s === "0" || s === "check-in") return "in";
  if (s === "out" || s === "o" || s === "1" || s === "check-out") return "out";
  return null;
}
