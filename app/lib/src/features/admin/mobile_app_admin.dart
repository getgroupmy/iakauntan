import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
                const _ReleaseCard(),
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
String releaseBlurb(String lane) => switch (lane) {
  'testflight' =>
    'Builds and uploads to TestFlight. Your own testers can install it '
        'within minutes of Apple finishing processing.',
  _ =>
    'Builds and uploads, ready to submit for review. Apple\'s review '
        'takes hours to days and nothing here can shorten it.',
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
  const _ReleaseCard();

  @override
  ConsumerState<_ReleaseCard> createState() => _ReleaseCardState();
}

class _ReleaseCardState extends ConsumerState<_ReleaseCard> {
  final _notes = TextEditingController();
  String _lane = 'testflight';
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
        title: Text(
          _lane == 'appstore' ? 'Release to the App Store?' : 'Send to TestFlight?',
        ),
        content: Text(
          '${releaseBlurb(_lane)}\n\n'
          'It builds on a Mac, which takes twenty to thirty minutes.',
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
      action: () => ref.read(platformRepoProvider).releaseIosApp(
        lane: _lane,
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      _notes.clear();
      ref.invalidate(iosReleasesProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final runs = ref.watch(iosReleasesProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'Release the iOS app',
              subtitle: 'Builds on a Mac and uploads to App Store Connect',
            ),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'testflight', label: Text('TestFlight')),
                ButtonSegment(value: 'appstore', label: Text('App Store')),
              ],
              selected: {_lane},
              onSelectionChanged: _busy
                  ? null
                  : (s) => setState(() => _lane = s.first),
            ),
            const SizedBox(height: Space.sm),
            Text(
              releaseBlurb(_lane),
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
                key: const ValueKey('start-ios-release'),
                onPressed: _busy ? null : _release,
                icon: const Icon(Icons.ios_share, size: 18),
                label: const Text('Start the build'),
              ),
            ),
            const Divider(height: Space.xl),
            Text(
              'Recent builds',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: Space.sm),
            AsyncView(
              value: runs,
              onRetry: () => ref.invalidate(iosReleasesProvider),
              skeleton: const CardRowsSkeleton(
                rows: 3,
                leadingSize: 24,
                trailing: 1,
              ),
              builder: (list) => list.isEmpty
                  ? Text(
                      'Nothing yet.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    )
                  : Column(
                      children: [
                        for (final run in list)
                          _ReleaseRow(
                            number: (run['number'] as num?)?.toInt() ?? 0,
                            status: run['status']?.toString() ?? 'unknown',
                            conclusion: run['conclusion']?.toString(),
                            startedAt: run['startedAt']?.toString(),
                            url: run['url']?.toString() ?? '',
                          ),
                      ],
                    ),
            ),
          ],
        ),
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
