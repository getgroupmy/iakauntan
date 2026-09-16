// A one-time rescue for browsers still carrying the service worker this
// app used to register.
//
// The app is built with --pwa-strategy=none, so nothing registers a
// worker any more. But a device that installed the old one keeps it:
// the worker serves flutter_bootstrap.js from its cache, that stale
// bootstrap carries the serviceWorkerVersion it was built with, so the
// worker concludes it is current and never updates. The app then runs
// old code indefinitely and an ordinary reload cannot break the loop --
// which is how a shipped fix can sit in production, deployed and
// correct, while the phone in your hand never sees it.
//
// This runs because index.html is the one thing Flutter's worker
// fetches network-first, so a new copy of that file -- and of the
// <script src> tag pointing here -- does reach the browser even while
// everything around it is stale.
//
// ---------------------------------------------------------------------
// Why this is a FILE and not an inline <script>
//
// It was inline, and the Content-Security-Policy in
// `deploy/vercel-output-config.json` is
//
//     script-src 'self' 'wasm-unsafe-eval' https://challenges.cloudflare.com
//
// with no 'unsafe-inline' and no hash. So the browser refused it on
// every single load, on every browser, and the rescue this file is
// named for never ran once in production. Old workers and old caches
// were never cleared, which is precisely the "I am still seeing the old
// version" report that brought it to light -- worst on Android Chrome,
// where tabs and installed web apps outlive everything.
//
// A hash in the CSP would also satisfy the policy, and is the wrong
// answer: the hash is of the script's exact bytes, so the next person
// to correct a comment in here ships a policy that blocks it again and
// finds out months later. 'self' and a file cannot drift apart.
//
// It only ever acts when a registration is actually present, so a clean
// visitor pays nothing, and the sessionStorage guard means it cannot
// turn into a reload loop if a browser reports registrations it will
// not let go of.
//
// One exception, added with web push: the worker at the /push/ scope is
// ours and current. It serves no assets and caches nothing, so it
// cannot cause the problem this rescue exists for -- and unregistering
// it would silently cancel the browser's push subscription, which is
// the sort of bug that looks like "notifications just stopped working
// on Chrome" and has no visible cause anywhere.
(function () {
  if (!('serviceWorker' in navigator)) return;

  function dropCaches() {
    if (!window.caches) return Promise.resolve();
    return caches.keys().then(function (keys) {
      return Promise.all(keys.map(function (k) { return caches.delete(k); }));
    });
  }

  function isPushWorker(reg) {
    return reg.scope.indexOf('/push/') === reg.scope.length - 6;
  }

  navigator.serviceWorker.getRegistrations().then(function (all) {
    var regs = all.filter(function (r) { return !isPushWorker(r); });
    var had = regs.length > 0;
    return Promise.all(regs.map(function (r) { return r.unregister(); }))
      // Unconditional, because the pass that unregisters cannot also
      // finish the cleanup: it reloads, and after the reload there is
      // no registration left to notice by. A cache with no worker to
      // read it is inert rather than harmful, but leaving one behind
      // for good is the kind of debris that misleads whoever debugs
      // this next.
      .then(dropCaches)
      .then(function () {
        if (!had || sessionStorage.getItem('sw-evicted')) return;
        sessionStorage.setItem('sw-evicted', '1');
        window.location.reload();
      });
  }).catch(function () { /* Nothing useful to do; the app still loads. */ });
})();
