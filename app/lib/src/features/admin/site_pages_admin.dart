import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform_live.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/landing_repository.dart';
import '../../data/site_pages_repository.dart';
import 'landing_cms.dart';

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

  /// One of `signin`, `signup`, `login`, `terms`, `privacy`, `contact`.
  /// The saver refuses anything else, and the table refuses it again.
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
  /// The three auth pages are wording on a screen that always draws —
  /// `login` joined them in `0348`, and gating it would leave a blank
  /// heading over the form at every company address at once.
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
                          decoration: InputDecoration(
                            labelText: _gated ? 'Body' : 'Line under it',
                            alignLabelWithHint: true,
                            helperText: sitePageBodyHelp(widget.slug),
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
                  const _SigninPanelCard(),
                  const SizedBox(height: Space.lg),
                  const _SigninWordsCard(),
                  const SizedBox(height: Space.lg),
                  const LandingSectionsCard(kind: 'signin'),
                  const SizedBox(height: Space.lg),
                  const _DemoAccountsCard(),
                ],
                // `0350`. The same three cards for a company's door,
                // against that page's own columns — the point of those
                // columns being that a switch flicked here does not
                // move the sign-in page.
                //
                // Three and not four. The demo logins are the
                // platform's own account fixtures and have no business
                // on a tenant's page: somebody arriving at Sinar's
                // address should not be offered a way into a
                // demonstration company.
                if (widget.slug == 'login') ...[
                  const SizedBox(height: Space.lg),
                  const _SigninPanelCard(login: true),
                  const SizedBox(height: Space.lg),
                  const _SigninWordsCard(login: true),
                  const SizedBox(height: Space.lg),
                  const LandingSectionsCard(kind: 'login'),
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
  'signin' || 'signup' => 'The line above the form — "Welcome back". Left '
      'empty, the screen uses its own wording.',
  _ => 'Shown at the top of the page.',
};

/// What the body box does, which differs on the two auth screens.
///
/// There it is a lead-in rather than a whole sentence: the screen puts
/// the company's name after it, so an operator writes the half that is
/// theirs and never has to know whose door this is.
String sitePageBodyHelp(String slug) => switch (slug) {
  'signin' => 'The line under it, without the name — "Sign in to continue '
      'to". The company\'s name, or yours, is added after it.',
  'signup' => 'The line under it, without the name — "Create your account '
      'at". Your name is added after it.',
  _ => 'Left empty, the screen uses the wording the product ships with.',
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

/// What the sign-in screen shows around the form.
///
/// Four switches and one line of copy. Every switch starts off, and
/// that is the change `0336` is: the panel used to be our mark, our
/// headline and our three claims, compiled in, on every deployment of
/// this product.
///
/// The wording of the heading itself is not here — it is the form above
/// this card, which writes `site_pages('signin')`. This is only whether
/// it is drawn, which is a different question and belongs next to the
/// other three whethers.
class _SigninPanelCard extends ConsumerStatefulWidget {
  const _SigninPanelCard({this.login = false});

  /// Whether this card dresses the login page rather than the sign-in
  /// one.
  ///
  /// `0350`. The two pages have separate columns, so this switches
  /// which set the card reads and writes — a card drawn on both tabs
  /// against one set of columns would have made a switch flicked here
  /// change the other page without saying so.
  ///
  /// Two of the switches are missing in the login case, and their
  /// absence is the point rather than an omission: a company's door
  /// always draws that company's own mark, whatever the platform's logo
  /// and name switches say, and it never offers an account. Switches
  /// that cannot change what is on the screen are worse than none.
  final bool login;

  @override
  ConsumerState<_SigninPanelCard> createState() => _SigninPanelCardState();
}

class _SigninPanelCardState extends ConsumerState<_SigninPanelCard> {
  final _headline = TextEditingController();

  /// Cloudflare Turnstile's site key (`0556`). One box rather than a
  /// switch, because there is nothing to switch on until there is a key
  /// to draw the widget with.
  final _siteKey = TextEditingController();

  /// `signin` or `login`, in front of every column this card touches.
  String get _p => widget.login ? 'login' : 'signin';

  /// Whether the box has been filled from the row yet.
  ///
  /// Once only, so a rebuild after a save does not throw away what
  /// somebody is halfway through typing.
  bool _loaded = false;
  bool _busy = false;

  @override
  void dispose() {
    _headline.dispose();
    _siteKey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final row = ref.watch(landingPageAdminProvider).valueOrNull;
    if (!_loaded && row != null) {
      _loaded = true;
      _headline.text = '${row['${_p}_headline'] ?? ''}';
      _siteKey.text = '${row['turnstile_site_key'] ?? ''}';
    }
    bool on(String key) => row?[key] == true;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Beside and around the form',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Everything here starts off. A visitor sees the sign-in '
              'form and nothing else until you switch something on.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: Space.sm),
            // Absent on the login page. A company's door draws that
            // company's mark whether these are on or off — taking
            // Sinar's logo off Sinar's door because *we* turned ours
            // off would be the wrong reading — so on that tab these two
            // would be switches with nothing behind them.
            if (!widget.login) ...[
              _Switch(
                value: on('signin_show_logo'),
                busy: _busy,
                title: 'Your logo',
                subtitle: 'On the panel beside the form, and above the '
                    'form on a phone. A company signing in at its own '
                    'subdomain always sees its own, whichever way this '
                    'is set.',
                onChanged: (v) => _save({'signin_show_logo': v}),
              ),
              _Switch(
                value: on('signin_show_name'),
                busy: _busy,
                title: 'Your name beside it',
                subtitle: 'Separate from the logo, because a logo that '
                    'already has the name in it does not want the word '
                    'next to it.',
                onChanged: (v) => _save({'signin_show_name': v}),
              ),
            ],
            _Switch(
              value: on('${_p}_show_headline'),
              busy: _busy,
              title: 'The headline',
              subtitle: 'The large line on the panel. Its wording is the '
                  'box below.',
              onChanged: (v) => _save({'${_p}_show_headline': v}),
            ),
            const SizedBox(height: Space.sm),
            TextField(
              controller: _headline,
              minLines: 2,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Headline',
                alignLabelWithHint: true,
                helperText: 'One line per line. Left empty, the panel uses '
                    'the wording the product ships with.',
              ),
            ),
            const SizedBox(height: Space.sm),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _save({'${_p}_headline': _headline.text}),
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('Save headline'),
              ),
            ),
            const Divider(height: Space.lg),
            _Switch(
              value: on('${_p}_show_heading'),
              busy: _busy,
              title: 'The heading above the form',
              subtitle: 'The line and sentence you edit at the top of this '
                  'screen. Off, the form has no heading at all.',
              onChanged: (v) => _save({'${_p}_show_heading': v}),
            ),
            // Also absent on the login page: `0336` took the offer of
            // an account off a company's door, so there is no link here
            // to switch.
            if (!widget.login)
              _Switch(
                value: on('signin_show_register'),
                busy: _busy,
                title: 'Offer an account',
                subtitle: 'Draws "New to us? Create an account" under '
                    'the button. Off, somebody can still reach the form '
                    'at /signin?mode=register, and the way back from it '
                    'is always drawn.',
                onChanged: (v) => _save({'signin_show_register': v}),
              ),
            const Divider(height: Space.lg),
            // The captcha. A box rather than a switch: there is nothing
            // to switch on until there is a key to draw the widget
            // with, and an empty box is the off position.
            TextField(
              key: const ValueKey('turnstile-site-key'),
              controller: _siteKey,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Cloudflare Turnstile site key',
                hintText: '0x4AAAAAAA…',
                helperText: 'Empty means no security check. The site key '
                    'is public; the SECRET goes in Supabase under '
                    'Authentication → Attack Protection, and the order '
                    'is: key here first, then the switch there. See '
                    'docs/captcha.md.',
                helperMaxLines: 4,
              ),
            ),
            const SizedBox(height: Space.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () => _save({'turnstile_site_key': _siteKey.text}),
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('Save site key'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save(Map<String, dynamic> patch) async {
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Saved',
      action: () => ref.read(landingAdminProvider).saveLandingPage(patch),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      ref.invalidate(landingPageAdminProvider);
      // The sign-in screen reads `landing_page()`, not the table.
      invalidatePlatformTable(ref, 'landing_page');
    }
  }
}

/// One switch, with room for a sentence saying what it actually does.
class _Switch extends StatelessWidget {
  const _Switch({
    required this.value,
    required this.busy,
    required this.title,
    required this.subtitle,
    required this.onChanged,
  });

  final bool value;
  final bool busy;
  final String title;
  final String subtitle;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    value: value,
    onChanged: busy ? null : onChanged,
    title: Text(title),
    subtitle: Text(subtitle),
  );
}

/// The words on the form itself.
///
/// Every one of them was a Dart literal until `0337`, which meant a
/// platform in Malay signed people in with an English form no matter
/// what it had written everywhere else.
///
/// Unlike the switches above, these do not default to empty: an empty
/// box means "the word the product ships with", because a form whose
/// fields have no labels is not a cleaner form.
class _SigninWordsCard extends ConsumerStatefulWidget {
  const _SigninWordsCard({this.login = false});

  /// Whether this card writes the login page's words rather than the
  /// sign-in page's. See [_SigninPanelCard.login].
  final bool login;

  @override
  ConsumerState<_SigninWordsCard> createState() => _SigninWordsCardState();
}

class _SigninWordsCardState extends ConsumerState<_SigninWordsCard> {
  /// Each console field, the column it writes and the word it replaces.
  ///
  /// A table rather than eight declared controllers, because they are
  /// eight of exactly the same thing and the shipped word belongs next
  /// to the column it is the default for.
  /// [notNull] marks the two columns that predate this screen.
  ///
  /// `sign_in_label` and `register_label` are NOT NULL with a default,
  /// so the saver reads an empty string as "leave it alone" rather than
  /// as "clear it". Emptying those boxes therefore sends the shipped
  /// word explicitly, which restores the same default the column has —
  /// so "leave a box empty to get the word under it" is true of all
  /// eight rather than of six of them.
  static const _fields =
      <({String column, String label, String ships, bool notNull})>[
    (
      column: 'signin_email_label',
      label: 'Email box',
      ships: 'Email',
      notNull: false,
    ),
    (
      column: 'signin_password_label',
      label: 'Password box',
      ships: 'Password',
      notNull: false,
    ),
    (
      column: 'signin_name_label',
      label: 'Name box, on the sign-up form',
      ships: 'Full name',
      notNull: false,
    ),
    (
      column: 'signin_forgot_label',
      label: 'The forgotten-password link',
      ships: 'Forgot password?',
      notNull: false,
    ),
    (
      column: 'sign_in_label',
      label: 'The sign-in button',
      ships: 'Sign in',
      notNull: true,
    ),
    (
      column: 'register_label',
      label: 'The sign-up button',
      ships: 'Create an account',
      notNull: true,
    ),
    (
      column: 'signin_register_prompt',
      label: 'The sentence offering an account',
      // Built from your name rather than stored, so there is no literal
      // to show here — clearing the box gives the sentence back.
      ships: 'New to <your name>? Create an account',
      notNull: false,
    ),
    (
      column: 'signin_signin_prompt',
      label: 'The sentence back to signing in',
      ships: 'Already have an account? Sign in',
      notNull: false,
    ),
  ];

  /// The login page's four, and why it is four rather than eight.
  ///
  /// `0350`. There is no sign-up form at a company's door, so the name
  /// box, the two prompts and the sign-up button have nothing to label;
  /// what is left is the two boxes, the forgotten-password link and the
  /// button. Every one of them is blankable, so "leave a box empty to
  /// get the word under it" holds for all four.
  static const _loginFields =
      <({String column, String label, String ships, bool notNull})>[
    (
      column: 'login_email_label',
      label: 'Email box',
      ships: 'Email',
      notNull: false,
    ),
    (
      column: 'login_password_label',
      label: 'Password box',
      ships: 'Password',
      notNull: false,
    ),
    (
      column: 'login_forgot_label',
      label: 'The forgotten-password link',
      ships: 'Forgot password?',
      notNull: false,
    ),
    (
      column: 'login_sign_in_label',
      label: 'The sign-in button',
      ships: 'Sign in',
      notNull: false,
    ),
  ];

  List<({String column, String label, String ships, bool notNull})>
      get _showing => widget.login ? _loginFields : _fields;

  final _controllers = <String, TextEditingController>{
    for (final f in [..._fields, ..._loginFields])
      f.column: TextEditingController(),
  };
  bool _loaded = false;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final row = ref.watch(landingPageAdminProvider).valueOrNull;
    if (!_loaded && row != null) {
      _loaded = true;
      for (final f in _showing) {
        _controllers[f.column]!.text = '${row[f.column] ?? ''}';
      }
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'The words on the form',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Leave a box empty to use the word shown under it.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: Space.sm),
            for (final f in _showing) ...[
              TextField(
                controller: _controllers[f.column],
                decoration: InputDecoration(
                  labelText: f.label,
                  helperText: 'Ships as "${f.ships}"',
                ),
              ),
              const SizedBox(height: Space.md),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _busy ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Save words'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    // Every field, empty included: an empty box is somebody asking for
    // the shipped word back, and the saver reads only an *absent* key
    // as "leave it alone".
    final patch = <String, dynamic>{
      for (final f in _showing)
        f.column: _controllers[f.column]!.text.trim().isEmpty && f.notNull
            ? f.ships
            : _controllers[f.column]!.text,
    };
    final ok = await runWithFeedback(
      context,
      successMessage: 'Saved',
      action: () => ref.read(landingAdminProvider).saveLandingPage(patch),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      ref.invalidate(landingPageAdminProvider);
      invalidatePlatformTable(ref, 'landing_page');
    }
  }
}
