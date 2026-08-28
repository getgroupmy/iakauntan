import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/platform_live.dart';
import '../../core/page_waiting.dart';
import '../../data/site_pages_repository.dart';
import 'landing_content.dart';
import 'landing_tokens.dart';

/// One of the three pages the footer links to.
///
/// Terms, Privacy and Contact: prose an operator wrote in the console,
/// on a page with the platform's mark at the top and a way back. No
/// shell and no session, because somebody being asked to agree to terms
/// has not signed in yet and a policy you have to sign in to read is
/// not a policy.
///
/// An unpublished page is not a 404 with a stack trace — it is a short
/// line saying there is nothing here yet, and the way back. The router
/// lets all three addresses through whether or not anybody has written
/// them, so this screen has to have an answer for the empty case.
class SitePageScreen extends ConsumerWidget {
  const SitePageScreen({super.key, required this.slug});

  /// `terms`, `privacy` or `contact`.
  final String slug;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The same socket the landing page opens: a policy rewritten in
    // the console reaches a visitor who is already reading it.
    ref.watch(platformLiveProvider);

    final scheme = Theme.of(context).colorScheme;
    final fetched = ref.watch(landingContentProvider);
    final pages = ref.watch(sitePagesProvider);

    // "There is nothing here yet" is the right thing to say about a
    // page nobody has written. It is the wrong thing to say about one
    // that has not arrived yet, and this drew it either way — so the
    // policy an operator did write flashed past as its own absence.
    if (!allSettled([fetched, pages])) return const PageWaiting();

    final brand = fetched.valueOrNull;
    final page = pages.valueOrNull?[slug];

    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Land.gutter,
                  vertical: 48,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextButton.icon(
                      onPressed: () => context.go('/'),
                      icon: const Icon(Icons.arrow_back, size: 18),
                      label: Text('Back to ${brand?.wordmark ?? 'iAkauntan'}'),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      page?.title ?? defaultSitePageTitle(slug),
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 20),
                    SelectableText(
                      page?.body ?? _nothingYet,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        height: 1.7,
                        color: page?.body == null
                            ? scheme.onSurfaceVariant
                            : scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 48),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown when nobody has written the page yet.
///
/// Deliberately not an apology and not an error: the operator has not
/// finished setting the platform up, and the visitor's next move is to
/// ask rather than to retry.
const _nothingYet =
    'This page has not been written yet. Please get in touch if you '
    'need it.';

/// The heading a page falls back to.
///
/// The console can rename them — an operator whose terms are called
/// "Syarat Penggunaan" should see that at the top — but a page with no
/// heading at all is a page that looks broken.
String defaultSitePageTitle(String slug) => switch (slug) {
  'terms' => 'Terms of Use',
  'privacy' => 'Privacy Policy',
  'contact' => 'Contact us',
  'signin' => 'Welcome back',
  'signup' => 'Create your account',
  _ => slug,
};
