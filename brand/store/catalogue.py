"""The app's screen list, read out of the Dart rather than typed again.

`screen_catalogue.dart` is already asserted against `core/router.dart` by
`test/screen_catalogue_test.dart`, so parsing it is the one way to get a
screen list for the store assets that cannot quietly drift from the app.
A label that changes in the app changes here on the next build; a screen
that is deleted disappears from the set instead of being shipped to Play
as a picture of somewhere that no longer exists.
"""
import os, re

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CAT = os.path.join(ROOT, 'app/lib/src/features/feedback/screen_catalogue.dart')
DOC = os.path.join(ROOT, 'app/lib/src/features/documents/doc_types.dart')


def doc_types():
    src = open(DOC).read()
    body = src[src.index('const docTypes ='):]
    out = []
    for m in re.finditer(r"'([a-z_]+)':\s*DocTypeMeta\((.*?)\n  \)", body, re.S):
        key, fields = m.group(1), m.group(2)
        plural = re.search(r"plural:\s*'([^']+)'", fields)
        kind = re.search(r"kind:\s*DocKind\.(\w+)", fields)
        if plural and kind:
            out.append((key, plural.group(1), kind.group(1)))
    return out


def screens():
    """[(module, area, label, route)] in catalogue order."""
    src = open(CAT).read()
    body = src[src.index('final List<ScreenModule> appScreenCatalogue'):]
    body = re.sub(r'//[^\n]*', '', body)
    docs = doc_types()
    out, module, area = [], None, None
    token = re.compile(
        r"ScreenModule\('([^']+)'|ScreenArea\('([^']+)'|"
        r"AppScreen\('([^']+)',\s*'([^']+)'\)|_documentScreens\(DocKind\.(\w+)\)")
    for m in token.finditer(body):
        if m.group(1):
            module = m.group(1)
        elif m.group(2):
            area = m.group(2)
        elif m.group(3):
            out.append((module, area, m.group(3), m.group(4)))
        elif m.group(5):
            kind = m.group(5)
            root = '/sales' if kind == 'sales' else '/purchases'
            for key, plural, k in docs:
                if k == kind:
                    out.append((module, area, plural, f'{root}/{key}'))
    return out


if __name__ == '__main__':
    s = screens()
    print(len(s), 'screens')
    mod = None
    for m, a, label, route in s:
        if m != mod:
            print('\n##', m); mod = m
        print(f'   {label:38s} {route}')
