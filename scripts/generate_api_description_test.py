#!/usr/bin/env python3
"""Assertions for scripts/generate_api_description.py.

    python3 scripts/generate_api_description_test.py

The generator's output is published: it is what somebody building
against this database will believe. That makes its quiet failures the
expensive kind -- a description that is merely absent costs an hour,
and one that is confidently wrong costs a day and is not doubted until
late.

Three of those have already happened while writing it, and each is
pinned below:

  * **enums resolving to nothing.** `format_type` spells a type the way
    Postgres would print it -- `app.doc_status`, schema-qualified --
    and the first version keyed its enum table on the bare `typname`.
    Every one of the hundred-odd enums silently fell through to "a
    Postgres type", losing the labels, which are the most useful thing
    in the whole document: a caller guessing at a status gets 22P02 and
    no list of what would have been accepted.

  * **`numeric(12,2)` read as two columns.** `TABLE(...)` is split on
    commas, and a naive split cuts a precision in half and shifts every
    column after it by one. The result still looks like a schema.

  * **an optional argument called required.** PostgREST resolves an
    overload on the argument names it is given, so a description that
    demands an argument the function defaults is wrong in the direction
    that sends people to the wrong overload -- which, for `0307`'s four
    protected writes, is the *unprotected* one.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import generate_api_description as gen  # noqa: E402

ENUMS = {
    'app.doc_status': ['draft', 'posted', 'void'],
    'public.tone': ['good', 'bad'],
}
TABLES = frozenset({'organizations', 'invoices'})


class TypeMapping(unittest.TestCase):
    def test_scalars_cross_the_wire_as_json(self):
        # The storage type is not the point; the shape in the response
        # body is. `numeric` is a JSON number, `uuid` a string that says
        # how to read it.
        self.assertEqual(gen.schema_for('numeric', ENUMS), {'type': 'number'})
        self.assertEqual(
            gen.schema_for('uuid', ENUMS),
            {'type': 'string', 'format': 'uuid'})
        self.assertEqual(
            gen.schema_for('timestamp with time zone', ENUMS),
            {'type': 'string', 'format': 'date-time'})

    def test_a_length_is_not_a_json_schema_concern(self):
        # PostgREST does not enforce it at the door, so publishing it
        # would describe a constraint the API does not apply.
        self.assertEqual(
            gen.schema_for('character varying(64)', ENUMS),
            {'type': 'string'})

    def test_enums_resolve_however_format_type_spelled_them(self):
        # The bug this test exists for. `format_type` qualifies anything
        # off the search path, so the same enum arrives both ways
        # depending on where it is used.
        want = {'type': 'string', 'enum': ['draft', 'posted', 'void']}
        self.assertEqual(gen.schema_for('app.doc_status', ENUMS), want)
        self.assertEqual(gen.schema_for('doc_status', ENUMS), want)

    def test_an_enum_array_keeps_its_labels(self):
        self.assertEqual(
            gen.schema_for('app.doc_status[]', ENUMS),
            {'type': 'array',
             'items': {'type': 'string',
                       'enum': ['draft', 'posted', 'void']}})

    def test_a_table_type_points_at_the_row_already_described(self):
        self.assertEqual(
            gen.schema_for('organizations', ENUMS, TABLES),
            {'$ref': '#/components/schemas/organizations'})

    def test_an_unknown_type_admits_it_rather_than_guessing(self):
        # A wrong type in a published description is worse than an
        # absent one, because it is believed.
        out = gen.schema_for('some_composite', ENUMS, TABLES)
        self.assertNotIn('type', out)
        self.assertIn('some_composite', out['description'])


class SplittingColumns(unittest.TestCase):
    def test_plain_columns(self):
        self.assertEqual(
            gen.split_columns('a uuid, b text'),
            [('a', 'uuid'), ('b', 'text')])

    def test_a_precision_is_one_column_not_two(self):
        # The bug: a naive split makes `numeric(12` and `2)` and shifts
        # every column after it by one, and the result still looks like
        # a schema.
        self.assertEqual(
            gen.split_columns('amount numeric(12,2), note text'),
            [('amount', 'numeric(12,2)'), ('note', 'text')])

    def test_nested_brackets_survive(self):
        self.assertEqual(
            gen.split_columns('a numeric(12,2)[], b character varying(3)'),
            [('a', 'numeric(12,2)[]'), ('b', 'character varying(3)')])


def fn(**kw):
    base = dict(name='f', signature='', returns='void', returns_set=False,
                volatility='v', description=None, module=None,
                roles=['authenticated'], args=[])
    base.update(kw)
    return base


class Responses(unittest.TestCase):
    def test_returns_table_becomes_an_array_of_rows(self):
        out = gen.response_schema(fn(
            returns='TABLE(period_end date, output_tax numeric)',
            returns_set=True), ENUMS, TABLES)
        self.assertEqual(out['type'], 'array')
        self.assertEqual(
            out['items']['properties'],
            {'period_end': {'type': 'string', 'format': 'date'},
             'output_tax': {'type': 'number'}})

    def test_setof_a_table_is_an_array_of_that_row(self):
        out = gen.response_schema(fn(
            returns='SETOF organizations', returns_set=True), ENUMS, TABLES)
        self.assertEqual(
            out,
            {'type': 'array',
             'items': {'$ref': '#/components/schemas/organizations'}})

    def test_a_scalar_stays_a_scalar(self):
        self.assertEqual(
            gen.response_schema(fn(returns='uuid'), ENUMS, TABLES),
            {'type': 'string', 'format': 'uuid'})


class Operations(unittest.TestCase):
    def test_only_arguments_without_defaults_are_required(self):
        op = gen.operation(fn(
            name='report_sst_due',
            signature='p_org_id uuid, p_within_days integer',
            args=[{'name': 'p_org_id', 'type': 'uuid', 'optional': False},
                  {'name': 'p_within_days', 'type': 'integer',
                   'optional': True}],
            volatility='s',
            returns='TABLE(days_left integer)', returns_set=True),
            ENUMS, TABLES)
        body = op['requestBody']['content']['application/json']['schema']
        self.assertEqual(body['required'], ['p_org_id'])
        self.assertIn('p_within_days', body['properties'])

    def test_a_read_is_marked_as_one(self):
        self.assertEqual(
            gen.operation(fn(volatility='s'), ENUMS, TABLES)['x-volatility'],
            'stable')
        self.assertEqual(
            gen.operation(fn(volatility='v'), ENUMS, TABLES)['x-volatility'],
            'volatile')

    def test_a_write_says_so_where_a_person_will_read_it(self):
        op = gen.operation(fn(volatility='v'), ENUMS, TABLES)
        self.assertIn('Writes.', op['description'])

    def test_the_module_gate_is_stated(self):
        op = gen.operation(fn(module='pos'), ENUMS, TABLES)
        self.assertEqual(op['tags'], ['pos'])
        self.assertIn('`pos` module', op['description'])

    def test_an_ungated_function_is_not_invented_a_module(self):
        self.assertEqual(gen.operation(fn(), ENUMS, TABLES)['tags'],
                         ['general'])

    def test_anon_reachability_is_stated_plainly(self):
        signed_in = gen.operation(fn(), ENUMS, TABLES)
        self.assertIn('Requires a signed-in user', signed_in['description'])
        open_door = gen.operation(
            fn(roles=['anon', 'authenticated']), ENUMS, TABLES)
        self.assertIn('without signing in', open_door['description'])


class TheWholeDocument(unittest.TestCase):
    def setUp(self):
        self.tables = [{
            'name': 'organizations', 'kind': 'r', 'rls': True,
            'security_invoker': False, 'description': 'Companies.',
            'privileges': ['SELECT:authenticated'],
            'columns': [
                {'name': 'id', 'type': 'uuid', 'required': False},
                {'name': 'name', 'type': 'text', 'required': True}],
        }]

    def test_overloads_share_a_path_and_the_longest_one_wins(self):
        # PostgREST picks between overloads on the argument names it is
        # given, which OpenAPI has no way to say. Describing the short
        # one would point a caller at `0307`'s UNPROTECTED write.
        short = fn(name='create_deposit', signature='p_org uuid',
                   args=[{'name': 'p_org', 'type': 'uuid',
                          'optional': False}])
        long = fn(name='create_deposit',
                  signature='p_org uuid, p_idempotency_key text',
                  args=[{'name': 'p_org', 'type': 'uuid', 'optional': False},
                        {'name': 'p_idempotency_key', 'type': 'text',
                         'optional': False}])
        doc = gen.build_openapi([short, long], self.tables, ENUMS)
        body = (doc['paths']['/rpc/create_deposit']['post']['requestBody']
                ['content']['application/json']['schema'])
        self.assertIn('p_idempotency_key', body['properties'])
        op = doc['paths']['/rpc/create_deposit']['post']
        self.assertIn('x-overloads', op)
        # And said in the prose, not only in an extension most viewers
        # hide. This is the one subtlety in the document a reader must
        # not miss.
        self.assertIn('overloaded', op['description'])
        self.assertIn('unprotected original', op['description'])

    def test_a_not_null_column_with_a_default_is_not_required(self):
        # Every `id` and every `created_at` in this schema. Calling them
        # required is wrong in the direction that costs somebody an hour
        # of sending values the database was going to supply.
        doc = gen.build_openapi([], self.tables, ENUMS)
        schema = doc['components']['schemas']['organizations']
        self.assertEqual(schema['required'], ['name'])

    def test_every_local_ref_resolves(self):
        doc = gen.build_openapi(
            [fn(name='my_orgs', returns='SETOF organizations',
                returns_set=True)], self.tables, ENUMS)
        found = []

        def walk(node):
            if isinstance(node, dict):
                for k, v in node.items():
                    found.append(v) if k == '$ref' else walk(v)
            elif isinstance(node, list):
                for v in node:
                    walk(v)

        walk(doc)
        self.assertTrue(found)
        for ref in set(found):
            node = doc
            for part in ref.lstrip('#/').split('/'):
                self.assertIn(part, node, f'{ref} does not resolve')
                node = node[part]

    def test_the_version_is_the_schema_not_the_clock(self):
        # A timestamp would change on every run and make the CI drift
        # check useless.
        self.assertRegex(gen.schema_version(), r'^\d{4}$')
        self.assertEqual(gen.schema_version(), gen.schema_version())


class LlmsTxt(unittest.TestCase):
    def test_it_names_the_idempotent_writes(self):
        text = gen.llms_txt(
            [fn(name='create_deposit',
                signature='p_org uuid, p_idempotency_key text')],
            [], '0568')
        self.assertIn('`create_deposit`', text)

    def test_it_lists_what_needs_no_sign_in(self):
        text = gen.llms_txt(
            [fn(name='maintenance_notice', roles=['anon', 'authenticated'])],
            [], '0568')
        self.assertIn('Reachable without signing in', text)
        self.assertIn('`maintenance_notice`', text)

    def test_it_says_the_three_things_an_agent_gets_wrong(self):
        text = gen.llms_txt([fn()], [], '0568')
        # A company is an argument, a refusal is the rule, and a write
        # that must not repeat takes a key. The JSON shape is the
        # OpenAPI's job; these three are not in it.
        self.assertIn('company is an argument', text)
        self.assertIn('refusal is the rule speaking', text)
        self.assertIn('Writes that must not repeat take a key', text)

    def test_a_view_with_invoker_rights_is_not_called_unprotected(self):
        # `v_lot_balances` is the specimen: RLS off, because a view has
        # none, and every policy underneath it still in force. Calling
        # that "no row-level security" would read as a hole.
        view = {'name': 'v_lot_balances', 'kind': 'v', 'rls': False,
                'security_invoker': True, 'description': None,
                'privileges': [], 'columns': []}
        text = gen.llms_txt([], [view], '0568')
        self.assertIn("caller's own rights", text)
        self.assertNotIn('no row-level security', text)

    def test_the_order_is_the_documents_not_the_servers(self):
        # The bug CI found on the first run after the drift check went
        # in. `order by` uses the SERVER's collation: the local cluster
        # is `C.UTF-8`, where `_` (0x5F) sorts before `s`, so
        # `applicant_stage_history` precedes `applicants`; Supabase's
        # Postgres collates the other way. Same schema, same line count,
        # different order -- a committed file that could never match the
        # one CI regenerated, failing for ever on a difference that
        # means nothing.
        #
        # So the shuffled input must produce the identical document.
        rows = [fn(name='applicants'), fn(name='applicant_stage_history'),
                fn(name='Apple'), fn(name='apple')]
        one = gen.llms_txt(gen.ordered(rows, 'name', 'signature'), [], '0568')
        two = gen.llms_txt(
            gen.ordered(list(reversed(rows)), 'name', 'signature'), [], '0568')
        self.assertEqual(one, two)
        # And it is codepoint order, which is the same on every machine:
        # `A` (0x41) before `a` (0x61), and `apple` before `applicant…`
        # because `e` < `i`. Not what a person would call alphabetical,
        # and that is the point -- it does not vary by locale.
        self.assertEqual(
            [r['name'] for r in gen.ordered(rows, 'name', 'signature')],
            ['Apple', 'apple', 'applicant_stage_history', 'applicants'])

    def test_a_table_list_is_ordered_the_same_way(self):
        tabs = [{'name': 'applicants', 'kind': 'r', 'rls': True,
                 'security_invoker': False, 'description': None,
                 'privileges': [], 'columns': []},
                {'name': 'applicant_stage_history', 'kind': 'r', 'rls': True,
                 'security_invoker': False, 'description': None,
                 'privileges': [], 'columns': []}]
        got = gen.llms_txt([], gen.ordered(tabs, 'name'), '0568')
        self.assertLess(got.index('`applicant_stage_history`'),
                        got.index('`applicants`'))

    def test_it_admits_how_much_of_itself_is_only_a_name(self):
        # 436 of 658 functions in this schema carry no comment, and
        # their summary is a de-underscored name. A document that let
        # that read as complete would be the confidently-wrong kind:
        # somebody would take `add_fixed_public_holidays` at face value
        # and find out what it actually does from production.
        text = gen.llms_txt(
            [fn(name='a', description='Does a thing.'), fn(name='b')],
            [], '0568')
        self.assertIn('1 of 2 functions carry a `comment on', text)
        self.assertIn('nobody has written down yet', text)


if __name__ == '__main__':
    unittest.main(verbosity=1)
