import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error_text.dart';
import '../../core/format.dart';
import '../../core/platform_live.dart';
import '../../core/providers.dart';
import '../../core/safe_link.dart';
import '../../core/skeletons.dart';
import '../../core/splash.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/landing_repository.dart';
import '../landing/splash_screen.dart';
import 'branding_admin.dart' show mimeForExtension;
import 'app_release.dart';

/// Everything about the iOS and Android builds, in one place.
///
/// Asked for as a console page called "Mobile Application" where the
/// mobile settings are done, and the splash picture is the first of
/// them.
///
/// ## What is here and what is deliberately not
///
/// The settings on this page are the ones that are ABOUT the apps: the
/// splash screen, which only the apps have, and the way to the demo
/// logins, which is a link in the apps and a panel on the web.
///
/// The per-platform switches that belong to a PAGE stayed on that
/// page's own tab — whether the apps link Terms of Use is a fact about
/// Terms of Use, and the operator who has just published it is standing
/// on that tab. The same goes for the passkey and register switches,
/// which are on the sign-in page's tab beside the web's own. Moving
/// them here would have meant two consoles that both claim to be where
/// the apps are configured, and the card at the bottom of this page
/// says where each of them is instead of pretending they do not exist.
class MobileAppAdminTab extends ConsumerStatefulWidget {
  const MobileAppAdminTab({super.key});

  @override
  ConsumerState<MobileAppAdminTab> createState() => _MobileAppAdminTabState();
}

class _MobileAppAdminTabState extends ConsumerState<MobileAppAdminTab> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final page = ref.watch(landingPageAdminProvider);

    return AsyncView<Map<String, dynamic>?>(
      value: page,
      onRetry: () => ref.invalidate(landingPageAdminProvider),
      // The store links and the three release cards, which are the same
      // cards whether or not the row has anything in it -- this screen
      // draws them for a page that has never been saved.
      skeleton: const Padding(
        padding: EdgeInsets.all(Space.lg),
        child: CardRowsSkeleton(
          rows: 5,
          leadingSize: 24,
          trailing: 1,
          rowGap: Space.lg,
        ),
      ),
      builder: (row) {
        final r = row ?? const <String, dynamic>{};
        String? text(String key) {
          final s = r[key]?.toString().trim();
          return (s == null || s.isEmpty) ? null : s;
        }

        return SingleChildScrollView(
          child: PageBody(
            maxWidth: 980,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader(
                  'Mobile Application',
                  subtitle:
                      'The iOS and Android builds. Nothing here changes '
                      'the website.',
                ),
                _SplashCard(
                  uploaded: text('splash_image_url'),
                  logo: text('logo_url'),
                  logoDark: text('logo_dark_url'),
                  wordmark: text('wordmark') ?? 'iAkauntan',
                  busy: _busy,
                  onUpload: _uploadSplash,
                  onClear: () => _save({'splash_image_url': ''}),
                ),
                const SizedBox(height: Space.lg),
                _DemoLinkCard(
                  // Ships off, so absent reads as off -- the opposite
                  // of the legal links, and for the reason the card
                  // spells out.
                  ios: r['signin_show_demo_page_ios'] == true,
                  android: r['signin_show_demo_page_android'] == true,
                  offeredAtAll: r['demo_accounts_enabled'] == true,
                  busy: _busy,
                  onChanged: (patch) => _save(patch),
                ),
                const SizedBox(height: Space.lg),
                // A card each, because they are two products with two
                // stores, two sets of destinations and two very
                // different costs — and one of them can be set up
                // while the other is not.
                const _ReleaseCard(ReleasePlatform.ios),
                const SizedBox(height: Space.lg),
                const _ReleaseCard(ReleasePlatform.android),
                const SizedBox(height: Space.lg),
                const _BothCard(),
                const SizedBox(height: Space.lg),
                const _ElsewhereCard(),
                const SizedBox(height: Space.lg),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _uploadSplash() async {
    final result = await FilePicker.platform.pickFiles(
      withData: true,
      type: FileType.image,
    );
    final file = result?.files.singleOrNull;
    if (file == null || file.bytes == null || !mounted) return;

    setState(() => _busy = true);
    String? url;
    final ok = await runWithFeedback(
      context,
      successMessage: 'Uploaded',
      action: () async {
        url = await ref
            .read(landingAdminProvider)
            .uploadLandingLogo(
              file.bytes!,
              'splash_image_url',
              contentType: mimeForExtension(file.extension),
            );
      },
    );
    if (!mounted) return;
    setState(() => _busy = false);
    // Saved rather than held as a draft, unlike the branding screen's
    // uploads. There is one field on this card and no Save button
    // beside it, so a picture that uploaded and did not save would be
    // an upload that appeared to do nothing.
    if (ok && url != null) await _save({'splash_image_url': url});
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
      // The apps read `landing_page()`, not the table, so this is what
      // makes a new splash picture reach a phone without a new build.
      invalidatePlatformTable(ref, 'landing_page');
    }
  }
}

/// The splash picture, with both backgrounds it will actually sit on.
///
/// Two previews rather than one, for the reason `branding_admin.dart`
/// shows the logo twice: a mark composed for a white page disappears on
/// black, and the splash is the one screen where nobody is looking at
/// anything else.
class _SplashCard extends StatelessWidget {
  const _SplashCard({
    required this.uploaded,
    required this.logo,
    required this.logoDark,
    required this.wordmark,
    required this.busy,
    required this.onUpload,
    required this.onClear,
  });

  final String? uploaded;
  final String? logo;
  final String? logoDark;
  final String wordmark;
  final bool busy;
  final VoidCallback onUpload;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final seconds = splashHold.inSeconds;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Splash screen',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'The first screen the apps draw, held for $seconds seconds '
              'while they start. Upload a picture, or leave this empty '
              'and your logo is used — on white in light mode and on '
              'black in dark. The website has no splash screen.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: Space.md),
            Row(
              children: [
                Expanded(
                  child: _SplashPreview(
                    label: 'Light',
                    dark: false,
                    image: splashImage(
                      uploaded: uploaded,
                      logo: logo,
                      logoDark: logoDark,
                      dark: false,
                    ),
                    wordmark: wordmark,
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: _SplashPreview(
                    label: 'Dark',
                    dark: true,
                    image: splashImage(
                      uploaded: uploaded,
                      logo: logo,
                      logoDark: logoDark,
                      dark: true,
                    ),
                    wordmark: wordmark,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.md),
            Wrap(
              spacing: Space.sm,
              runSpacing: Space.sm,
              children: [
                FilledButton.icon(
                  key: const ValueKey('splash-upload'),
                  onPressed: busy ? null : onUpload,
                  icon: const Icon(Icons.upload_outlined, size: 18),
                  label: const Text('Upload a picture'),
                ),
                if (uploaded != null)
                  OutlinedButton.icon(
                    key: const ValueKey('splash-clear'),
                    onPressed: busy ? null : onClear,
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('Use the logo instead'),
                  ),
              ],
            ),
            const SizedBox(height: Space.sm),
            Text(
              'PNG, JPEG or WebP. Both previews show what a phone will '
              'draw, including the background — the splash is not in '
              'your brand colour, because a logo drawn for white on top '
              'of a colour is the one thing that cannot be corrected '
              'from here.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// One of the two previews.
class _SplashPreview extends StatelessWidget {
  const _SplashPreview({
    required this.label,
    required this.dark,
    required this.image,
    required this.wordmark,
  });

  final String label;
  final bool dark;
  final String? image;
  final String wordmark;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.md),
          child: SizedBox(
            height: 220,
            // The real thing, not an impression of it. `SplashView` is
            // what a phone draws, so a picture that is wrong here is
            // wrong there.
            child: SplashView(image: image, wordmark: wordmark, dark: dark),
          ),
        ),
      ],
    );
  }
}

/// Whether the apps offer the way to the demo logins page.
///
/// Off on both out of the box, and the card says why rather than
/// leaving an operator to wonder why this one switch is different: the
/// demo password is compiled into the app bundle and readable by
/// anybody who opens it.
class _DemoLinkCard extends StatelessWidget {
  const _DemoLinkCard({
    required this.ios,
    required this.android,
    required this.offeredAtAll,
    required this.busy,
    required this.onChanged,
  });

  final bool ios;
  final bool android;

  /// `demo_accounts_enabled`, the switch on the sign-in page's tab.
  /// Shown rather than repeated: these two are ANDed with it, and a
  /// switch turned on here while that is off does nothing.
  final bool offeredAtAll;

  final bool busy;
  final ValueChanged<Map<String, dynamic>> onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'The demo logins page',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Adds "Look around a demo" under the sign-in form in the '
              'apps, opening a page of one-tap demo accounts. The '
              'website keeps the panel it has always had under the '
              'form — twelve rows are a long way down a phone.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: Space.sm),
            SwitchListTile(
              key: const ValueKey('demo-page-ios'),
              contentPadding: EdgeInsets.zero,
              value: ios,
              onChanged: busy
                  ? null
                  : (v) => onChanged({'signin_show_demo_page_ios': v}),
              title: const Text('Offer it in the iOS app'),
            ),
            SwitchListTile(
              key: const ValueKey('demo-page-android'),
              contentPadding: EdgeInsets.zero,
              value: android,
              onChanged: busy
                  ? null
                  : (v) => onChanged({'signin_show_demo_page_android': v}),
              title: const Text('Offer it in the Android app'),
            ),
            const SizedBox(height: Space.sm),
            Text(
              offeredAtAll
                  ? 'Two more things have to be true as well: the build '
                        'has to be made with DEMO_MODE turned on, and '
                        'the page is never offered at a company\'s own '
                        'address.'
                  : '"Offer the demo logins" is OFF on the Sign in page, '
                        'so neither of these draws anything yet. It is '
                        'the switch above these two, not beside them.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: Space.sm),
            Text(
              'These ship off, unlike the links on the Terms and Privacy '
              'pages, because the demo password is compiled into the app '
              'and anybody who opens it can read it. Delete the demo '
              'users before this deployment holds real books.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.colors.danger,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Where the rest of the mobile settings live.
///
/// A page called "Mobile Application" invites the belief that
/// everything about the apps is on it. Four switches are not, for a
/// reason each, and saying so here is cheaper than an operator
/// concluding the passkey switch does not exist.
class _ElsewhereCard extends StatelessWidget {
  const _ElsewhereCard();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'The rest of the app settings, and where they are',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Each of these belongs to a page rather than to the apps, '
              'so it is on that page — beside the same switch for the '
              'website, where the two can be compared.',
              style: style,
            ),
            const SizedBox(height: Space.sm),
            _Elsewhere(
              icon: Icons.gavel_outlined,
              title: 'Linking Terms of Use, Terms of Service and Privacy',
              where: 'on each of those three pages',
              style: style,
            ),
            _Elsewhere(
              icon: Icons.fingerprint,
              title: 'The passkey button in each app',
              where: 'Sign in page',
              style: style,
            ),
            _Elsewhere(
              icon: Icons.person_add_alt_outlined,
              title: 'Offering an account in the apps',
              where: 'Sign in page',
              style: style,
            ),
            _Elsewhere(
              icon: Icons.science_outlined,
              title: 'Offering the demo logins at all',
              where: 'Sign in page',
              style: style,
            ),
            _Elsewhere(
              icon: Icons.image_outlined,
              title: 'The logo the splash falls back to',
              where: 'Branding',
              style: style,
            ),
          ],
        ),
      ),
    );
  }
}

class _Elsewhere extends StatelessWidget {
  const _Elsewhere({
    required this.icon,
    required this.title,
    required this.where,
    required this.style,
  });

  final IconData icon;
  final String title;
  final String where;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text('$title — $where', style: style)),
        ],
      ),
    );
  }
}

/// What somebody here can say about a release, and what nobody can.
///
/// Both lanes are worth showing because they are genuinely different
/// decisions, not two buttons for one thing.
String releaseBlurb(String choice) => switch (choice) {
  'testflight' =>
    'Builds and uploads to TestFlight. Your own testers can install it '
        'within minutes of Apple finishing processing.',
  'appstore' =>
    'Builds and uploads the same way, then you submit it for review in '
        'App Store Connect. Apple\'s review takes hours to days and '
        'nothing here can shorten it.',
  'internal' =>
    'Builds and uploads to the internal testing track. The testers on '
        'that track can install it once Play has processed it, with no '
        'review.',
  'production' =>
    'Builds, uploads, and rolls out to everybody. Play reviews it '
        'first, which takes hours to days and nothing here can '
        'shorten.',
  // Alpha and beta are both closed testing and behave the same way,
  // so they share a sentence — named explicitly rather than left to
  // the fallback, because the fallback has to stay free for the case
  // below.
  'alpha' || 'beta' =>
    'Builds and uploads to that closed testing track. Play reviews a '
        'first release to it, and testers get it after that.',
  // A destination this build does not know. It gets the most cautious
  // sentence there is, and deliberately does not name a store: the
  // only safe thing to say about an unrecognised destination is that
  // it might be public and might be reviewed.
  _ =>
    'Builds and uploads. This destination is not one this screen '
        'recognises, so check where it goes before pressing — it may '
        'reach the public, and a store review may apply.',
};

/// A run, in a word.
///
/// GitHub gives a status and a conclusion, and the pair is what means
/// something: `completed` alone does not say whether it worked, and a
/// conclusion is null for as long as it is running.
({String label, IconData icon}) releaseState(
  String status,
  String? conclusion,
) {
  if (status != 'completed') {
    return (label: 'Building', icon: Icons.sync);
  }
  return switch (conclusion) {
    'success' => (label: 'Uploaded', icon: Icons.check_circle_outline),
    'cancelled' => (label: 'Cancelled', icon: Icons.block),
    // Named rather than folded into "failed": a build that ran out of
    // its ninety minutes and one that was refused by Apple need
    // different things looking at.
    'timed_out' => (label: 'Timed out', icon: Icons.timer_off_outlined),
    _ => (label: 'Failed', icon: Icons.error_outline),
  };
}

/// Build the app and hand it to Apple.
///
/// The button is here rather than anywhere else because this is the
/// page for everything the mobile applications need, and a release is
/// the last of those things.
///
/// What it does NOT do is build. Xcode runs on Apple hardware, and
/// neither Supabase nor Vercel is that — so this asks
/// `.github/workflows/ios-release.yml`, on a macOS runner, through the
/// `ios-release` function, which is the only party here holding a
/// token that can start it. The console never sees a signing
/// certificate or an App Store key.
class _ReleaseCard extends ConsumerStatefulWidget {
  const _ReleaseCard(this.platform);

  final ReleasePlatform platform;

  @override
  ConsumerState<_ReleaseCard> createState() => _ReleaseCardState();
}

class _ReleaseCardState extends ConsumerState<_ReleaseCard> {
  final _notes = TextEditingController();
  late String _choice = widget.platform.choices.first;
  bool _busy = false;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _release() async {
    // Asked out loud, because this signs a build with a distribution
    // certificate and puts it in front of Apple under the company's
    // name. It is also the one button on this page that costs money.
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Release the ${widget.platform.label} app?'),
        content: Text(
          '${releaseBlurb(_choice)}\n\n'
          '${widget.platform.buildTime}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Start the build'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;

    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Building. It appears below in a moment.',
      action: () => ref.read(platformRepoProvider).releaseApp(
        widget.platform,
        choice: _choice,
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      _notes.clear();
      ref.invalidate(appReleasesProvider(widget.platform));
    }
  }

  @override
  Widget build(BuildContext context) {
    final runs = ref.watch(appReleasesProvider(widget.platform));
    // `valueOrNull` and not `.value`: this is read on every build,
    // including the one where the provider is still in flight or has
    // failed, and `.value` throws on both. Unknown reads as "set up"
    // so the button is not disabled by a provider that has not
    // answered yet -- a 503 from pressing it is recoverable, a button
    // that is dead while the page loads looks broken.
    final unavailable = runs.valueOrNull?.unavailable;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              widget.platform.title,
              subtitle: widget.platform.subtitle,
            ),
            SegmentedButton<String>(
              // Four destinations on Android, so it has to be allowed
              // to wrap rather than overflow a narrow card.
              segments: [
                for (var i = 0; i < widget.platform.choices.length; i++)
                  ButtonSegment(
                    value: widget.platform.choices[i],
                    label: Text(widget.platform.labels[i]),
                  ),
              ],
              selected: {_choice},
              showSelectedIcon: false,
              onSelectionChanged: _busy
                  ? null
                  : (s) => setState(() => _choice = s.first),
            ),
            const SizedBox(height: Space.sm),
            Text(
              releaseBlurb(_choice),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _notes,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'What changed',
                helperText: 'Optional, and for your own records',
              ),
            ),
            const SizedBox(height: Space.md),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                key: ValueKey('start-${widget.platform.name}-release'),
                onPressed: _busy || unavailable != null ? null : _release,
                icon: Icon(
                  widget.platform == ReleasePlatform.ios
                      ? Icons.ios_share
                      : Icons.android,
                  size: 18,
                ),
                label: const Text('Start the build'),
              ),
            ),
            const Divider(height: Space.xl),
            Text(
              'Recent builds',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: Space.sm),
            AsyncView<AppReleases>(
              value: runs,
              onRetry: () =>
                  ref.invalidate(appReleasesProvider(widget.platform)),
              skeleton: const CardRowsSkeleton(
                rows: 3,
                leadingSize: 24,
                trailing: 1,
              ),
              builder: (result) {
                if (!result.isConfigured) {
                  return _NotSetUp(result.unavailable!);
                }
                if (result.runs.isEmpty) {
                  return Text(
                    'Nothing yet.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  );
                }
                return Column(
                  children: [
                    for (final run in result.runs)
                      _ReleaseRow(
                        number: (run['number'] as num?)?.toInt() ?? 0,
                        status: run['status']?.toString() ?? 'unknown',
                        conclusion: run['conclusion']?.toString(),
                        startedAt: run['startedAt']?.toString(),
                        url: run['url']?.toString() ?? '',
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Releasing has not been set up here yet, said as a fact.
///
/// NOT `ErrorState`. That draws a red exclamation, the words "Something
/// went wrong" and whatever the exception stringified to — which for
/// this is `FunctionException(status: 503, details: {error: ...})`,
/// shown to somebody whose only mistake is not having added a secret
/// they were never told to add.
///
/// The same judgement `.github/workflows/ios-release.yml` makes when it
/// checks its own secrets and stops rather than failing, and the same
/// one `send-push` makes about a missing VAPID pair. Nothing here is
/// broken; a setup has not been finished.
class _NotSetUp extends StatelessWidget {
  const _NotSetUp(this.said);

  /// The function's own sentence, which names what is missing. Shown
  /// rather than replaced with wording from here: the function knows
  /// which secret it looked for and this screen does not.
  final String said;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('ios-release-not-set-up'),
      width: double.infinity,
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.settings_outlined, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(
                  'Not set up yet',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.xs),
          Text(
            said,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: Space.sm),
          Text(
            'Until then the button above is off. Nothing is broken and '
            'nothing has failed — the Mac that would do the building '
            'has not been given anything to sign with.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _ReleaseRow extends StatelessWidget {
  const _ReleaseRow({
    required this.number,
    required this.status,
    required this.conclusion,
    required this.startedAt,
    required this.url,
  });

  final int number;
  final String status;
  final String? conclusion;
  final String? startedAt;
  final String url;

  @override
  Widget build(BuildContext context) {
    final state = releaseState(status, conclusion);
    final when = startedAt == null ? null : DateTime.tryParse(startedAt!);

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(state.icon, size: 20),
      // The build number, which is what App Store Connect shows beside
      // the build and therefore the only thing that lets somebody match
      // a row here to a row there.
      title: Text('Build $number — ${state.label}'),
      subtitle: when == null ? null : Text(Fmt.dateTime(when)),
      trailing: url.isEmpty
          ? null
          : IconButton(
              tooltip: 'Open the log',
              icon: const Icon(Icons.open_in_new, size: 18),
              onPressed: () => launchExternal(url),
            ),
    );
  }
}

/// Both at once, for the ordinary case where a change belongs on both
/// phones.
///
/// It is two dispatches, not one, and that is the thing this card has
/// to be honest about. The workflows are independent: they run on
/// different runners, take different times, and one can succeed while
/// the other fails. Nothing here is a transaction, so the copy says
/// "starts both" rather than anything that sounds atomic, and the
/// result is reported per platform.
///
/// It sends each platform's FIRST destination — TestFlight and
/// internal testing — rather than whatever the cards above happen to
/// have selected. Two reasons. A button that silently depends on the
/// state of two other cards is a button whose effect you cannot read
/// off the screen. And these are the two destinations that reach
/// testers without a review, which is what "build both" is almost
/// always for; releasing to a store is a decision worth making one
/// platform at a time, on the card that explains it.
class _BothCard extends ConsumerStatefulWidget {
  const _BothCard();

  @override
  ConsumerState<_BothCard> createState() => _BothCardState();
}

class _BothCardState extends ConsumerState<_BothCard> {
  final _notes = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _releaseBoth() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Release both apps?'),
        content: const Text(
          'Starts two builds: iOS to TestFlight and Android to the '
          'internal testing track.\n\n'
          'They are independent — separate runners, different '
          'durations, and one can fail while the other succeeds. '
          'Neither reaches the public.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Start both'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;

    setState(() => _busy = true);
    final notes = _notes.text.trim().isEmpty ? null : _notes.text.trim();
    final repo = ref.read(platformRepoProvider);

    // Sequential, and each failure named. Starting them together with
    // `Future.wait` would abandon the second the moment the first
    // threw, and report one error for two attempts — so a green
    // Android build would go unmentioned because iOS refused.
    final failures = <String>[];
    for (final platform in ReleasePlatform.values) {
      try {
        await repo.releaseApp(
          platform,
          choice: platform.choices.first,
          notes: notes,
        );
      } catch (e) {
        failures.add('${platform.label}: ${errorText(e)}');
      }
      ref.invalidate(appReleasesProvider(platform));
    }

    if (!mounted) return;
    setState(() => _busy = false);

    final (said, ok) = switch (failures.length) {
      0 => ('Both building. They appear in the cards above.', true),
      final n when n == ReleasePlatform.values.length =>
        ('Neither started. ${failures.first}', false),
      // The half-success, which is the case worth wording carefully:
      // one build IS running, and somebody who reads this as a plain
      // failure will press again and start a second one.
      _ => ('One started, one did not — ${failures.first}', false),
    };
    if (ok) _notes.clear();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(said),
          backgroundColor:
              ok ? context.colors.success : context.colors.danger,
          duration: Duration(seconds: ok ? 4 : 6),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    // Disabled only when BOTH are unconfigured. With one set up, this
    // still does something useful and says which half failed.
    final configured = ReleasePlatform.values.any(
      (p) => ref.watch(appReleasesProvider(p)).valueOrNull?.unavailable == null,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'Release both apps',
              subtitle: 'iOS to TestFlight and Android to internal testing',
            ),
            Text(
              'Two builds, started together. They run independently, so '
              'one can finish long before the other — and one can fail '
              'on its own.',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _notes,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'What changed',
                helperText: 'Optional, and sent to both',
              ),
            ),
            const SizedBox(height: Space.md),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                key: const ValueKey('start-both-releases'),
                onPressed: _busy || !configured ? null : _releaseBoth,
                icon: const Icon(Icons.phone_iphone, size: 18),
                label: const Text('Start both builds'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
