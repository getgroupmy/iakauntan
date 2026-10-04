#!/usr/bin/env python3
"""The money-column gate's own assertions.

    python3 scripts/check_money_is_numeric_test.py

Beside `check_document_types_test.py`, `check_orphan_columns_test.py`
and the rest, for the reason they all give: a gate that is wrong is
worse than no gate, because it is believed.

This one earns its keep for a specific reason. The gate passes on this
repository today and will pass on it for a long time, because every
money column really is numeric. A gate whose only observed behaviour is
"passes" is indistinguishable from a gate that parses nothing at all --
and this project has shipped that exact bug twice, in
`check_async_skeletons.py` (a type-argument regex that stopped at the
first `>`, so it swept clean over five bare call sites) and in the
`ref_currencies` seed reader that would have read an empty list. So the
first assertion below is that it FINDS things, and the rest are that it
catches what it claims to.
"""
import contextlib
import importlib.util
import io
import pathlib
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    'check_money_is_numeric',
    Path(__file__).with_name('check_money_is_numeric.py'))
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


def run(**patch):
    """Run `main` with some of the module's globals replaced.

    `LEAST_MONEY_COLUMNS` defaults to 0 here because every case below
    feeds a MIGRATIONS directory of one or two files, and the gate's real
    floor is 250 -- a floor over a two-file fixture is not a positive
    control, it is a broken test. `TheFloorItself` passes it explicitly.
    """
    patch.setdefault("LEAST_MONEY_COLUMNS", 0)
    saved = {k: getattr(gate, k) for k in patch}
    for k, v in patch.items():
        setattr(gate, k, v)
    try:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = gate.main()
        return code, out.getvalue()
    finally:
        for k, v in saved.items():
            setattr(gate, k, v)


class ItActuallyReadsColumns(unittest.TestCase):
    """The assertions that stop a clean sweep over nothing."""

    def test_the_real_migrations_parse_to_something_plausible(self):
        # If this number is ever 0, every other assertion in this file is
        # theatre and the gate is passing because it sees nothing.
        total = 0
        money = 0
        for path in sorted(gate.MIGRATIONS.glob("*.sql")):
            sql = gate.strip_comments(path.read_text())
            for column, _rest in gate.declarations(sql):
                total += 1
                if gate.is_money_name(column):
                    money += 1
        self.assertGreater(total, 2000, "the column parser found almost "
                                        "nothing -- it is broken")
        self.assertGreater(money, 200, "no money-shaped columns found, so "
                                       "the name test matches nothing")

    def test_it_finds_a_known_real_column(self):
        # `expenses` is declared in 0006 with three numeric money columns.
        sql = gate.strip_comments(
            (gate.MIGRATIONS / "0006_purchases_inventory.sql").read_text())
        names = {c for c, _ in gate.declarations(sql)}
        for known in ("amount", "tax_amount", "total_amount"):
            self.assertIn(known, names)

    def test_numeric_with_a_scale_is_not_cut_in_half(self):
        # Reading a create-table body to the first `)` would stop inside
        # `numeric(18, 2)` and lose every column after the first one that
        # has a precision.
        sql = """
        create table public.t (
          id uuid primary key,
          amount numeric(18, 2) not null,
          total_amount numeric(18, 2) not null
        );
        """
        names = [c for c, _ in gate.declarations(sql)]
        self.assertEqual(names, ["id", "amount", "total_amount"])


class WhatItCatches(unittest.TestCase):
    def _fails_on(self, sql: str, tmp_path: Path) -> tuple[int, str]:
        (tmp_path / "0001_x.sql").write_text(sql)
        return run(MIGRATIONS=tmp_path)

    def setUp(self):
        import tempfile
        self._dir = tempfile.TemporaryDirectory()
        self.tmp = Path(self._dir.name)
        self.addCleanup(self._dir.cleanup)

    def test_a_double_precision_money_column_fails(self):
        code, said = self._fails_on(
            "create table public.t (\n"
            "  id uuid primary key,\n"
            "  total_amount double precision not null\n"
            ");\n", self.tmp)
        self.assertEqual(code, 1)
        self.assertIn("total_amount", said)

    def test_real_and_float_spellings_all_fail(self):
        for spelling in ("real", "float", "float8", "float4",
                         "double precision", "float(24)"):
            with self.subTest(spelling=spelling):
                code, _ = self._fails_on(
                    f"create table public.t (\n  balance {spelling} not null\n);\n",
                    self.tmp)
                self.assertEqual(code, 1, f"{spelling} was not caught")

    def test_an_added_column_is_caught_too(self):
        # Most money columns since 0006 arrived by `alter table`, so a
        # gate that only read `create table` would cover the oldest
        # migrations and none of the recent ones.
        code, said = self._fails_on(
            "alter table public.expenses\n"
            "  add column if not exists service_charge_amount real;\n",
            self.tmp)
        self.assertEqual(code, 1)
        self.assertIn("service_charge_amount", said)

    def test_numeric_passes(self):
        code, _ = self._fails_on(
            "create table public.t (\n"
            "  total_amount numeric(18, 2) not null default 0\n"
            ");\n", self.tmp)
        self.assertEqual(code, 0)

    def test_a_float_that_is_not_money_passes(self):
        # A quantity, a percentage, a confidence score. Not this gate's
        # business, and flagging them would make it noise somebody turns
        # off.
        code, _ = self._fails_on(
            "create table public.t (\n"
            "  quantity double precision,\n"
            "  confidence real,\n"
            "  latitude double precision\n"
            ");\n", self.tmp)
        self.assertEqual(code, 0)

    def test_prose_warning_against_a_float_is_not_a_declaration(self):
        # Several migrations here explain at length why money is numeric.
        # A gate that read comments would fail on the migration that
        # exists to prevent the thing it is describing.
        code, _ = self._fails_on(
            "-- total_amount double precision would store the error\n"
            "/* balance real is wrong for the same reason */\n"
            "create table public.t (\n"
            "  total_amount numeric(18, 2)\n"
            ");\n", self.tmp)
        self.assertEqual(code, 0)

    def test_a_table_constraint_is_not_read_as_a_column(self):
        code, _ = self._fails_on(
            "create table public.t (\n"
            "  total_amount numeric(18, 2),\n"
            "  check (total_amount >= 0),\n"
            "  unique (total_amount)\n"
            ");\n", self.tmp)
        self.assertEqual(code, 0)


class TheAllowanceList(unittest.TestCase):
    def setUp(self):
        import tempfile
        self._dir = tempfile.TemporaryDirectory()
        self.tmp = Path(self._dir.name)
        self.addCleanup(self._dir.cleanup)

    def test_an_allowed_float_passes(self):
        (self.tmp / "0001_x.sql").write_text(
            "create table public.t (\n  pay_rate real\n);\n")
        code, _ = run(MIGRATIONS=self.tmp,
                      ALLOWED={("0001_x", "pay_rate"): "an hourly rate"})
        self.assertEqual(code, 0)

    def test_an_allowance_that_matches_nothing_fails(self):
        # The staleness rule. Without it the list silently becomes a
        # backlog of columns that no longer exist.
        (self.tmp / "0001_x.sql").write_text(
            "create table public.t (\n  total_amount numeric(18, 2)\n);\n")
        code, said = run(MIGRATIONS=self.tmp,
                         ALLOWED={("0001_x", "gone_away"): "renamed in 0002"})
        self.assertEqual(code, 1)
        self.assertIn("gone_away", said)

    def test_the_repository_itself_passes(self):
        # The gate's claim about the state of this database, asserted
        # rather than assumed.
        code, said = run()
        self.assertEqual(code, 0, said)

class TheFloorItself(unittest.TestCase):
    """The gate used to pass over an empty `supabase/migrations`, printing
    "every money column is numeric (0 migrations, 0 allowed floats)". The
    number was in the output and nothing compared it.

    `ItActuallyReadsColumns` above already said the right thing -- "if
    this number is ever 0, every other assertion in this file is theatre"
    -- so the instinct was in the TEST and not in the GATE, and CI only
    held because the two run together. That is a weaker arrangement than
    it reads.
    """

    def test_an_empty_migrations_directory_is_refused(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            code, _ = run(MIGRATIONS=pathlib.Path(tmp),
                          LEAST_MONEY_COLUMNS=250)
        self.assertEqual(code, 2)

    def test_the_real_tree_clears_the_shipped_floor(self):
        _, matched, money = gate.offenders()
        self.assertGreaterEqual(money, gate.LEAST_MONEY_COLUMNS)

    def test_the_floor_is_below_the_census_but_not_at_zero(self):
        """At zero it is not a floor; at the census it goes red whenever a
        column is renamed."""
        _, _, money = gate.offenders()
        self.assertGreater(gate.LEAST_MONEY_COLUMNS, 0)
        self.assertLess(gate.LEAST_MONEY_COLUMNS, money)

    def test_the_success_line_reports_the_census(self):
        code, said = run()
        self.assertEqual(code, 0, said)
        self.assertIn("money-named columns", said)


if __name__ == "__main__":
    unittest.main(verbosity=2)

