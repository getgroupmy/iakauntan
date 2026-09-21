#!/usr/bin/env python3
"""The nested-scrollable gate's own assertions.

    python3 scripts/check_nested_scrollables_test.py

Beside `check_screens_built_test.py` and the rest, for the reason they
all give: a gate that is wrong is worse than no gate, because it is
believed.

The ways THIS one could lie are all about what it does not look
through. It reads Dart with a regular expression and a paren counter,
so it has no idea what an identifier means -- and the three things it
must not do are pair an outer with an inner on a DIFFERENT axis (that
is a carousel), pair across a boundary that re-bounds the axis (a
`SizedBox(width:)`, a `shrinkWrap`), and count a widget named in a
comment or a string. The last one is not hypothetical here: this
repository explains itself in prose, and the gate's own file names
every widget it looks for, many times.

The real tree is asserted too, so the script cannot pass by finding
nothing because it looked in the wrong place.
"""
import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    'check_nested_scrollables',
    Path(__file__).with_name('check_nested_scrollables.py'))
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)

REAL_APP = gate.APP


def run_on(files: dict[str, str]):
    """Run `main` over a made-up app, returning (code, output)."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for name, body in files.items():
            path = root / 'lib' / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body)
        saved = gate.APP
        gate.APP = root
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = gate.main()
            return code, out.getvalue()
        finally:
            gate.APP = saved


class SameAxis(unittest.TestCase):
    def test_a_horizontal_list_inside_a_horizontal_scroll_view_is_refused(self):
        code, out = run_on({'a.dart': '''
Widget build() => SingleChildScrollView(
  scrollDirection: Axis.horizontal,
  child: ListView(scrollDirection: Axis.horizontal, children: []),
);
'''})
        self.assertEqual(code, 1)
        self.assertIn('ListView', out)
        self.assertIn('unbounded width', out)

    def test_a_vertical_list_inside_a_vertical_scroll_view_is_refused(self):
        # Both default to vertical, so neither names an axis. The
        # commonest way a Flutter screen throws.
        code, out = run_on({'a.dart': '''
Widget build() => SingleChildScrollView(
  child: ListView(children: []),
);
'''})
        self.assertEqual(code, 1)
        self.assertIn('unbounded height', out)

    def test_the_repository_wrapper_counts_as_the_scroll_view_it_is(self):
        # `FilterBar` is a horizontal SingleChildScrollView underneath
        # and a caller cannot see that. This is the shipped defect.
        code, out = run_on({'a.dart': '''
Widget build() => FilterBar(
  child: ListView(scrollDirection: Axis.horizontal, children: []),
);
'''})
        self.assertEqual(code, 1)
        self.assertIn('FilterBar', out)


class DifferentAxis(unittest.TestCase):
    def test_a_horizontal_list_inside_a_vertical_one_is_a_carousel(self):
        code, _ = run_on({'a.dart': '''
Widget build() => ListView(
  children: [
    SizedBox(
      height: 120,
      child: ListView(scrollDirection: Axis.horizontal, children: []),
    ),
  ],
);
'''})
        self.assertEqual(code, 0)

    def test_and_a_vertical_one_inside_a_horizontal_one(self):
        code, _ = run_on({'a.dart': '''
Widget build() => SingleChildScrollView(
  scrollDirection: Axis.horizontal,
  child: ListView(children: []),
);
'''})
        self.assertEqual(code, 0)

    def test_a_PageView_defaults_to_horizontal_not_vertical(self):
        # The default axis differs by widget, and reading them all as
        # vertical would both miss real faults and invent fake ones.
        # A vertical list inside a PageView is ordinary.
        code, _ = run_on({'a.dart': '''
Widget build() => PageView(
  children: [ListView(children: [])],
);
'''})
        self.assertEqual(code, 0)

    def test_but_a_horizontal_list_inside_one_is_not(self):
        code, _ = run_on({'a.dart': '''
Widget build() => PageView(
  children: [ListView(scrollDirection: Axis.horizontal, children: [])],
);
'''})
        self.assertEqual(code, 1)


class BoundedAgain(unittest.TestCase):
    def test_a_fixed_width_between_them_makes_it_fine(self):
        code, _ = run_on({'a.dart': '''
Widget build() => SingleChildScrollView(
  scrollDirection: Axis.horizontal,
  child: SizedBox(
    width: 400,
    child: ListView(scrollDirection: Axis.horizontal, children: []),
  ),
);
'''})
        self.assertEqual(code, 0)

    def test_and_so_does_shrinkWrap_on_the_inner_one(self):
        code, _ = run_on({'a.dart': '''
Widget build() => SingleChildScrollView(
  child: ListView(shrinkWrap: true, children: []),
);
'''})
        self.assertEqual(code, 0)

    def test_a_fixed_height_does_not_rescue_the_horizontal_case(self):
        # Wrong axis: a height says nothing about the width the inner
        # viewport is offered. Accepting it would be the gate reading
        # any SizedBox at all as an escape hatch.
        code, _ = run_on({'a.dart': '''
Widget build() => SingleChildScrollView(
  scrollDirection: Axis.horizontal,
  child: SizedBox(
    height: 40,
    child: ListView(scrollDirection: Axis.horizontal, children: []),
  ),
);
'''})
        self.assertEqual(code, 1)


class ProseIsNotCode(unittest.TestCase):
    def test_a_line_comment_describing_the_nesting_is_not_the_nesting(self):
        code, _ = run_on({'a.dart': '''
// Not a ListView(scrollDirection: Axis.horizontal) inside a FilterBar(
Widget build() => Row(children: []);
'''})
        self.assertEqual(code, 0)

    def test_nor_a_doc_comment(self):
        code, _ = run_on({'a.dart': '''
/// Was a FilterBar( wrapping a ListView(scrollDirection: Axis.horizontal).
Widget build() => Row(children: []);
'''})
        self.assertEqual(code, 0)

    def test_nor_a_string(self):
        code, _ = run_on({'a.dart': '''
const help = 'A ListView( inside a FilterBar( throws.';
Widget build() => FilterBar(child: Row(children: []));
'''})
        self.assertEqual(code, 0)

    def test_but_a_comment_does_not_hide_real_code_after_it(self):
        # Comments are blanked to SPACES, not deleted, so offsets and
        # the line numbers computed from them stay true.
        code, out = run_on({'a.dart': '''
// A note about FilterBar(
Widget build() => FilterBar(
  child: ListView(scrollDirection: Axis.horizontal, children: []),
);
'''})
        self.assertEqual(code, 1)
        self.assertIn(':4', out)


class TheRealTree(unittest.TestCase):
    def test_the_repository_passes_its_own_gate(self):
        self.assertTrue((REAL_APP / 'lib').is_dir(), REAL_APP)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = gate.main()
        self.assertEqual(code, 0, out.getvalue())

    def test_and_the_gate_looked_at_more_than_nothing(self):
        # A `lib` that moved would make every assertion above pass by
        # finding no files at all.
        self.assertGreater(len(list((REAL_APP / 'lib').rglob('*.dart'))), 100)


if __name__ == '__main__':
    unittest.main(verbosity=2)
