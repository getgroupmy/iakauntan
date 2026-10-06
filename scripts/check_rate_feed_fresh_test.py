#!/usr/bin/env python3
"""Self-test for `check_rate_feed_fresh.py`.

The gate exists because a dead rate feed went eleven days unnoticed, so
the cases worth pinning are the ones where it would pass while the feed
is dead: an empty table, PostgREST's own error object, a date in the
future, and a threshold that has drifted out of order.

And one case in the other direction, because a gate that cries wolf over
an ordinary long weekend is a gate somebody switches off.
"""

from __future__ import annotations

import contextlib
import datetime as dt
import io
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import check_rate_feed_fresh as g  # noqa: E402

TODAY = dt.date(2026, 10, 6)  # a Tuesday


def run(argv: list[str], stdin: str = "") -> tuple[int, str]:
    out = io.StringIO()
    old = sys.stdin
    sys.stdin = io.StringIO(stdin)
    try:
        with contextlib.redirect_stdout(out):
            code = g.main(argv)
    finally:
        sys.stdin = old
    return code, out.getvalue()


class Verdict(unittest.TestCase):

    def test_yesterday_is_fresh(self):
        self.assertEqual(g.verdict(TODAY - dt.timedelta(days=1), TODAY)[0], g.FRESH)

    def test_a_friday_rate_read_on_monday_is_fresh(self):
        """Three days, and the commonest reading of the week."""
        monday = dt.date(2026, 10, 5)
        self.assertEqual(g.verdict(dt.date(2026, 10, 2), monday)[0], g.FRESH)

    def test_a_long_weekend_warns_and_does_not_fail(self):
        """A holiday Monday makes it four days. Not a failure.

        If this ever fails, the gate fires every long weekend and will be
        switched off the second time it does.
        """
        state, age, _ = g.verdict(TODAY - dt.timedelta(days=g.WARN_DAYS), TODAY)
        self.assertEqual((state, age), (g.WARN, g.WARN_DAYS))

    def test_the_day_before_the_stale_line_still_only_warns(self):
        state, _, _ = g.verdict(TODAY - dt.timedelta(days=g.STALE_DAYS - 1), TODAY)
        self.assertEqual(state, g.WARN)

    def test_the_stale_line_itself_fails(self):
        """Boundary, so `>=` cannot quietly become `>`."""
        state, age, _ = g.verdict(TODAY - dt.timedelta(days=g.STALE_DAYS), TODAY)
        self.assertEqual((state, age), (g.STALE, g.STALE_DAYS))

    def test_the_eleven_days_that_bought_this_file_fail(self):
        state, age, sentence = g.verdict(dt.date(2026, 9, 25), TODAY)
        self.assertEqual((state, age), (g.STALE, 11))
        self.assertIn("fetch-rates.unreachable", sentence)

    def test_no_date_at_all_is_broken_not_fresh(self):
        """The worst case must not read as the best."""
        self.assertEqual(g.verdict(None, TODAY)[0], g.BROKEN)

    def test_a_date_in_the_future_is_broken_not_fresh(self):
        """A negative age is below every threshold and would pass them all."""
        state, age, _ = g.verdict(TODAY + dt.timedelta(days=3), TODAY)
        self.assertEqual((state, age), (g.BROKEN, -3))

    def test_the_thresholds_are_in_order(self):
        """A warning line past the failure line can never warn."""
        self.assertLess(g.WARN_DAYS, g.STALE_DAYS)
        self.assertGreater(g.WARN_DAYS, 3,
            "a Friday rate read on Monday is three days old; warning at "
            "three would warn every single week")


class Payload(unittest.TestCase):

    def test_a_postgrest_reply_is_read(self):
        self.assertEqual(g.newest_from_rows('[{"rate_date":"2026-09-25"}]'),
                         dt.date(2026, 9, 25))

    def test_the_newest_of_several_rows_is_taken(self):
        self.assertEqual(
            g.newest_from_rows('[{"rate_date":"2026-09-01"},'
                               '{"rate_date":"2026-09-25"},'
                               '{"rate_date":"2026-09-10"}]'),
            dt.date(2026, 9, 25))

    def test_a_timestamp_is_read_as_its_date(self):
        self.assertEqual(g.newest_from_rows('[{"rate_date":"2026-09-25T00:00:00"}]'),
                         dt.date(2026, 9, 25))

    def test_an_empty_table_has_no_newest_date(self):
        self.assertIsNone(g.newest_from_rows("[]"))

    def test_a_postgrest_error_object_is_not_a_rate(self):
        """What an expired key returns. It must not parse as a reply."""
        self.assertIsNone(g.newest_from_rows(
            '{"message":"Invalid API key","hint":"Double check your key"}'))

    def test_garbage_is_not_a_rate(self):
        for junk in ("", "not json", "null", '[{"rate_date":null}]',
                     '[{"other":"2026-09-25"}]', '[{"rate_date":"yesterday"}]',
                     '["2026-09-25"]'):
            with self.subTest(junk=junk):
                self.assertIsNone(g.newest_from_rows(junk))


class EndToEnd(unittest.TestCase):

    def test_fresh_exits_zero_and_annotates_nothing(self):
        code, out = run(["--today", "2026-10-06"], '[{"rate_date":"2026-10-05"}]')
        self.assertEqual(code, 0)
        self.assertNotIn("::", out)

    def test_a_warning_exits_zero_but_annotates(self):
        """Annotated, so it reaches the run summary rather than the log only."""
        code, out = run(["--newest", "2026-10-01", "--today", "2026-10-06"])
        self.assertEqual(code, 0)
        self.assertIn("::warning::", out)

    def test_stale_exits_one_with_an_error_annotation(self):
        code, out = run(["--today", "2026-10-06"], '[{"rate_date":"2026-09-25"}]')
        self.assertEqual(code, 1)
        self.assertIn("::error::", out)

    def test_an_empty_reply_exits_one(self):
        code, out = run(["--today", "2026-10-06"], "[]")
        self.assertEqual(code, 1)
        self.assertIn("::error::", out)

    def test_an_unreadable_newest_argument_exits_one(self):
        code, _ = run(["--newest", "last tuesday", "--today", "2026-10-06"])
        self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
