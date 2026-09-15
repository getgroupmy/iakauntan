#!/usr/bin/env python3
"""Assertions for scripts/sql_call_graph.py.

    python3 scripts/sql_call_graph_test.py

`check_stable_writers.py` fails a build when this module says a
function writes, and a gate is only as honest as what it reads. The
cases below are the ones that were wrong before they were pinned, and
every one of them was wrong in the SAME direction: a write the scanner
could not see, and so a gate that stayed quiet.

  * **`--` inside a refusal message.** `set_item_weighed` raises
    "... a unit that measures something -- a kilogram, a litre" and then
    updates `items`. Blanking comments before strings eats from that
    `--` to the end of the line, leaves an unmatched quote, and the
    string pass swallows the rest of the function. Three functions read
    as pure reads that way -- `set_item_weighed`, `import_accounts` and
    `platform_save_promotion` -- and all three plainly write.

  * **a trailing `\\b` across an alternation.** Written as
    `\\b(insert into|update \\w|...)\\b`, the final boundary has to hold
    after the last character matched -- so `update p` of
    `update public.items` fails, because `p` and `u` are both word
    characters. Every `update` in the schema went unseen and the check
    reported a clean database.

  * **a write four hops down.** Half this schema is a thin wrapper over
    an `_internal` writer. A caller whose own body mentions nothing
    that writes is the normal case, not the exception.
"""
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from sql_call_graph import clean, writes_in_body, mark_writers  # noqa: E402


class Clean(unittest.TestCase):
    def test_comment_goes(self):
        self.assertNotIn('secret', clean('select 1; -- secret\nselect 2;'))

    def test_string_goes(self):
        self.assertNotIn('secret', clean("select 'secret';"))

    def test_a_dash_dash_inside_a_string_is_not_a_comment(self):
        # The one that made this a scanner. Everything after the
        # message must survive.
        body = (
            "begin\n"
            "  raise exception 'needs a unit -- a kilogram, a litre';\n"
            "  update public.items set is_weighed = true;\n"
            "end")
        self.assertIn('update public.items', clean(body))

    def test_doubled_quote_does_not_end_the_string(self):
        body = "begin\n  raise exception 'the company''s own -- books';\n" \
               "  delete from public.items;\nend"
        self.assertIn('delete from public.items', clean(body))

    def test_dollar_quoted_body_is_blanked(self):
        self.assertNotIn('secret', clean("execute $q$ select 'secret' $q$;"))

    def test_nested_block_comments(self):
        # Postgres nests them; Python's `str.find('*/')` alone does not.
        body = 'select 1; /* outer /* inner */ still comment */ update x set a=1;'
        out = clean(body)
        self.assertNotIn('inner', out)
        self.assertIn('update x', out)


class Verbs(unittest.TestCase):
    def test_update_of_a_qualified_table(self):
        self.assertTrue(writes_in_body('update public.items set a = 1;'))

    def test_update_of_a_bare_table(self):
        self.assertTrue(writes_in_body('update items set a = 1;'))

    def test_insert_delete_truncate(self):
        for body in ('insert into x (a) values (1);',
                     'delete from x where a = 1;',
                     'truncate x;'):
            self.assertTrue(writes_in_body(body), body)

    def test_a_write_inside_a_cte(self):
        self.assertTrue(writes_in_body(
            'with moved as (insert into x select * from y returning id) '
            'select count(*) from moved;'))

    def test_a_sequence_is_a_write(self):
        self.assertTrue(writes_in_body("select nextval('s');"))

    def test_a_plain_read_is_not(self):
        for body in ('select a from x where b = 1 order by a;',
                     'select count(*) from x join y on y.id = x.y_id;',
                     "return query select a, b from x where c = 'updated';"):
            self.assertFalse(writes_in_body(body), body)

    def test_the_word_update_in_prose_is_not_a_write(self):
        self.assertFalse(writes_in_body(
            '-- this does not update anything\nselect 1;'))

    def test_a_column_called_updated_at_is_not_a_write(self):
        self.assertFalse(writes_in_body('select updated_at from x;'))


def _fn(name, src, sch='public', vol='v'):
    return {'sch': sch, 'name': name, 'args': '', 'vol': vol, 'kind': 'f',
            'src': src, 'reachable': True, 'ext': False,
            'clean': clean(src), 'self_writes': writes_in_body(src),
            'signature': f'{sch}.{name}()'}


class Reachability(unittest.TestCase):
    def test_a_direct_write(self):
        rows = [_fn('w', 'update public.items set a = 1;')]
        self.assertTrue(mark_writers(rows)[0])

    def test_one_hop(self):
        rows = [_fn('outer', 'perform app.inner(p);'),
                _fn('inner', 'update public.items set a = 1;', sch='app')]
        self.assertTrue(mark_writers(rows)[0])

    def test_four_hops(self):
        rows = [_fn('a', 'perform b();'), _fn('b', 'perform c();'),
                _fn('c', 'perform d();'),
                _fn('d', 'update public.items set a = 1;')]
        self.assertTrue(mark_writers(rows)[0])

    def test_a_chain_of_reads_stays_a_read(self):
        rows = [_fn('a', 'return b();'), _fn('b', 'return c();'),
                _fn('c', 'select 1;')]
        self.assertFalse(mark_writers(rows)[0])

    def test_a_cycle_terminates(self):
        # Two functions that call each other, neither writing. The
        # fixed point must stop rather than spin.
        rows = [_fn('a', 'return b();'), _fn('b', 'return a();')]
        self.assertFalse(mark_writers(rows)[0])

    def test_a_cycle_that_reaches_a_write(self):
        rows = [_fn('a', 'return b();'), _fn('b', 'perform a(); perform w();'),
                _fn('w', 'delete from public.items;')]
        marked = mark_writers(rows)
        self.assertTrue(marked[0])
        self.assertTrue(marked[1])

    def test_an_overload_that_writes_taints_the_name(self):
        # `record_pdc` has two overloads and only one is protected.
        # The graph keys on the NAME, so the writing sibling counts --
        # conservative, and the safe direction for a gate that fails.
        rows = [_fn('caller', 'perform twin();'),
                _fn('twin', 'select 1;'),
                _fn('twin', 'insert into public.items (a) values (1);')]
        self.assertTrue(mark_writers(rows)[0])

    def test_a_name_this_database_does_not_have_is_not_a_call(self):
        rows = [_fn('a', 'select coalesce(x, 0), count(*) from t;')]
        self.assertFalse(mark_writers(rows)[0])

    def test_recursion_on_itself_is_not_a_call_to_a_writer(self):
        rows = [_fn('a', 'if n > 0 then return a(n - 1); end if; select 1;')]
        self.assertFalse(mark_writers(rows)[0])


if __name__ == '__main__':
    unittest.main(verbosity=2)
