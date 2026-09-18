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
                    // Back to WHERE THEY CAME FROM when there is such a
                    // place, and to the front page only when there is
                    // not.
                    //
                    // This page is reached two ways and they want
                    // different answers: from the footer, where the
                    // front page is genuinely behind it, and from the
                    // consent line under the register button, where the
                    // half-filled form is. Sending the second reader to
                    // the front page throws away what they had typed --
                    // for the crime of reading the terms they were just
                    // asked to agree to.
                    //
                    // The label follows, because a button that says
                    // "Back to iAkauntan" and returns to a sign-up form
                    // is a button that lied about where it goes.
                    _BackButton(brand: brand?.wordmark ?? 'iAkauntan'),
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

/// The pages the footer links to, reachable without signing in.
///
/// ONE list, read by three things that must agree: the routes
/// `router.dart` builds, the paths its redirect lets a stranger past,
/// and the footer on the landing page.
///
/// It is a constant rather than three literals because the third of
/// them was missed. `0651` added `terms-of-service` to the routes and
/// to the footer and NOT to the redirect's public-path list, so the
/// link drew, was tappable, and bounced a signed-out reader to the
/// sign-in form — a page that exists, is linked, and cannot be opened,
/// which is the exact shape of failure a list repeated three times
/// produces.
///
/// A policy you have to sign in to read is not a policy. Everything on
/// this list is readable by a stranger by design.
const publicSitePageSlugs = <String>[
  'terms',
  'terms-of-service',
  'privacy',
  'contact',
];

/// The heading a page falls back to.
///
/// The console can rename them — an operator whose terms are called
/// "Syarat Penggunaan" should see that at the top — but a page with no
/// heading at all is a page that looks broken.
String defaultSitePageTitle(String slug) => switch (slug) {
  'terms' => 'Terms of Use',
  'terms-of-service' => 'Terms of Service',
  'privacy' => 'Privacy Policy',
  'contact' => 'Contact us',
  'signin' => 'Welcome back',
  'signup' => 'Create your account',
  // `0348`. The same words as `signin` out of the box, because the
  // page starts as a copy of it and an operator who has not edited it
  // yet should not be able to tell.
  'login' => 'Welcome back',
  _ => slug,
};


/// Back to where the reader came from, or to the front page.
///
/// This page is reached two ways and they want different answers: from
/// the footer, where the front page really is behind it, and from the
/// consent line under the register button, where a half-filled form is.
/// Sending the second reader to the front page throws away what they
/// typed -- for the crime of reading the terms they were just asked to
/// agree to.
///
/// The label follows the destination, because a button that says "Back
/// to iAkauntan" and returns to a sign-up form is a button that lied.
///
/// ## `maybeOf`, and why not `context.canPop()`
///
/// `context.canPop()` THROWS where there is no GoRouter in the tree,
/// and it is called while BUILDING rather than on a press -- so a
/// screen that used it could not be rendered at all outside a router.
/// Four assertions in `site_pages_test.dart` pump this page in a plain
/// `MaterialApp` and every one of them broke on it.
///
/// That is not only a test's problem. A screen that cannot be built
/// without a router is a screen that cannot be previewed, embedded, or
/// shown in a dialog, and it fails at build time rather than at the
/// press -- the worst moment to discover it. `GoRouter.maybeOf` answers
/// null instead, and null here means "nothing behind this page", which
/// is exactly right for a page reached without a router.
class _BackButton extends StatelessWidget {
  const _BackButton({required this.brand});

  final String brand;

  @override
  Widget build(BuildContext context) {
    final router = GoRouter.maybeOf(context);
    final canGoBack = router?.canPop() ?? false;
    return TextButton.icon(
      key: const ValueKey('site-page-back'),
      onPressed: () {
        if (canGoBack) {
          router!.pop();
        } else if (router != null) {
          router.go('/');
        }
      },
      icon: const Icon(Icons.arrow_back, size: 18),
      label: Text(canGoBack ? 'Back' : 'Back to $brand'),
    );
  }
}
