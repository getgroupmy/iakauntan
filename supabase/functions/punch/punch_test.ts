import { assertEquals } from "jsr:@std/assert@1";

import { punchDirection, punchTime } from "./punch.ts";

// A terminal that loses its network at 08:55 and reconnects at 17:30
// sends the morning's punches when it reconnects. What time they are
// filed at is the whole of whether this feature works, so the reading
// of the device's own timestamp is what these assert.

Deno.test("an ISO time with an offset is taken as itself", () => {
  assertEquals(
    punchTime("2026-03-06T08:55:00+08:00"),
    "2026-03-06T00:55:00.000Z",
  );
});

Deno.test("and one in UTC is too", () => {
  assertEquals(punchTime("2026-03-06T00:55:00Z"), "2026-03-06T00:55:00.000Z");
});

Deno.test("a bare local time is Malaysian, because that is where the wall is", () => {
  // Reading it as UTC would file the morning shift as the night
  // before: a whole day out rather than a plausible eight hours, which
  // is the difference between somebody noticing and nobody noticing.
  assertEquals(punchTime("2026-03-06 08:55:00"), "2026-03-06T00:55:00.000Z");
  assertEquals(punchTime("2026-03-06T08:55:00"), "2026-03-06T00:55:00.000Z");
});

Deno.test("a dead battery is refused rather than filed", () => {
  // These are what a terminal with a flat clock actually reports.
  // Twenty years of attendance on somebody's record is not something
  // anything downstream is built to notice.
  assertEquals(punchTime("1970-01-01T00:00:00Z"), null);
  assertEquals(punchTime("2000-01-01 00:00:00"), null);
});

Deno.test("and so is a time nobody can read", () => {
  assertEquals(punchTime("yesterday morning"), null);
  assertEquals(punchTime(""), null);
  assertEquals(punchTime("   "), null);
  assertEquals(punchTime(undefined), null);
});

Deno.test("a future far enough away is a broken clock too", () => {
  assertEquals(punchTime("2999-01-01T00:00:00Z"), null);
});

// Direction. Most devices send nothing, some send a word, and a few
// send ZKTeco's 0 and 1.

Deno.test("the words a device uses for in", () => {
  for (const raw of ["in", "IN", "i", "0", "check-in", " In "]) {
    assertEquals(punchDirection(raw), "in", raw);
  }
});

Deno.test("and for out", () => {
  for (const raw of ["out", "OUT", "o", "1", "check-out"]) {
    assertEquals(punchDirection(raw), "out", raw);
  }
});

Deno.test("anything else is nothing, not a guess", () => {
  // A device that sends "2" means a break or an overtime punch,
  // depending on the model. Guessing it into a clock-out would close
  // somebody's day at lunchtime; the database works the direction out
  // from what the day already has instead.
  assertEquals(punchDirection("2"), null);
  assertEquals(punchDirection("break"), null);
  assertEquals(punchDirection(""), null);
  assertEquals(punchDirection(undefined), null);
});
