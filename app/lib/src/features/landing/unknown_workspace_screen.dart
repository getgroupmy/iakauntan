import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/safe_link.dart';
import 'landing_content.dart';

/// What a visitor gets at a subdomain nobody holds.
///
/// Every label under the wildcard resolves, so `nosuchcompany` reaches
/// the app exactly as a real company's name does. Before this screen it
/// drew the platform's own front page, which reads as "the address is
/// fine, the company is not here" — the opposite of what happened.
///
/// Deliberately not an error page. The likeliest visitor is somebody
/// who mistyped a name, or was handed one that has lapsed, and neither
/// of them did anything wrong. It carries the platform's own mark, a
/// plain sentence, and one way onwards.
class UnknownWorkspaceScreen extends ConsumerWidget {
  const UnknownWorkspaceScreen({super.key, this.host});

  /// The address this is being drawn at. Injected only by the tests —
  /// in a browser it is `Uri.base.host`, which they cannot set.
  final String? host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brand = ref.watch(landingContentProvider).valueOrNull;

    final title = brand?.unknownTitle ?? LandingContent.defaultUnknownTitle;
    final body = brand?.unknownBody ?? LandingContent.defaultUnknownBody;
    final label =
        brand?.unknownCtaLabel ?? LandingContent.defaultUnknownCtaLabel;
    final url = brand?.unknownCtaUrl ?? 'https://${apexOf(host ?? Uri.base.host)}';

    return Scaffold(
      backgroundColor: scheme.surface,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (brand?.logoUrl != null)
                  Image.network(
                    brand!.logoUrl!,
                    height: 36,
                    // The same rule the sign-in page's mark has: a logo
                    // that will not load must not take the page with it.
                    errorBuilder: (_, _, _) => _Wordmark(brand: brand),
                  )
                else
                  _Wordmark(brand: brand),
                const SizedBox(height: 32),
                Text(title, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 12),
                Text(
                  body,
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                // The address itself, because "check it for a typo" is
                // advice somebody cannot follow without seeing what
                // they typed — a phone's address bar hides it.
                SelectableText(
                  host ?? Uri.base.host,
                  key: const Key('unknown-workspace-host'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 28),
                FilledButton(
                  onPressed: () => launchExternal(url),
                  child: Text(label),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The bare domain behind a company's address.
///
/// `sinar.iakauntan.com` → `iakauntan.com`. Pure and exported so the
/// test can assert it without a browser, and because the alternative —
/// writing the platform's own domain into the app — is a constant that
/// goes wrong the day somebody runs this under a second one.
///
/// A host with nothing in front of it is returned unchanged: this is
/// only ever called on an address that already has a label, but a
/// helper that drops the whole domain when it is wrong about that
/// would send the visitor somewhere that does not exist.
String apexOf(String host) {
  final bare = host.split(':').first.trim().toLowerCase();
  final labels = bare.split('.');
  return labels.length < 3 ? bare : labels.sublist(1).join('.');
}

class _Wordmark extends StatelessWidget {
  const _Wordmark({required this.brand});

  final LandingContent? brand;

  @override
  Widget build(BuildContext context) => Text(
        brand?.wordmark ?? 'iAkauntan',
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.primary,
            ),
      );
}
