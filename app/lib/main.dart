import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/app.dart';
import 'src/core/env.dart';
import 'src/core/splash.dart';
import 'src/core/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // `0653`. Stamped here, before anything slow, because the splash is
  // held for what is LEFT of five seconds from this moment rather than
  // for five seconds from the first frame. `Supabase.initialize` below
  // waits up to fifteen seconds, and a cold start that showed the
  // system splash, then this one for a further five, would be the
  // longest wait on the slowest network -- which is exactly backwards.
  markSplashStart();

  // Refuse to start on a build that was configured with nothing.
  //
  // `Env` carries defaults, so this cannot fire on a build that simply
  // omitted `--dart-define`. It fires on the case that used to be
  // silent: a pipeline that passes `--dart-define=SUPABASE_URL=` with an
  // unset variable behind it, or a URL that is not one. Without this the
  // bundle starts, every query fails somewhere else, and the reason
  // looks like a network problem for as long as anyone cares to look.
  final misconfigured = Env.misconfiguration();
  if (misconfigured != null) {
    runApp(_StartupFailure(error: misconfigured, configuration: true));
    return;
  }

  try {
    await Supabase.initialize(
      url: Env.supabaseUrl,
      publishableKey: Env.supabaseAnonKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
      ),
    ).timeout(const Duration(seconds: 15));
  } catch (error) {
    // Without this the app would sit on a blank white canvas forever
    // whenever the backend is unreachable, with nothing to explain why.
    runApp(_StartupFailure(error: error));
    return;
  }

  runApp(const ProviderScope(child: IAkauntanApp()));
}

/// Shown when the backend could not be reached at start-up — an offline
/// device, a blocked network, or a misconfigured Supabase URL.
class _StartupFailure extends StatelessWidget {
  const _StartupFailure({required this.error, this.configuration = false});

  final Object error;

  /// Whether this is a build that was never configured, rather than a
  /// network that is down. The two look identical from a blank page and
  /// have nothing in common as problems: one is fixed by reconnecting,
  /// the other only by rebuilding.
  final bool configuration;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: Env.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(Space.xxl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    configuration ? Icons.settings_ethernet : Icons.cloud_off,
                    size: 44,
                    color: context.colors.danger,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    configuration
                        ? 'iAkauntan is not configured'
                        : 'Cannot reach iAkauntan',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    configuration
                        ? 'This build was made without the settings it needs, '
                              'so it has not started. Rebuilding with them is '
                              'the only fix; reloading will not help.'
                        : 'The app started but could not connect to the '
                              'server. Check your internet connection and try '
                              'again.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 20),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(Space.md),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: SelectableText(
                      '$error',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
