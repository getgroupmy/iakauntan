#!/usr/bin/env python3
"""Does the built web bundle get past bootstrap?

    cd app && flutter build web --release
    python3 scripts/check_web_boots.py

## The failure this is for

A web plugin registrant that throws. `registerPlugins()` runs BEFORE
`runApp`, so one exception there means `main()` never finishes and
every page of the app is blank -- the landing page included, which has
nothing to do with whichever plugin it was.

Nothing else here catches it. `flutter analyze` is clean,
`flutter build web` compiles it happily, and the failure is a missing
JS global at runtime in a browser. It shipped that way once; see
`docs/passkeys.md`.

`scripts/check_web_plugin_registrant.py` is the cheap tripwire for the
one plugin known to do this, and it fires on the commit that adds it.
This is the general answer, and the only honest one: open the bundle in
a browser and see whether anything is drawn.

## Two things it has to do to mean anything

**Serve CanvasKit locally.** A release bundle fetches it from
`gstatic.com`, which a locked-down network refuses -- and a refusal
there gives a blank page for a reason that has nothing to do with the
code. The first version of this reported a white screen on a bundle
that was fine. So the SDK's own copy is placed beside the build and
the loader is pointed at it, in a COPY of the build output; nothing in
`build/web` is modified.

**Ask whether Flutter drew, not whether the page is empty.**
`flutter-view` is inserted by the engine after `main()` has run, so its
presence is a direct statement that bootstrap finished.

Network errors from the app's own back end are IGNORED. They are
expected wherever this runs without credentials and they say nothing
about bootstrap; what is not ignored is an uncaught exception, which is
what the outage was.
"""
import http.server
import json
import os
import re
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / 'app' / 'build' / 'web'
CHROME = os.environ.get(
    'CHROME', '/opt/pw-browsers/chromium-1194/chrome-linux/chrome')
FLUTTER_ROOT = Path(os.environ.get('FLUTTER_ROOT', '/opt/flutter-sdk'))
CANVASKIT = FLUTTER_ROOT / 'bin' / 'cache' / 'flutter_web_sdk' / 'canvaskit'

# The expression in the generated loader that decides where CanvasKit
# comes from. Replaced with the local path in the served copy.
REMOTE_CANVASKIT = re.compile(
    r'e\.engineRevision&&!e\.useLocalCanvasKit\?'
    r'_\("https://www\.gstatic\.com/flutter-canvaskit",e\.engineRevision\)'
    r':"canvaskit"')


def serve(directory: Path):
    """A quiet static server on a port the OS picks."""
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=str(directory), **kw)

        def log_message(self, *a):
            pass

    httpd = socketserver.TCPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, httpd.server_address[1]


def stage(build: Path, into: Path) -> bool:
    """A copy of the build with CanvasKit beside it. True if pointed."""
    shutil.copytree(build, into, dirs_exist_ok=True)
    if CANVASKIT.exists():
        shutil.copytree(CANVASKIT, into / 'canvaskit', dirs_exist_ok=True)
    loader = into / 'flutter_bootstrap.js'
    if not loader.exists():
        return False
    body = loader.read_text()
    pointed, n = REMOTE_CANVASKIT.subn('"canvaskit"', body)
    if n:
        loader.write_text(pointed)
        return True
    # A loader that never mentions gstatic is already serving CanvasKit
    # from the bundle -- `--wasm` does this, and so does a build that
    # was pointed at a local copy some other way. Not a failure to
    # point it; nothing to point.
    return 'gstatic.com/flutter-canvaskit' not in body


def boot(url: str, seconds: float = 30) -> tuple[str, list[str]]:
    """Load the page and report what Flutter did. (verdict, exceptions)"""
    import websocket

    port = 9455
    chrome = subprocess.Popen(
        [CHROME, '--headless=new', f'--remote-debugging-port={port}',
         '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage',
         '--remote-allow-origins=*',
         f'--user-data-dir={tempfile.mkdtemp()}', 'about:blank'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        target = None
        for _ in range(80):
            try:
                tabs = json.load(urllib.request.urlopen(
                    f'http://127.0.0.1:{port}/json/list', timeout=1))
                target = next((t for t in tabs if t['type'] == 'page'), None)
                if target:
                    break
            except Exception:
                pass
            time.sleep(0.5)
        if not target:
            return 'no browser', []

        ws = websocket.create_connection(target['webSocketDebuggerUrl'],
                                         timeout=seconds + 10)

        def rpc(i, method, params=None):
            ws.send(json.dumps(
                {'id': i, 'method': method, 'params': params or {}}))

        rpc(1, 'Runtime.enable')
        rpc(2, 'Page.enable')
        rpc(3, 'Page.navigate', {'url': url})

        thrown = []
        ws.settimeout(2)
        deadline = time.time() + seconds
        while time.time() < deadline:
            try:
                msg = json.loads(ws.recv())
            except Exception:
                continue
            if msg.get('method') == 'Runtime.exceptionThrown':
                detail = msg['params']['exceptionDetails']
                thrown.append(str(detail.get('exception', {})
                                  .get('description') or detail.get('text')))

        rpc(90, 'Runtime.evaluate', {
            'expression': "document.querySelector('flutter-view')?'drew':"
                          "'blank'",
            'returnByValue': True})
        ws.settimeout(10)
        verdict = 'no answer'
        for _ in range(60):
            try:
                msg = json.loads(ws.recv())
            except Exception:
                break
            if msg.get('id') == 90:
                verdict = (msg.get('result', {}).get('result', {})
                           .get('value', 'no answer'))
                break
        return verdict, thrown
    finally:
        chrome.terminate()
        chrome.wait()


def main() -> int:
    if not (BUILD / 'index.html').exists():
        print(f'no build at {BUILD.relative_to(ROOT)}. Run:')
        print('    cd app && flutter build web --release')
        return 2
    if not Path(CHROME).exists():
        print(f'no browser at {CHROME}. Set CHROME to one.')
        return 2
    try:
        import websocket  # noqa: F401
    except ImportError:
        print('needs websocket-client: pip install websocket-client')
        return 2

    with tempfile.TemporaryDirectory() as tmp:
        staged = Path(tmp) / 'web'
        pointed = stage(BUILD, staged)
        if not pointed:
            # Said out loud rather than run anyway. A bundle that
            # cannot reach CanvasKit draws nothing, and reporting that
            # as the outage would be a check that fails for a reason
            # of its own making.
            print('could not point the loader at a local CanvasKit.')
            print('    The bundle would fetch it from gstatic.com, and a '
                  'network that')
            print('    refuses that gives a blank page for a reason that is '
                  'not the code.')
            return 2
        httpd, port = serve(staged)
        try:
            verdict, thrown = boot(f'http://127.0.0.1:{port}/index.html')
        finally:
            httpd.shutdown()

    if thrown:
        print('The web bundle threw before it finished starting.')
        print()
        for t in thrown[:8]:
            print(f'    {t.splitlines()[0][:200]}')
        print()
        print('    This is the shape of the outage in docs/passkeys.md: a '
              'plugin')
        print('    registrant that throws inside registerPlugins(), which '
              'runs')
        print('    before runApp. Every page is blank.')
        return 1
    if verdict != 'drew':
        print(f'The web bundle did not draw anything ({verdict}).')
        print('    No exception was reported, so this is not the registrant')
        print('    failure -- look at the browser console by hand.')
        return 1

    print('ok   the web bundle starts and Flutter draws')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
