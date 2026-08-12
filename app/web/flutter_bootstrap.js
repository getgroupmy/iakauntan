{{flutter_js}}
{{flutter_build_config}}

// Deliberately no `serviceWorkerSettings`, which is what stops a service
// worker being registered at all.
//
// Flutter's default worker caches the application shell, including this
// bootstrap — and the bootstrap is what carries the serviceWorkerVersion
// the worker compares against. Once a device holds a stale copy, the
// worker reads the old version out of it, concludes it is current, and
// keeps serving old code. A deployed fix then never reaches that device
// and an ordinary reload cannot break the loop, because the reload is
// answered from the same cache.
//
// `--pwa-strategy=none` is not enough on its own: it emits a worker with
// an empty body but still registers it. Registering nothing is what makes
// a deploy land the moment somebody loads the page.
//
// Nothing here works offline in any case — every screen reads Supabase —
// so an offline shell only ever bought the illusion of one.
// Sentinel for the deploy workflow's check. The obvious assertion —
// grepping the built bootstrap for "serviceWorkerVersion" — is wrong:
// flutter.js is inlined here and always contains that identifier whether
// or not anything uses it. So the check looks for this line instead.
// iakauntan:no-service-worker
_flutter.loader.load();
