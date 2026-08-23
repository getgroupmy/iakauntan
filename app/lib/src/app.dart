import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/env.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'features/landing/landing_content.dart';

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
      routerConfig: ref.watch(routerProvider),
    );
  }
}
