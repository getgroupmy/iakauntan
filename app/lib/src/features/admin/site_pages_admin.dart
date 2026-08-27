import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform_live.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/landing_repository.dart';
import '../../data/site_pages_repository.dart';

/// The pages beside the product, edited rather than deployed.
///
/// Five of them — the wording on the sign-in and sign-up screens, and
/// Terms, Privacy and Contact — and one screen for all five, because
/// they are the same shape: a heading and a body. Five near-identical
/// tabs would be five places to fix the same bug.
///
/// ## Two kinds of page, one form
///
/// The auth pages are a line of welcome above a form this screen does
/// not get to touch, so they always draw and there is nothing to
/// publish. The three linked pages appear in the footer only once
/// somebody has published them, which is why those three have the
/// switch and the other two do not — a switch that changes nothing is
/// worse than an absent one.
class SitePageTab extends ConsumerStatefulWidget {
  const SitePageTab({super.key, required this.slug});

  /// One of `signin`, `signup`, `terms`, `privacy`, `contact`. The
  /// saver refuses anything else, and the table refuses it again.
  final String slug;

  @override
  ConsumerState<SitePageTab> createState() => _SitePageTabState();
}

class _SitePageTabState extends ConsumerState<SitePageTab> {
  final _title = TextEditingController();
  final _body = TextEditingController();

  /// The slug the controllers currently hold text for.
  ///
  /// The console keeps one widget per route, but a rebuild after a save
  /// must not refill the boxes from the row and throw away what
  /// somebody is typing. Filling once per page is the rule, and this is
  /// what remembers that it has been done.
  String? _loadedFor;
  bool? _published;
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  /// Whether this page is one the footer links to.
  ///
  /// The two auth pages are wording on a screen that always draws.
  bool get _gated => const {'terms', 'privacy', 'contact'}.contains(widget.slug);

  @override
  Widget build(BuildContext context) {
    final pages = ref.watch(sitePageDraftsProvider);

    return AsyncView<Map<String, SitePage>>(
      value: pages,
      onRetry: () => ref.invalidate(sitePageDraftsProvider),
      builder: (rows) {
        final page = rows[widget.slug];
        if (_loadedFor != widget.slug) {
          _loadedFor = widget.slug;
          _title.text = page?.title ?? '';
          _body.text = page?.body ?? '';
          _published = page?.isPublished ?? false;
        }

        return SingleChildScrollView(
          child: PageBody(
            maxWidth: 860,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionHeader(
                  sitePageLabel(widget.slug),
                  subtitle: sitePageHint(widget.slug),
                ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(Space.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _title,
                          decoration: InputDecoration(
                            labelText: 'Heading',
                            helperText: sitePageTitleHelp(widget.slug),
                          ),
                        ),
                        const SizedBox(height: Space.md),
                        TextField(
                          controller: _body,
                          minLines: _gated ? 14 : 3,
                          maxLines: _gated ? 40 : 6,
                          decoration: const InputDecoration(
                            labelText: 'Body',
                            alignLabelWithHint: true,
                            helperText: 'Left empty, the screen uses the '
                                'wording the product ships with.',
                          ),
                        ),
                        if (_gated) ...[
                          const SizedBox(height: Space.sm),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _published ?? false,
                            onChanged: _busy
                                ? null
                                : (v) => setState(() => _published = v),
                            title: const Text('Published'),
                            subtitle: const Text(
                              'Until this is on, the page is a draft: the '
                              'footer does not link to it and a visitor '
                              'cannot reach it.',
                            ),
                          ),
                        ],
                        const SizedBox(height: Space.md),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton.icon(
                            onPressed: _busy ? null : _save,
                            icon: const Icon(Icons.save_outlined),
                            label: const Text('Save'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (widget.slug == 'signin') ...[
                  const SizedBox(height: Space.lg),
                  const _DemoAccountsCard(),
                ],
                const SizedBox(height: Space.lg),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Saved',
      // The text is sent whatever it says, empty included: an empty box
      // is somebody asking for the shipped wording back, and the saver
      // reads only an *absent* argument as "leave it alone".
      action: () => ref.read(sitePagesRepositoryProvider).save(
        widget.slug,
        title: _title.text,
        body: _body.text,
        isPublished: _gated ? (_published ?? false) : null,
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      ref.invalidate(sitePageDraftsProvider);
      // The public reader too: the sign-in screen and the three linked
      // pages read that one, and an operator who has just saved is
      // usually about to go and look.
      ref.invalidate(sitePagesProvider);
    }
  }
}

/// What to call each page, on its console section and at the top of it.
String sitePageLabel(String slug) => switch (slug) {
  'signin' => 'Sign in page',
  'signup' => 'Sign up page',
  'terms' => 'Terms of Use',
  'privacy' => 'Privacy Policy',
  'contact' => 'Contact us',
  _ => slug,
};

/// One line saying where the words actually end up.
String sitePageHint(String slug) => switch (slug) {
  'signin' => 'The line above the password box. Always shown; there is '
      'nothing to publish.',
  'signup' => 'The line above the registration form. Always shown; there '
      'is nothing to publish.',
  'terms' => 'Linked from the footer once published, and reachable at '
      '/terms.',
  'privacy' => 'Linked from the footer once published, and reachable at '
      '/privacy.',
  'contact' => 'Linked from the footer once published, and reachable at '
      '/contact.',
  _ => '',
};

String sitePageTitleHelp(String slug) => switch (slug) {
  'signin' || 'signup' => 'Shown above the form. Left empty, the screen '
      'uses its own wording.',
  _ => 'Shown at the top of the page.',
};

/// The one-tap demo logins, switched on and off.
///
/// On this screen rather than on the landing page's, because the list
/// is drawn on the sign-in screen and this is the section for it.
///
/// The switch is the *inner* of two gates and says so on the card. A
/// build made without `--dart-define=DEMO_MODE=true` does not carry the
/// demo password at all, and nothing here can put it back — so an
/// operator who turns this on and sees nothing has not found a bug.
class _DemoAccountsCard extends ConsumerStatefulWidget {
  const _DemoAccountsCard();

  @override
  ConsumerState<_DemoAccountsCard> createState() => _DemoAccountsCardState();
}

class _DemoAccountsCardState extends ConsumerState<_DemoAccountsCard> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final row = ref.watch(landingPageAdminProvider).valueOrNull;
    final on = row?['demo_accounts_enabled'] == true;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: on,
              onChanged: _busy ? null : _set,
              title: const Text('Offer the demo logins'),
              subtitle: const Text(
                'Adds the row of one-tap demo accounts under the sign-in '
                'form. Off by default. Everyone shares the same demo '
                'company, so anything a visitor changes is there for the '
                'next one.',
              ),
            ),
            const SizedBox(height: Space.sm),
            Text(
              'The app also has to be built with DEMO_MODE turned on — '
              'the demo password ships inside the bundle, so a build that '
              'did not ask for it cannot be talked into it here.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _set(bool value) async {
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: value ? 'Demo logins on' : 'Demo logins off',
      action: () => ref
          .read(landingAdminProvider)
          .saveLandingPage({'demo_accounts_enabled': value}),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      ref.invalidate(landingPageAdminProvider);
      // The sign-in screen reads `landing_page()`, not the table, so
      // this is what makes the list appear or go without a reload.
      invalidatePlatformTable(ref, 'landing_page');
    }
  }
}
