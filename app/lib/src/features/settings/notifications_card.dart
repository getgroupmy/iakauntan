import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/push.dart';
import '../../core/surface.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// What to call the thing being notified, on the build looking at it.
///
/// Four words of copy with a reason behind them: permission belongs to
/// this browser on this machine, or to this app on this handset, and
/// switching it on here does nothing for the same person anywhere else.
/// A card that said "you" would be describing something that does not
/// exist.
String pushDeviceNoun(Surface surface) =>
    surface == Surface.web ? 'browser' : 'device';

/// Why this build cannot be notified at all, said usefully.
///
/// Three different facts wearing one [PushStatus], and the difference
/// matters to whoever is reading: a browser is missing a feature and
/// could be swapped, an Android build is missing a Firebase project
/// that somebody has to create, and a desktop simply is not a thing
/// this is built for.
String pushUnsupportedNote(Surface surface) => switch (surface) {
  Surface.web =>
    'This browser cannot be notified while the app is closed. '
        'Notifications work in Chrome, Edge and Firefox, and on Safari '
        'once the app has been added to the home screen.',
  Surface.android =>
    'Notifications on Android go through Firebase, and this build has '
        'no Firebase project. See docs/push-notifications.md.',
  // iOS reaches this only on a build whose Dart is ahead of its
  // AppDelegate, which is a rebuild rather than anything a person can
  // act on. Said the same way as a desktop, which simply is not a thing
  // this is built for.
  Surface.ios || Surface.desktop =>
    'This device cannot be notified while the app is closed.',
};

/// Turning on the notification that arrives when the app is closed.
///
/// Unlike everything else on this screen it is not company
/// configuration: permission belongs to this browser on this machine,
/// or to this app on this handset, and switching it on here does
/// nothing for the same person anywhere else. So it says which device
/// it is talking about.
///
/// The button asks for permission, and it only exists as a button
/// because of Safari and iOS alike: the prompt has to come from
/// something the person pressed, and neither will ask a second time
/// once refused. Asking on start-up would spend that one chance on
/// somebody who had not yet decided they wanted it.
class NotificationsCard extends ConsumerWidget {
  const NotificationsCard({super.key, this.surface});

  /// Which build this is, overridable so a test can be both.
  ///
  /// `currentSurface` reads `kIsWeb`, which is a compile-time constant:
  /// a widget test on the Dart VM can never see the browser half of the
  /// copy below, and a test that cannot see half of what it covers is
  /// half a test.
  final Surface? surface;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(pushStatusProvider);
    final surface = this.surface ?? currentSurface;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'Notifications',
              subtitle: 'Being told when the app is closed',
            ),
            AsyncView(
              value: status,
              onRetry: () => ref.invalidate(pushStatusProvider),
              // One row, whatever the answer turns out to be: a
              // sentence about where notifications stand and a button
              // to change it. Which sentence and which button depend on
              // the status; that there is one of each does not.
              skeleton: const CardRowsSkeleton(
                rows: 1,
                leading: false,
                lines: 1,
                trailing: 1,
                trailingWidth: 96,
              ),
              builder: (state) => _Body(state: state, surface: surface),
            ),
          ],
        ),
      ),
    );
  }
}

class _Body extends ConsumerStatefulWidget {
  const _Body({required this.state, required this.surface});

  final PushStatus state;
  final Surface surface;

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> {
  bool _busy = false;

  Future<void> _turnOn() async {
    setState(() => _busy = true);
    final result = await enablePush(ref.read(repoProvider));
    ref.invalidate(pushStatusProvider);
    if (!mounted) return;
    setState(() => _busy = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(switch (result) {
          PushStatus.on => 'This ${pushDeviceNoun(widget.surface)} will be notified',
          // Said as its own sentence rather than folded into a generic
          // failure: nothing will ask again, and the only way back is
          // settings this app cannot open.
          PushStatus.denied => widget.surface == Surface.web
              ? 'This browser refused. Allow notifications for this site '
                    'in the browser\'s own settings, then try again.'
              : 'Notifications were refused. iOS will not ask again — '
                    'allow them for iAkauntan in Settings, then try again.',
          _ => 'Could not turn notifications on for this ${pushDeviceNoun(widget.surface)}',
        }),
      ),
    );
  }

  Future<void> _turnOff() async {
    setState(() => _busy = true);
    await disablePush(ref.read(repoProvider));
    ref.invalidate(pushStatusProvider);
    if (!mounted) return;
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return switch (widget.state) {
      // Not a failure and not worth a warning colour: this build simply
      // has no way to do it, and saying which one would be needed is
      // more useful than an apology.
      PushStatus.unsupported => _Note(
        icon: Icons.notifications_off_outlined,
        text: pushUnsupportedNote(widget.surface),
      ),
      PushStatus.notConfigured => const _Note(
        icon: Icons.build_outlined,
        text:
            'Notifications are not switched on for this installation. '
            'It needs a VAPID key pair — see docs/push-notifications.md.',
      ),
      PushStatus.denied => _Note(
        icon: Icons.block,
        text: widget.surface == Surface.web
            ? 'This browser has refused notifications for this site. It '
                  'will not ask again, so it has to be changed in the '
                  'browser\'s own site settings.'
            : 'Notifications were refused on this device. iOS will not '
                  'ask again, so they have to be allowed for iAkauntan '
                  'in Settings.',
      ),
      PushStatus.askable => Row(
        children: [
          Expanded(
            child: Text(
              'Be told about messages and calls when this '
              '${pushDeviceNoun(widget.surface)} is in the background. The '
              'notification says who it is from and never what it says.',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(width: Space.md),
          FilledButton.icon(
            key: const ValueKey('enable-push'),
            onPressed: _busy ? null : _turnOn,
            icon: const Icon(Icons.notifications_active_outlined, size: 18),
            label: const Text('Turn on'),
          ),
        ],
      ),
      PushStatus.on => Row(
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 18,
            color: context.colors.success,
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              'This ${pushDeviceNoun(widget.surface)} will be notified about messages '
              'and calls.',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          TextButton(
            key: const ValueKey('disable-push'),
            onPressed: _busy ? null : _turnOff,
            child: const Text('Turn off'),
          ),
        ],
      ),
    };
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 16,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: Space.sm),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
