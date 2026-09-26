#!/usr/bin/env python3
"""The route sweep's own assertions.

    python3 scripts/check_routes_test.py

A gate that is wrong is worse than no gate, because it is believed.

This one was wrong TWICE before it was committed, and both are asserted
below. The first version passed the very bug it was written for -- "No
page at /banking" -- and printed a confident `ok` while doing it.
"""
import importlib.util
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    'check_routes', Path(__file__).with_name('check_routes.py'))
sweep = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sweep)


class Nesting(unittest.TestCase):
    """A child's path is relative to its parent.

    THE FIRST VERSION PAIRED EVERY ABSOLUTE PATH WITH EVERY RELATIVE
    ONE. The router has a root route `/` and a child segment `:id`
    somewhere else entirely, so the cross-product invented `/:id` -- a
    single-segment route with a parameter, which matches ANY
    single-segment target. `/banking` matched it, the sweep printed
    `ok`, and the bug it existed to catch walked straight past.
    """

    def test_a_child_hangs_off_its_parent(self):
        src = """
        GoRoute(
          path: '/hr/people',
          routes: [
            GoRoute(path: 'new', builder: x),
          ],
        )
        """
        self.assertEqual(sweep.declared_routes(src),
                         {'/hr/people', '/hr/people/new'})

    def test_and_not_off_somebody_else(self):
        src = """
        GoRoute(path: '/', builder: x),
        GoRoute(
          path: '/hr/people',
          routes: [GoRoute(path: ':id', builder: x)],
        )
        """
        routes = sweep.declared_routes(src)
        self.assertIn('/hr/people/:id', routes)
        # The invented route that made the first version useless.
        self.assertNotIn('/:id', routes)


class Comments(unittest.TestCase):
    """An apostrophe in a comment is not a string literal.

    THE SECOND VERSION scanned for brackets while skipping strings, and
    treated the `'` in "the company's own page" as opening one. It then
    ran to the next quote mark and swallowed the code between -- which
    hid seventeen real routes, including `/` itself, and turned the
    sweep into a list of false alarms.
    """

    def test_an_apostrophe_in_a_line_comment_hides_nothing(self):
        src = """
        // the company's own front page
        GoRoute(path: '/', builder: x),
        GoRoute(path: '/demo', builder: x),
        """
        self.assertEqual(sweep.declared_routes(src), {'/', '/demo'})

    def test_and_neither_does_one_in_a_block_comment(self):
        src = """
        /* somebody's note */
        GoRoute(path: '/demo', builder: x),
        """
        self.assertIn('/demo', sweep.declared_routes(src))


class Matching(unittest.TestCase):
    def test_a_parameter_takes_any_one_segment(self):
        self.assertTrue(sweep.matches('/hr/payslip/abc', '/hr/payslip/:id'))

    def test_but_not_two(self):
        self.assertFalse(sweep.matches('/hr/payslip/a/b', '/hr/payslip/:id'))

    def test_an_interpolated_segment_is_some_value(self):
        # `context.go('/hr/people/${employee.id}')` is a real call and
        # the id is not knowable here.
        self.assertTrue(
            sweep.matches('/hr/people/${employee.id}', '/hr/people/:id'))

    def test_a_wrong_name_is_still_wrong(self):
        self.assertFalse(sweep.matches('/banking', '/bank-statements'))

    def test_the_root_matches_only_the_root(self):
        self.assertTrue(sweep.matches('/', '/'))
        self.assertFalse(sweep.matches('/banking', '/'))


class TheRealRouter(unittest.TestCase):
    """And it parses the router this repository actually has.

    A parser that silently matched nothing would pass every file in the
    app, so the count is asserted too -- that is the check the sweep
    itself makes before it reports anything.
    """

    def test_the_router_yields_a_plausible_number_of_routes(self):
        src = (Path(__file__).resolve().parent.parent
               / 'app/lib/src/core/router.dart').read_text()
        routes = sweep.declared_routes(src)
        self.assertGreater(len(routes), 100)
        for want in ('/', '/demo', '/reconcile', '/bank-statements',
                     '/smartscan', '/share/:token', '/sales/:docType'):
            self.assertIn(want, routes)
        self.assertNotIn('/banking', routes)


if __name__ == '__main__':
    unittest.main()
