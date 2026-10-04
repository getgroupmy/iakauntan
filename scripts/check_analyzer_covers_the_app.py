#!/usr/bin/env python3
"""`flutter analyze` says "No issues found!" over code it never read.

    python3 scripts/check_analyzer_covers_the_app.py

`- run: flutter analyze --fatal-infos --fatal-warnings` is the strictest
line in `ci.yml` and the easiest one in the repository to switch off
without touching it, because what it analyses is decided somewhere else:
`app/analysis_options.yaml`.

Both holes below were MEASURED, not reasoned about. A file holding two
hard type errors was put in `lib/src/`, and `flutter analyze` found them:

    2 issues found. (ran in 70.6s)   exit 1

Then, with that file untouched:

  * `exclude: - lib/src/**` ->  "No issues found! (ran in 3.2s)"  exit 0
  * `errors: invalid_assignment: ignore` (and `return_of_invalid_type`)
    ->                           "No issues found! (ran in 18.2s)" exit 0

Seventy seconds became three, which is the tell nothing reads, and the
build went green over code the analyser had not looked at. A third line
does the same thing more quietly: delete `include:` and every lint in
`flutter_lints` goes with it, leaving only the type system.

## What this asserts

  * `include:` is still there and still names the lint package.
  * every `exclude:` entry is one of the four non-Dart directories, named
    here, and nothing else.
  * no `exclude:` pattern MATCHES a real `.dart` file under `app/lib` or
    `app/test`. That is the check about effect rather than spelling. The
    clause above refuses a pattern nobody listed here; this one catches
    the case where the pattern is unchanged and the TREE moved under it
    -- Dart put into `app/web/`, say, which is excluded and reasonably
    so today because it holds `index.html`, a manifest and a service
    worker. The name would still look right.
  * no `errors:` key downgrades anything to `ignore`, `info` or
    `warning`. Downgrading to `warning` matters because --fatal-warnings
    makes it fatal again, so only `error` and absence are safe, and
    saying so here is cheaper than relying on the flag staying.
  * no `rules:` entry is `false`, which is how a single lint is switched
    off.
  * a floor on the number of `.dart` files that remain analysable, so an
    empty `app/` cannot read as a clean configuration.

Not a list of which lints to use. `flutter_lints` is the project's
choice; this says the choice is still in force.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "app"
OPTIONS = APP / "analysis_options.yaml"

#: The directories allowed to be excluded, each with the reason it holds
#: no Dart the analyser should read. An entry here is a claim, so a fifth
#: exclusion has to be argued for in this file rather than added quietly.
ALLOWED_EXCLUDES = {
    "build/**": "generated output",
    "android/**": "Gradle and Kotlin, plus a generated plugin registrant",
    "ios/**": "Xcode and Swift, plus a generated plugin registrant",
    "web/**": "the web shell -- index.html, the manifest, a service worker",
}

#: The lint package the project chose. Removing the `include:` line is
#: the quietest of the three holes: analyze still runs, still passes, and
#: enforces nothing but the type system.
INCLUDE = "package:flutter_lints/flutter.yaml"

#: A floor under the `.dart` files that remain analysable. 1,000-odd
#: today across lib and test; floored well below, because an empty app/
#: and a correctly configured one read the same.
LEAST_DART = 400

#: Severities that make an analyser message stop failing the build.
#: `warning` is in here because the only thing making a warning fatal is
#: `--fatal-warnings` on a line in another file.
SOFTENED = {"ignore", "info", "warning"}


def glob_to_regex(pattern: str) -> re.Pattern[str]:
    """A Dart analyzer exclude glob as a regex over a relative path.

    `**` crosses path separators, `*` does not, `?` is one character that
    is not a separator. Written out rather than handed to `fnmatch`,
    which translates `*` to `.*` and so cannot tell the two apart -- and
    the whole point of this function is that `build/*` and `build/**`
    exclude different things.
    """
    out = ["^"]
    i = 0
    while i < len(pattern):
        c = pattern[i]
        if pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif c == "*":
            out.append("[^/]*")
            i += 1
        elif c == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(c))
            i += 1
    out.append("$")
    return re.compile("".join(out))


def parse(text: str) -> dict:
    """The few things this gate needs, out of a flat two-level YAML.

    No yaml module: `ci.yml` is read with one in this repository's own
    tests, but a gate in `scripts/` that imports PyYAML is a gate that
    does not run where PyYAML is missing, and this file is two keys deep.
    """
    excludes: list[str] = []
    errors: dict[str, str] = {}
    rules: dict[str, str] = {}
    includes: list[str] = []
    section = None
    for raw in text.split("\n"):
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        stripped = line.strip()
        if indent == 0:
            if stripped.startswith("include:"):
                includes.append(stripped.split(":", 1)[1].strip())
            section = None
            if stripped.rstrip(":") in ("analyzer", "linter"):
                section = stripped.rstrip(":")
            continue
        if indent == 2 and stripped.rstrip(":") in ("exclude", "errors",
                                                    "rules", "plugins",
                                                    "language",
                                                    "strong-mode"):
            section = stripped.rstrip(":")
            continue
        if section == "exclude" and stripped.startswith("- "):
            excludes.append(stripped[2:].strip().strip("'\""))
        elif section == "errors" and ":" in stripped:
            k, v = stripped.split(":", 1)
            errors[k.strip()] = v.strip().strip("'\"")
        elif section == "rules" and ":" in stripped:
            k, v = stripped.split(":", 1)
            rules[k.strip()] = v.strip().strip("'\"")
        elif section == "rules" and stripped.startswith("- "):
            rules[stripped[2:].strip()] = "true"
    return {"exclude": excludes, "errors": errors, "rules": rules,
            "include": includes}


def dart_files() -> list[str]:
    """Every `.dart` file under app/lib and app/test, relative to app/."""
    out = []
    for sub in ("lib", "test"):
        for path in (APP / sub).rglob("*.dart"):
            out.append(str(path.relative_to(APP)))
    return sorted(out)


def problems(text: str | None = None,
             files: list[str] | None = None) -> tuple[list[str], int]:
    out: list[str] = []
    if text is None:
        if not OPTIONS.exists():
            # `relative_to(ROOT)` RAISES for a path outside ROOT, and
            # this gate's own test points OPTIONS at /nonexistent to
            # reach this branch. Second time today: the same line was
            # written, hit and fixed in check_self_tests_run.py an hour
            # earlier, and the comment there did not stop it being
            # written again here. A path constant a test repoints is not
            # inside ROOT.
            try:
                where = OPTIONS.relative_to(ROOT)
            except ValueError:
                where = OPTIONS
            return ([
                "%s does not exist. With no analysis options at all "
                "`flutter analyze` still runs and still passes, enforcing "
                "nothing but the type system -- so this check could not "
                "look, which is not the same as finding nothing wrong."
                % where], 0)
        text = OPTIONS.read_text()
    conf = parse(text)
    files = dart_files() if files is None else files

    if len(files) < LEAST_DART:
        out.append(
            "found only %d analysable .dart file(s) under app/lib and "
            "app/test, and there were %d or more when this was written. A "
            "sweep with nothing to look at reports what a correctly "
            "configured project reports." % (len(files), LEAST_DART))
        return out, len(files)

    if INCLUDE not in conf["include"]:
        out.append(
            "analysis_options.yaml no longer includes %s. Deleting that "
            "one line is the quietest way to switch this project's lints "
            "off: `flutter analyze` still runs, still says \"No issues "
            "found!\", and enforces nothing but the type system."
            % INCLUDE)

    for pattern in conf["exclude"]:
        if pattern not in ALLOWED_EXCLUDES:
            out.append(
                "analysis_options.yaml excludes %r, which is not one of "
                "the four directories this project excludes (%s). An "
                "exclusion is code `flutter analyze` does not read, and "
                "the build stays green over it. Measured: adding "
                "`lib/src/**` took a run with two hard type errors from "
                "\"2 issues found\" and exit 1 to \"No issues found! "
                "(ran in 3.2s)\" and exit 0."
                % (pattern, ", ".join(sorted(ALLOWED_EXCLUDES))))
            continue
        hidden = [f for f in files if glob_to_regex(pattern).match(f)]
        if hidden:
            out.append(
                "the exclusion %r matches %d .dart file(s) under app/lib "
                "or app/test, starting with %s. It is on the allowed list "
                "under a name that no longer describes what it hides."
                % (pattern, len(hidden), hidden[0]))

    for name, why in sorted(ALLOWED_EXCLUDES.items()):
        if name not in conf["exclude"]:
            out.append(
                "%r is listed here as an exclusion this project makes (%s) "
                "and analysis_options.yaml does not exclude it. Either the "
                "directory is gone, in which case drop the entry, or "
                "something is now being analysed that this file says is "
                "not -- which is the harmless direction, and still worth "
                "reading." % (name, why))

    for code, severity in sorted(conf["errors"].items()):
        if severity.lower() in SOFTENED:
            out.append(
                "analysis_options.yaml downgrades %s to %r. Measured: "
                "`invalid_assignment: ignore` took a run with two hard "
                "type errors to \"No issues found!\" and exit 0, with "
                "--fatal-infos --fatal-warnings both set. `warning` "
                "counts here too, because the only thing making a warning "
                "fatal is a flag in another file." % (code, severity))

    for rule, value in sorted(conf["rules"].items()):
        if value.lower() == "false":
            out.append(
                "analysis_options.yaml turns the lint %s off. That is a "
                "deliberate weakening of the set this project chose; if it "
                "is wanted, say why here and add it to a list of allowed "
                "exceptions rather than leaving it unremarked." % rule)

    return out, len(files)


def main() -> int:
    found, counted = problems()
    if found:
        print("The analyser is not reading what CI claims it reads:\n",
              file=sys.stderr)
        for problem in found:
            print("  %s\n" % problem, file=sys.stderr)
        return 1
    print("flutter analyze reads all %d .dart files under app/lib and "
          "app/test; the lint include is in force and nothing is "
          "downgraded" % counted)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
