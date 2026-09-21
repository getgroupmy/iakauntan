/// The first screen an app draws, and the gate that holds it there.
///
/// `core/splash.dart` decides everything worth deciding — how long,
/// whether this surface holds one at all, which picture, which two
/// colours — and this draws the result and counts down. The split is
/// the usual one: none of those answers needs a widget to be asserted,
/// and all of them would be unassertable inside a build method.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/splash.dart';
import '../../core/surface.dart';
import 'landing_content.dart';

/// Holds [child] behind a splash for what is left of [splashHold].
///
/// In the apps only. In a browser it is its child and nothing else, so
/// the website is not a logo for five seconds — see `core/splash.dart`.
class SplashGate extends ConsumerStatefulWidget {
  const SplashGate({super.key, required this.child, this.surface});

  final Widget child;

  /// Which surface this is, for a test that wants to be an app without
  /// being compiled as one. Null means ask [currentSurface], which is
  /// what every real caller does.
  final Surface? surface;

  @override
  ConsumerState<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends ConsumerState<SplashGate> {
  bool _done = false;

  @override
  void initState() {
    super.initState();
    final surface = widget.surface ?? currentSurface;
    if (!splashHeld(surface)) {
      _done = true;
      return;
    }
    final left = splashRemaining(DateTime.now());
    if (left == Duration.zero) {
      // A start slow enough to have used the whole hold. Nothing is
      // gained by drawing the splash for a frame and taking it away.
      _done = true;
      return;
    }
    Future<void>.delayed(left, () {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;

    final brand = ref.watch(landingContentProvider).valueOrNull;
    final dark = Theme.of(context).brightness == Brightness.dark;

    return SplashView(
      image: splashImage(
        uploaded: brand?.splashImageUrl,
        logo: brand?.logoUrl,
        logoDark: brand?.logoDarkUrl,
        dark: dark,
      ),
      wordmark: brand?.wordmark ?? 'iAkauntan',
      dark: dark,
    );
  }
}

/// The splash itself, told what to draw rather than working it out.
///
/// Separate from the gate so it can be looked at without waiting five
/// seconds for it, in a test or in a preview.
class SplashView extends StatelessWidget {
  const SplashView({
    super.key,
    required this.image,
    required this.wordmark,
    required this.dark,
  });

  /// The picture, or null where there is none to draw.
  final String? image;

  /// What the platform calls itself, drawn where there is no picture
  /// and where the picture will not load.
  final String wordmark;

  final bool dark;

  @override
  Widget build(BuildContext context) {
    final background = splashBackground(dark: dark);
    final ink = splashInk(dark: dark);

    final name = Text(
      wordmark,
      key: const ValueKey('splash-wordmark'),
      textAlign: TextAlign.center,
      style: TextStyle(
        color: ink,
        fontSize: 26,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
      ),
    );

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        key: const ValueKey('splash'),
        color: background,
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: image == null
              ? name
              : Image.network(
                  image!,
                  height: 120,
                  fit: BoxFit.contain,
                  // A logo that will not load must not leave five
                  // seconds of empty colour: that reads as a hang, and
                  // the URL comes from a database row and a bucket, so
                  // "will not load" is an ordinary Tuesday.
                  errorBuilder: (_, _, _) => name,
                ),
        ),
      ),
    );
  }
}
