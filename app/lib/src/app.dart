import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/env.dart';
import 'core/favicon.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'data/reserved_names_repository.dart';
import 'features/landing/landing_content.dart';
import 'features/landing/unknown_workspace_screen.dart';

class IAkauntanApp extends ConsumerWidget {
  const IAkauntanApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The platform's chosen colours, if it has chosen any. Read from the
    // same place the landing page is, which is reachable without a
    // session — so the product is in the right colours on the front page
    // as well as behind the sign-in.
    //
    // `valueOrNull` and not a spinner: a theme that waits for the
    // network is a white screen, and the fallback is the colour the
    // product shipped in rather than an absence.
    final brand = ref.watch(landingContentProvider).valueOrNull;

    // The tab icon, repointed at the uploaded image as soon as the brand
    // is known — the built favicon is a file and cannot change until the
    // next deploy, which reads as broken to somebody who has just
    // uploaded one and is watching the tab.
    //
    // In `build` rather than an initState because this is the widget that
    // already watches the brand, and `applyFavicon` is idempotent: it
    // sets an attribute to a value it may already hold. On anything that
    // is not a browser it does nothing at all.
    applyFavicon(brand?.appIconUrl);

    return MaterialApp.router(
      title: Env.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(
        seedColor: AppTheme.parseHex(brand?.brandColour),
      ),
      darkTheme: AppTheme.dark(
        seedColor: AppTheme.parseHex(brand?.brandColourDark) ??
            AppTheme.parseHex(brand?.brandColour),
      ),
      // Which of the two a visitor gets before they have chosen. The
      // default is `system`, which is what `MaterialApp` does anyway —
      // the point of the setting is that a platform that wants to look
      // the same to everybody can now say so, which it could not before.
      themeMode: themeModeFor(brand?.themeMode),
      routerConfig: ref.watch(routerProvider),
      // A name nobody holds gets one page, whatever route was asked
      // for. Here rather than in the router because it is a fact about
      // the address rather than about the path: `/`, `/signin` and any
      // deep link into the app are all equally not this visitor's, and
      // a redirect would only move the same wrong answer around.
      //
      // `valueOrNull` while the lookup is in flight, so the ordinary
      // app draws first and this replaces it — the alternative is a
      // blank screen on every page load for the sake of the rare one.
      builder: (context, child) =>
          ref.watch(workspaceLookupProvider).valueOrNull?.host ==
                  WorkspaceHost.unknown
              ? const UnknownWorkspaceScreen()
              : child ?? const SizedBox.shrink(),
    );
  }
}

/// The stored scheme as Flutter's enum.
///
/// Anything unrecognised is `system`, deliberately: the value arrives
/// from a database column, and a front page that throws because somebody
/// typed a fourth scheme into it is a worse outcome than a front page in
/// the visitor's own preference.
ThemeMode themeModeFor(String? stored) => switch (stored) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => ThemeMode.system,
};
