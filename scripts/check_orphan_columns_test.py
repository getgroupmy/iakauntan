#!/usr/bin/env python3
"""The orphan-column sweep's own assertions.

    python3 scripts/check_orphan_columns_test.py

`dependency_audit_test.py`, `generate_api_description_test.py`,
`sql_call_graph_test.py` and `mutate_test.py` are here for the same
reason: a gate that is wrong is worse than no gate, because it is
believed.

This one was wrong twice before it was committed, and both are asserted
below.
"""
import importlib.util
import sys
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    'check_orphan_columns', Path(__file__).with_name('check_orphan_columns.py'))
sweep = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sweep)


class Counting(unittest.TestCase):
    """Occurrences, not files -- and that is the whole accuracy of it.

    The first version asked whether a column's name appeared in more
    than one FILE. A column created and used in the same migration --
    `pos_kitchen_tickets.ready_at`, set by a function written below its
    own `create table` -- appears in exactly one file, so it was
    reported as reached by nothing. Twenty-seven of the thirty-five it
    reported were that, and a gate that is three-quarters noise is a
    gate somebody switches off.
    """

    def test_a_column_used_below_its_own_create_table_is_not_an_orphan(self):
        one_file = """
create table public.tickets (
  id uuid primary key,
  ready_at timestamptz
);

create function mark_ready(p_id uuid) returns void language sql as $$
  update public.tickets set ready_at = now() where id = p_id;
$$;
"""
        counts = sweep.tokens(one_file)
        self.assertEqual(counts['ready_at'], 2)

    def test_and_a_column_nothing_touches_appears_once(self):
        counts = sweep.tokens(
            'create table public.tickets (id uuid, served_at timestamptz);')
        self.assertEqual(counts['served_at'], 1)


class ProseIsNotAUse(unittest.TestCase):
    """A column named in the paragraph above its own declaration.

    This repository explains itself at length inside its migrations, so
    a sweep that counted commentary would clear half of what it looks
    for. `check_web_plugin_registrant.py` and
    `check_android_compile_sdk.py` each shipped once without stripping
    comments and each refused the very arrangement it existed to
    require.
    """

    DECLARED = """
-- `tourism_tax_reg_no` is the number RMCD issued. See tourism_tax_reg_no
-- above, and tourism_tax_reg_no again, because this file explains
-- itself.
create table public.organizations (
  id uuid primary key,
  tourism_tax_reg_no text
);
"""

    def test_the_declaration_survives_the_strip(self):
        bare = sweep.strip_sql_comments(self.DECLARED)
        self.assertEqual(sweep.tokens(bare)['tourism_tax_reg_no'], 1)

    def test_and_the_commentary_does_not(self):
        self.assertEqual(
            sweep.tokens(self.DECLARED)['tourism_tax_reg_no'], 4)

    def test_a_block_comment_goes_too(self):
        bare = sweep.strip_sql_comments(
            '/* about is_inclusive */ create table t (is_inclusive bool);')
        self.assertEqual(sweep.tokens(bare)['is_inclusive'], 1)


class WhichFileDeclaresWhat(unittest.TestCase):
    """`declarers`, which reads the table name out of the statement."""

    FILES = [
        (Path('a.sql'), 'create table public.notes (id uuid, is_pinned bool);'),
        (Path('b.sql'), 'alter table public.notes add column pinned_by uuid;'),
        (Path('c.sql'), 'select is_pinned from public.notes;'),
        (Path('d.sql'), 'create table if not exists leads (id uuid);'),
    ]

    def test_a_create_and_an_alter_both_declare(self):
        found = sweep.declarers(self.FILES)
        self.assertEqual(found['notes'], {0, 1})

    def test_a_select_does_not(self):
        self.assertNotIn(2, sweep.declarers(self.FILES)['notes'])

    def test_if_not_exists_is_read_through(self):
        self.assertEqual(sweep.declarers(self.FILES)['leads'], {3})


class EveryExemptionSaysWhy(unittest.TestCase):
    """The entry IS the reason. A name without one is a column hidden."""

    def test_each_entry_carries_a_sentence(self):
        for name, reason in sweep.EXEMPT.items():
            self.assertTrue(reason and len(reason) > 20,
                            f'{name} is exempt without a reason')

    def test_the_four_lists_do_not_overlap(self):
        # A column in two lists is two verdicts, and the next person
        # reads whichever they find first.
        lists = [sweep.DELIBERATE, sweep.SUPERSEDED,
                 sweep.WHOLE_TABLE_UNREACHED, sweep.KNOWN_GAPS]
        seen: set[str] = set()
        for one in lists:
            self.assertFalse(seen & set(one),
                             f'named twice: {seen & set(one)}')
            seen |= set(one)

    def test_a_known_gap_says_what_closing_it_needs(self):
        # The reason a gap stays open is that nobody remembers what
        # closing it involved.
        for name, reason in sweep.KNOWN_GAPS.items():
            self.assertTrue(len(reason) > 30,
                            f'{name} does not say what closing it needs')


class AgainstThisRepository(unittest.TestCase):
    """The live run, which is what CI does."""

    def test_the_description_is_there_and_has_columns(self):
        cols = sweep.columns()
        self.assertGreater(len(cols), 300)
        self.assertIn('is_inclusive', cols['tax_codes'])

    def test_the_two_columns_this_sweep_found_are_reached_now(self):
        # 0641 and 0642. If either is reported again, something was
        # reverted and this says which.
        cols = sweep.columns()
        self.assertIn('tourism_tax_reg_no', cols['organizations'])
        self.assertNotIn('tax_codes.is_inclusive', sweep.EXEMPT)
        self.assertNotIn('organizations.tourism_tax_reg_no', sweep.EXEMPT)

    def test_the_sweep_passes(self):
        self.assertEqual(sweep.main(), 0)

    def test_and_refuses_a_column_nothing_is_wired_to(self):
        # The gate's actual job, proved rather than assumed: a column
        # in the description that nothing in the tree names.
        #
        # The probe's name is BUILT rather than written, and the first
        # version of this test is why. `scripts/*.py` is in the corpus
        # this sweep reads, so a literal `'a_column_nobody_wired'` in
        # this file is two mentions of that column -- the probe made
        # itself reachable and the gate correctly cleared it. Exactly
        # the trap the comment-stripping exists for, one layer out.
        import contextlib
        import io

        probe = '_'.join(['probe', 'column', 'nothing', 'names'])
        real = sweep.columns
        try:
            sweep.columns = lambda: {
                **real(),
                'tax_codes': real()['tax_codes'] + [probe],
            }
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                code = sweep.main()
        finally:
            sweep.columns = real

        self.assertEqual(code, 1)
        self.assertIn(f'tax_codes.{probe}', err.getvalue())

    def test_and_refuses_an_entry_for_a_column_that_is_reached_now(self):
        # Somebody wires a column up and leaves the entry behind. Then
        # the file reads as a list of what is missing while describing
        # something that is not, which is worse than silence: the next
        # person believes it.
        #
        # `tax_codes.is_inclusive` is the specimen for a reason -- it
        # WAS an orphan until 0641, so a stale claim about it is the
        # exact mistake this catches.
        #
        # The first version of this check compared against the reported
        # list, which has the exemptions already filtered out of it, so
        # every exempted column looked wired up and all thirteen were
        # reported at once.
        import contextlib
        import io

        reason = 'a stale claim that this is unreached, long enough to pass'
        sweep.DELIBERATE['tax_codes.is_inclusive'] = reason
        sweep.EXEMPT['tax_codes.is_inclusive'] = reason
        try:
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                code = sweep.main()
        finally:
            del sweep.DELIBERATE['tax_codes.is_inclusive']
            del sweep.EXEMPT['tax_codes.is_inclusive']

        self.assertEqual(code, 1)
        self.assertIn('reached by something now', err.getvalue())

    def test_and_refuses_an_exemption_for_a_column_that_is_gone(self):
        # An exemption hiding nothing rots quietly.
        import contextlib
        import io

        gone = 'tax_codes.' + '_'.join(['column', 'since', 'dropped'])
        reason = 'a reason long enough to pass the assertion above this one'
        sweep.DELIBERATE[gone] = reason
        sweep.EXEMPT[gone] = reason
        try:
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                code = sweep.main()
        finally:
            del sweep.DELIBERATE[gone]
            del sweep.EXEMPT[gone]

        self.assertEqual(code, 1)
        self.assertIn('no longer a column', err.getvalue())


if __name__ == '__main__':
    sys.exit(unittest.main(verbosity=2))
