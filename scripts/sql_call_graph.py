#!/usr/bin/env python3
"""Which functions in this database can reach a write.

`check_stable_writers.py` asks whether a STABLE function writes, and
until now it asked by looking for three function names in the body:

    p.prosrc ~* '(note_read|note_export|record_security_event)'

That is the list of writers somebody had been bitten by, not the list of
writers. It answers correctly for `public.platform_feedback`, which is
the one that broke, and says nothing about a STABLE function that calls
anything else -- or that writes with its own `update`.

This module answers the question properly: build the call graph, mark
every function whose own body writes, and propagate to a fixed point so
a write four hops down still counts.

## The scanner, and why it is not two regexes

Finding the writes means reading the body, and reading the body means
knowing which characters are code. Doing that as two passes -- blank the
comments, then blank the strings -- is wrong in the direction that
matters, because a refusal message like

    'Sold by weight needs a unit that measures something -- a
     kilogram, a litre, a metre.'

carries a `--` INSIDE a string. Strip comments first and that eats to
the end of the line, leaving an unmatched quote; the string pass then
swallows the rest of the function, including the `update` the message
was written for. `set_item_weighed`, `import_accounts` and
`platform_save_promotion` all read as pure reads that way. All three
plainly write.

So [clean] is one left-to-right scanner, which is the only thing that
can tell a comment from four characters of English. It handles `''`
inside a literal and `$tag$` dollar quotes, both of which this schema
uses.

## What it is deliberately not

It is not a parser. A function reached only through `execute` on a
string this cannot see is a write it will miss, and the conservative
half of that is the important half: the check built on this FAILS a
build when it finds a write, so a miss is a gate that stays quiet, not
a gate that fires wrongly.
"""
import re
import json
import subprocess

# One alternative per verb, each ending at its own boundary.
#
# A single trailing `\b` over the whole alternation is wrong and lets
# writes through silently: matching `update p` of `update public.x`,
# the boundary between `p` and `u` does not hold, the match fails, and
# a function that plainly updates reads as a pure read.
WRITE = re.compile('|'.join([
    r'\binsert\s+into\b',
    r'\bupdate\s+(?:only\s+)?[a-z_"]',
    r'\bdelete\s+from\b',
    r'\btruncate\b',
    r'\bmerge\s+into\b',
    r'\bnextval\b',
    r'\bsetval\b',
    r'\bcreate\s+(?:or\s+replace\s+)?[a-z]',
    r'\bdrop\s+[a-z]',
    r'\balter\s+[a-z]',
    r'\bgrant\s+[a-z]',
    r'\brevoke\s+[a-z]',
    r'\bcopy\s+[a-z_"]',
    # `returning` cannot appear in a read. It is here for the write
    # hidden in a CTE -- `with x as (insert ... returning ...)` -- where
    # the verb is inside parentheses the alternatives above still catch,
    # and as a second net for anything they do not.
    r'\breturning\b',
    r'\blo_[a-z]+\s*\(',
]), re.I)

_DOLLAR = re.compile(r'\$[A-Za-z_]\w*\$|\$\$')

# Anything that looks like a call. Deliberately loose: it is matched
# against the names this database actually has, so a column called
# `count(` or a type cast matches nothing.
_CALL = re.compile(r'\b(?:(?:app|public)\s*\.\s*)?([a-z_][a-z0-9_]*)\s*\(', re.I)

_DUMP = r"""
select coalesce(json_agg(row_to_json(t)), '[]'::json) from (
  select n.nspname as sch, p.proname as name,
         pg_get_function_identity_arguments(p.oid) as args,
         p.provolatile as vol, p.prokind as kind,
         coalesce(p.prosrc, '') as src,
         has_function_privilege('authenticated', p.oid, 'execute')
           as reachable,
         exists (select 1 from pg_depend dp
                  where dp.objid = p.oid and dp.deptype = 'e') as ext
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'app')
) t;
"""


def clean(src: str) -> str:
    """The body with comments and string literals blanked out.

    One pass, left to right. See the module docstring for why this
    cannot be two regexes.
    """
    out = []
    i, n = 0, len(src)
    while i < n:
        if src.startswith('--', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
        elif src.startswith('/*', i):
            # Postgres block comments nest; so does this.
            depth, i = 1, i + 2
            while i < n and depth:
                if src.startswith('/*', i):
                    depth, i = depth + 1, i + 2
                elif src.startswith('*/', i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
            out.append(' ')
        elif src[i] == "'":
            i += 1
            while i < n:
                if src[i] == "'":
                    if src.startswith("''", i):
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            out.append(" '' ")
        elif src[i] == '$' and (m := _DOLLAR.match(src, i)):
            tag = m.group(0)
            j = src.find(tag, i + len(tag))
            i = n if j < 0 else j + len(tag)
            out.append(" '' ")
        else:
            out.append(src[i])
            i += 1
    return ''.join(out)


def writes_in_body(src: str) -> bool:
    """Whether this body writes something itself."""
    return bool(WRITE.search(clean(src)))


def load(url: str) -> list[dict]:
    """Every function in `public` and `app`, with its body scanned."""
    out = subprocess.run(['psql', url, '-tAc', _DUMP],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip())
    rows = json.loads(out.stdout)
    for r in rows:
        r['clean'] = clean(r['src'])
        r['self_writes'] = bool(WRITE.search(r['clean']))
        r['signature'] = f"{r['sch']}.{r['name']}({r['args']})"
    return rows


def mark_writers(rows: list[dict]) -> dict[int, bool]:
    """Which functions can reach a write, by index into `rows`.

    A fixed point rather than one pass over the callees, so a write
    four hops down still counts. `post_sales_document` reaches one
    through `post_sales_document_internal`; `bulk_post_documents`
    reaches it through that.
    """
    by_name: dict[str, list[int]] = {}
    for i, r in enumerate(rows):
        by_name.setdefault(r['name'].lower(), []).append(i)

    calls = [
        {nm for nm in (m.group(1).lower()
                       for m in _CALL.finditer(r['clean']))
         if nm in by_name and nm != r['name'].lower()}
        for r in rows
    ]

    writes = {i: r['self_writes'] for i, r in enumerate(rows)}
    changed = True
    while changed:
        changed = False
        for i, r in enumerate(rows):
            if writes[i]:
                continue
            if any(writes[j] for nm in calls[i] for j in by_name[nm]):
                writes[i] = True
                changed = True
    return writes


def why(rows: list[dict], writes: dict[int, bool], i: int) -> str:
    """What makes row `i` a writer, in words, for the failure message."""
    if rows[i]['self_writes']:
        return 'its own body'
    by_name: dict[str, list[int]] = {}
    for j, r in enumerate(rows):
        by_name.setdefault(r['name'].lower(), []).append(j)
    named = sorted({
        nm for m in _CALL.finditer(rows[i]['clean'])
        if (nm := m.group(1).lower()) in by_name
        and nm != rows[i]['name'].lower()
        and any(writes[j] for j in by_name[nm])
    })
    return ', '.join(named) or 'something it calls'
