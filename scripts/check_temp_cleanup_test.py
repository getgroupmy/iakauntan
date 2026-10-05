#!/usr/bin/env python3
"""Does the mkdtemp gate fire, and only when it should?

A gate nobody has broken on purpose is a gate nobody has tested. Each
case here is fed to the real `offenders()`, and the ones that must NOT
fire matter as much as the ones that must: this gate's failure mode is
nagging about a directory that is already removed, which gets a gate
deleted faster than one that misses a leak.
"""
from __future__ import annotations

import pathlib
import tempfile
import unittest

import importlib.util

_spec = importlib.util.spec_from_file_location(
    'check_temp_cleanup',
    pathlib.Path(__file__).resolve().parent / 'check_temp_cleanup.py')
gate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gate)


class Fed(unittest.TestCase):
    """Write a source file, run the gate over it, return what it said."""

    def verdict(self, body: str) -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            p = pathlib.Path(tmp) / 'subject.py'
            p.write_text(body)
            return gate.offenders([p])


class WhatMustFire(Fed):
    def test_a_bare_mkdtemp_is_reported(self):
        said = self.verdict(
            'import tempfile\n'
            'def build():\n'
            '    return tempfile.mkdtemp()\n')
        self.assertEqual(len(said), 1, said)
        self.assertIn('build()', said[0])
        self.assertIn('removes nothing', said[0])

    def test_the_real_shape_that_leaked_28_a_run(self):
        """Verbatim from dependency_audit_test.py before the fix."""
        said = self.verdict(
            'import os\n'
            'import tempfile\n'
            'def workspace(files):\n'
            '    root = tempfile.mkdtemp()\n'
            '    for path, body in files.items():\n'
            '        os.makedirs(os.path.dirname(path), exist_ok=True)\n'
            '    return root\n')
        self.assertEqual(len(said), 1, said)
        self.assertIn('workspace()', said[0])

    def test_a_removal_in_a_DIFFERENT_function_does_not_count(self):
        """The bug that made a plain grep miss two of the five leaks.

        Both check_web_boots.py and check_surface_size_test.py already
        contained the word `rmtree` somewhere else in the file, so a
        file-level search called them clean. The leak is per FUNCTION.
        """
        said = self.verdict(
            'import shutil\n'
            'import tempfile\n'
            'def leaks():\n'
            '    return tempfile.mkdtemp()\n'
            'def tidies_something_else(d):\n'
            '    shutil.rmtree(d, True)\n')
        self.assertEqual(len(said), 1, said)
        self.assertIn('leaks()', said[0])


class WhatMustNotFire(Fed):
    def test_atexit_register_passes_rmtree_without_calling_it(self):
        self.assertEqual(self.verdict(
            'import atexit\n'
            'import shutil\n'
            'import tempfile\n'
            'def build():\n'
            '    root = tempfile.mkdtemp()\n'
            '    atexit.register(shutil.rmtree, root, True)\n'
            '    return root\n'), [])

    def test_addCleanup_counts(self):
        self.assertEqual(self.verdict(
            'import shutil\n'
            'import tempfile\n'
            'class T:\n'
            '    def tree(self):\n'
            '        tmp = tempfile.mkdtemp()\n'
            '        self.addCleanup(shutil.rmtree, tmp, True)\n'
            '        return tmp\n'), [])

    def test_a_plain_rmtree_call_counts(self):
        self.assertEqual(self.verdict(
            'import shutil\n'
            'import tempfile\n'
            'def build():\n'
            '    tmp = tempfile.mkdtemp()\n'
            '    shutil.rmtree(tmp)\n'), [])

    def test_TemporaryDirectory_needs_nothing(self):
        self.assertEqual(self.verdict(
            'import tempfile\n'
            'def build():\n'
            '    with tempfile.TemporaryDirectory() as tmp:\n'
            '        return tmp\n'), [])

    def test_a_file_with_no_temp_directories_at_all(self):
        self.assertEqual(self.verdict('def f():\n    return 1\n'), [])

    def test_the_word_mkdtemp_in_a_STRING_is_not_a_call(self):
        """This gate reads the AST, so prose about mkdtemp is just prose.

        It has to be: check_temp_cleanup.py's own docstring discusses
        `mkdtemp` at length, and so does this file.
        """
        self.assertEqual(self.verdict(
            'def f():\n'
            '    """Do not call tempfile.mkdtemp() here."""\n'
            '    return "tempfile.mkdtemp()"\n'), [])


class TheFloor(unittest.TestCase):
    """A gate that looked at nothing must refuse, not pass.

    Two empty schema dumps once compared clean, and the thin-assertion
    gate needed the same guard. This is the cheapest version of it.
    """

    def test_main_refuses_when_it_can_barely_see_any_files(self):
        import io
        import contextlib
        real = gate.python_files
        gate.python_files = lambda root=None: []
        try:
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                code = gate.main()
            self.assertEqual(code, 2)
            self.assertIn('looking in the wrong place', err.getvalue())
        finally:
            gate.python_files = real

    def test_the_floor_is_not_zero(self):
        self.assertGreaterEqual(gate.LEAST_FILES, 60)

    def test_the_repository_really_has_more_files_than_the_floor(self):
        """Otherwise the floor above is the thing that would fail first."""
        self.assertGreater(len(gate.python_files()), gate.LEAST_FILES)


if __name__ == '__main__':
    unittest.main(verbosity=1)
