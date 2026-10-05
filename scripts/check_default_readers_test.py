#!/usr/bin/env python3
"""Tests for check_default_readers.py.

The first version of the gate reported five findings and four were
WRONG -- `update ... set is_default = false`, the clear-the-old-default
half of a setter, where not filtering on liveness is the correct
behaviour. Those four are pinned here as must-not-report, because a gate
that flags correct code is a gate somebody turns off, and the shape is
easy to reintroduce while "tightening" the pattern.
"""
from __future__ import annotations

import unittest

import check_default_readers as gate


class Judge(unittest.TestCase):
    def test_a_bare_single_row_pick_is_reported(self):
        self.assertTrue(gate.judge(
            "select id into v_x from public.warehouses "
            "where org_id = p_org and is_default limit 1;", 'warehouses'))

    def test_a_bare_pick_with_no_limit_is_reported_too(self):
        # `select ... into` takes the first row whether it says so or not.
        self.assertTrue(gate.judge(
            "select id into v_x from public.warehouses "
            "where org_id = p_org and is_default;", 'warehouses'))

    def test_asking_is_active_clears_it(self):
        self.assertFalse(gate.judge(
            "select id into v_x from public.warehouses where org_id = p_org "
            "and is_default and is_active limit 1;", 'warehouses'))

    def test_asking_deleted_at_clears_it_too(self):
        # payment_methods uses this instead, because a method can be
        # switched off without being deleted.
        self.assertFalse(gate.judge(
            "select charge_account_id into v_id from public.payment_methods "
            "where org_id = p_org_id and is_default and deleted_at is null;",
            'payment_methods'))

    def test_clearing_the_old_default_is_not_judged(self):
        # The four false positives of the first run, one shape.
        self.assertFalse(gate.judge(
            "update public.tax_codes set is_default = false "
            "where org_id = p_org_id and is_default;", 'tax_codes'))

    def test_clearing_scoped_to_an_outlet_is_not_judged_either(self):
        self.assertFalse(gate.judge(
            "update public.pos_kitchen_stations st set is_default = false "
            "where st.outlet_id = p_outlet and st.is_default", 
            'pos_kitchen_stations'))

    def test_a_table_it_does_not_name_is_ignored(self):
        self.assertFalse(gate.judge(
            "select id into v_x from public.warehouses "
            "where org_id = p_org and is_default limit 1;", 'branches'))

    def test_a_pick_that_does_not_mention_is_default_is_ignored(self):
        self.assertFalse(gate.judge(
            "select id into v_x from public.warehouses "
            "where org_id = p_org and is_active limit 1;", 'warehouses'))

    def test_case_and_whitespace_do_not_matter(self):
        self.assertTrue(gate.judge(
            "SELECT id\n  INTO v_x\n  FROM public.warehouses\n"
            " WHERE org_id = p_org\n   AND is_default\n LIMIT 1;",
            'warehouses'))


class Constrained(unittest.TestCase):
    def test_the_repository_names_the_two_tables_0742_constrained(self):
        self.assertEqual(gate.constrained(), {'warehouses', 'pipelines'})


class Scope(unittest.TestCase):
    """The scope is DERIVED, because the hand-kept version was wrong.

    It named `contact_addresses`, which has no liveness column and so
    cannot have this bug, and omitted `pos_modifiers`, which does. Two
    errors in fourteen entries, written and found inside an hour. These
    tests pin the derivation against what the live catalogue reports, so
    the list cannot silently go stale again.
    """

    def test_it_derives_the_fourteen_the_catalogue_reports(self):
        self.assertEqual(sorted(gate.in_scope()), [
            'bank_accounts', 'branches', 'payment_methods', 'payment_terms',
            'pipelines', 'pos_kitchen_stations', 'pos_modifiers',
            'pos_outlet_channels', 'price_levels', 'sla_policies',
            'tax_codes', 'ticket_teams', 'warehouses', 'work_shifts'])

    def test_pos_modifiers_is_in_scope(self):
        # The one the hand-kept list omitted.
        self.assertIn('pos_modifiers', gate.in_scope())

    def test_a_table_with_no_liveness_column_is_out_of_scope(self):
        # contact_addresses, contact_persons, item_barcodes and
        # ticket_team_members carry a singleton flag and nothing that can
        # make a row stale, so every row is live and no reader can pick a
        # second one by accident.
        for table in ('contact_addresses', 'contact_persons',
                      'item_barcodes', 'ticket_team_members'):
            self.assertNotIn(table, gate.in_scope(), table)

    def test_scope_is_computed_from_columns_not_a_literal(self):
        made_up = {'a_new_table': {'org_id', 'is_default', 'is_active'},
                   'no_liveness': {'org_id', 'is_default'},
                   'no_flag': {'org_id', 'is_active'}}
        self.assertEqual(gate.in_scope(made_up), {'a_new_table': 'is_default'})

    def test_is_primary_and_is_lead_are_recognised_as_flags(self):
        self.assertEqual(
            gate.in_scope({'t': {'is_primary', 'is_active'}}),
            {'t': 'is_primary'})
        self.assertEqual(
            gate.in_scope({'u': {'is_lead', 'deleted_at'}}),
            {'u': 'is_lead'})


class Offenders(unittest.TestCase):
    def test_head_is_clean(self):
        self.assertEqual(gate.offenders(), [])

    def test_dropping_0742s_check_reports_the_thirteen(self):
        # The regression this gate exists to refuse: the CHECK goes, the
        # bare readers stay, and nothing else notices.
        bad = gate.offenders(allowed=set())
        names = {line.split(' ')[0] for line in bad}
        self.assertIn('app.pos_deplete_recipes', names)
        self.assertIn('public.complete_pos_sale', names)
        self.assertIn('app.post_sales_document_internal', names)
        self.assertGreaterEqual(len(names), 11)

    def test_a_new_bare_reader_on_an_unconstrained_table_is_reported(self):
        bad = gate.offenders(
            definitions={'app.brand_new': ('9999_x.sql',
                "select id into v_x from public.branches "
                "where org_id = p_org and is_default limit 1;")},
            allowed={'warehouses', 'pipelines'})
        self.assertEqual(len(bad), 1)
        self.assertIn('branches', bad[0])

    def test_a_bare_pick_on_a_table_out_of_scope_is_not_reported(self):
        # contact_addresses has no liveness column, so there is nothing to
        # ask about and nothing to report.
        bad = gate.offenders(
            definitions={'app.x': ('9999_x.sql',
                "select id into v_x from public.contact_addresses "
                "where contact_id = p_c and is_default limit 1;")},
            allowed=set())
        self.assertEqual(bad, [])

    def test_the_same_reader_is_fine_once_the_table_is_constrained(self):
        bad = gate.offenders(
            definitions={'app.brand_new': ('9999_x.sql',
                "select id into v_x from public.branches "
                "where org_id = p_org and is_default limit 1;")},
            allowed={'branches'})
        self.assertEqual(bad, [])


class Plumbing(unittest.TestCase):
    def test_it_reads_the_latest_definition_not_the_first(self):
        # calc_pcb is defined in 0446 and redefined in 0530 in UPPER CASE;
        # a case-sensitive grep for the lower-case form named 0446 and was
        # wrong by RM6,000 of relief.
        where, _ = gate.latest_definitions()['app.calc_pcb']
        self.assertTrue(where.startswith('05') or where > '0446',
                        f'latest calc_pcb came back as {where}')

    def test_it_found_a_plausible_number_of_functions(self):
        self.assertGreater(len(gate.latest_definitions()),
                           gate.LEAST_FUNCTIONS)

    def test_every_canary_is_reported_by_judge(self):
        for label, (snippet, table, flag) in gate.CANARIES.items():
            self.assertTrue(gate.judge(snippet, table, flag), label)

    def test_no_canary_names_a_constrained_table(self):
        # A canary on a table that has since been given the CHECK would
        # stop proving anything, silently.
        for label, (_, table, _flag) in gate.CANARIES.items():
            self.assertNotIn(table, gate.constrained(), label)

    def test_every_canary_names_a_table_still_in_scope(self):
        scope = gate.in_scope()
        for label, (_, table, _flag) in gate.CANARIES.items():
            self.assertIn(table, scope, label)

    def test_the_scope_floor_is_below_what_head_derives(self):
        self.assertGreaterEqual(len(gate.in_scope()), gate.LEAST_TABLES)

    def test_main_passes_at_head(self):
        self.assertEqual(gate.main(), 0)


if __name__ == '__main__':
    unittest.main()
