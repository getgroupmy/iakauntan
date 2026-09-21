#!/usr/bin/env python3
"""Every document type the database has is a document somebody can open.

    python3 scripts/check_document_types.py

`app.sales_doc_type` and `app.purchase_doc_type` decide what kinds of
document exist. `docTypes` in
`app/lib/src/features/documents/doc_types.dart` decides which of them
have a screen -- the router builds every document address out of that
map, and `screen_catalogue.dart` reads it rather than a typed list.

Two ways those can disagree, and both have happened:

  * A TYPE WITH NO SCREEN. `docs/gaps-against-autocount.md` listed five
    for a long time. Four of them were given screens and the document
    never caught up, so it went on naming `proforma` and
    `purchase_request` as unreachable while the router had been
    building their addresses for months. The fifth,
    `purchase_return`, is real and is named below.

  * A SCREEN WITH NO TYPE. Worse, and quieter: the list would offer a
    document the database refuses on insert, with a check constraint's
    message rather than a sentence.

## Why a gate rather than a re-read

Because the re-read is what failed. That document, README's own list,
and this file's predecessors were each wrong about capabilities that
had been built -- four claims in one document, corrected by reading
the code. A list of what is missing is exactly the thing nobody
revisits after they build the missing part.

## How it reads them

From `docs/api/openapi.json`, which carries each enum's values on the
column that uses it, and which another gate already refuses to let
disagree with the schema. No database needed.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
API = ROOT / 'docs' / 'api' / 'openapi.json'
DOC_TYPES = ROOT / 'app' / 'lib' / 'src' / 'features' / 'documents' / 'doc_types.dart'

# The column each enum is reachable through in the description.
ENUMS = {
    'sales_doc_type': ('sales_documents', 'doc_type'),
    'purchase_doc_type': ('purchase_documents', 'doc_type'),
}

# A document type the database has and the app deliberately does not
# offer. The entry is the reason; a name here without one is a screen
# somebody quietly decided not to build.
#
# A ratchet, like `check_unreachable.py`'s: the number should go DOWN.
NO_SCREEN: dict[str, str] = {
    # Returning goods to a supplier is done by a PURCHASE CREDIT NOTE,
    # which has a screen, posts, and creates the stock movement whose
    # type is literally `purchase_return` -- the `v_sign = -1` branch
    # of `post_purchase_document_internal`, which is where the movement
    # enum's name comes from. The document type and the movement type
    # share a name and are not the same thing.
    #
    # So this is a leftover: a numbering prefix (`PRT-`) and nothing
    # else. It cannot mis-post, because the posting function refuses
    # any type but `bill`, `purchase_credit_note` and
    # `purchase_debit_note` by name. A screen for it would be a second
    # way to do what the credit note already does, and the two would
    # disagree about which one the supplier's statement should match.
    'purchase_return':
        'a purchase credit note is how goods go back, and it posts the '
        'purchase_return stock movement',
}


def enum_values() -> dict[str, list[str]]:
    schemas = json.loads(API.read_text())['components']['schemas']
    out = {}
    for name, (table, column) in ENUMS.items():
        prop = schemas.get(table, {}).get('properties', {}).get(column, {})
        values = prop.get('enum')
        if not values:
            sys.exit(f'{API.name} carries no values for {table}.{column} -- '
                     f'regenerate it with scripts/generate_api_description.py')
        out[name] = list(values)
    return out


def screened() -> set[str]:
    """The keys of `docTypes`.

    Read off the declarations rather than by importing Dart: each entry
    is `'name': DocTypeMeta(`, which is unambiguous and is how the map
    has been written since it existed.
    """
    text = DOC_TYPES.read_text()
    # Comments first: this file explains each type at length, and a
    # type named in the paragraph above its own entry would count.
    text = re.sub(r'//.*?$', '', text, flags=re.M)
    return set(re.findall(r"'([a-z_]+)'\s*:\s*DocTypeMeta\(", text))


def main() -> int:
    values = enum_values()
    known = {v for vs in values.values() for v in vs}
    have = screened()

    if not have:
        print('no DocTypeMeta entries found -- has doc_types.dart moved?',
              file=sys.stderr)
        return 2

    missing = sorted(known - have - set(NO_SCREEN))
    if missing:
        print('document types the database has and nobody can open:\n',
              file=sys.stderr)
        for name in missing:
            print(f'  {name}', file=sys.stderr)
        print('\nGive it a DocTypeMeta entry, or name it in NO_SCREEN in '
              'this file WITH the reason.', file=sys.stderr)
        return 1

    # The other direction, and the quieter one: a screen for a document
    # the database refuses on insert.
    invented = sorted(have - known)
    if invented:
        print('documents the app offers and the database has no type for:\n',
              file=sys.stderr)
        for name in invented:
            print(f'  {name}', file=sys.stderr)
        print('\nThe insert would be refused by a check constraint, with '
              'its message rather than a sentence.', file=sys.stderr)
        return 1

    # And an exemption that no longer names a type, which exempts
    # nothing and rots quietly.
    stale = sorted(n for n in NO_SCREEN if n not in known)
    if stale:
        print('named in this file and no longer a document type:\n',
              file=sys.stderr)
        for name in stale:
            print(f'  {name}', file=sys.stderr)
        return 1

    # Or one that has a screen now and was left behind, so the file
    # reads as a list of what is missing while describing something
    # that is not.
    reached = sorted(n for n in NO_SCREEN if n in have)
    if reached:
        print('named in this file and on the list of screens now:\n',
              file=sys.stderr)
        for name in reached:
            print(f'  {name}  -- {NO_SCREEN[name]}', file=sys.stderr)
        print('\nRemove the entry.', file=sys.stderr)
        return 1

    print(f'every document type has a screen '
          f'({len(have)} screens, {len(NO_SCREEN)} deliberately without)')
    if NO_SCREEN:
        print('     deliberately without: ' + ', '.join(sorted(NO_SCREEN)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
