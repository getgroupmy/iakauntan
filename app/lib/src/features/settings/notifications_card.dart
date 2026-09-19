import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/push.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Turning on the notification that arrives when the app is closed.
///
/// Unlike everything else on this screen it is not company
/// configuration: permission belongs to this device, and switching it on
/// here does nothing for the same person on their other one. So it says
/// which device it is talking about.
///
/// The button asks for permission, and it only exists as a button
/// because a browser needs the prompt to come from something the person
/// pressed and iOS needs the same for the same reason: a refusal is not
/// asked again by anybody, so asking on start-up would spend that one
/// chance on somebody who had not yet decided they wanted it.
class NotificationsCard extends ConsumerWidget {
  const NotificationsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(pushStatusProvider);

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
              loading: const LinearProgressIndicator(),
              builder: (state) => _Body(state: state),
            ),
          ],
        ),
      ),
    );
  }
}

class _Body extends ConsumerStatefulWidget {
  const _Body({required this.state});

  final PushStatus state;

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
          PushStatus.on => 'This device will be notified',
          // Said as its own sentence rather than folded into a generic
          // failure: it will not ask again, and the only way back is
          // outside this app.
          PushStatus.denied =>
            defaultTargetPlatform == TargetPlatform.iOS
                ? 'This iPhone refused. Allow notifications for this app in '
                      'Settings, then try again.'
                : 'This browser refused. Allow notifications for this site '
                      'in the browser\'s own settings, then try again.',
          _ => 'Could not turn notifications on for this device',
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
      PushStatus.unsupported => const _Note(
        icon: Icons.notifications_off_outlined,
        text:
            'This device cannot be notified while the app is closed. '
            'Notifications work in Chrome, Edge and Firefox, on Safari '
            'once the app has been added to the home screen, and on '
            'iPhone. Not yet on Android.',
      ),
      PushStatus.notConfigured => const _Note(
        icon: Icons.build_outlined,
        text:
            'Notifications are not switched on for this installation. '
            'It needs a VAPID key pair — see docs/push-notifications.md.',
      ),
      PushStatus.denied => _Note(
        icon: Icons.block,
        text: defaultTargetPlatform == TargetPlatform.iOS
            ? 'This iPhone has refused notifications for this app. It '
                  'will not ask again, so it has to be turned back on in '
                  'Settings → Notifications.'
            : 'This browser has refused notifications for this site. It '
                  'will not ask again, so it has to be changed in the '
                  'browser\'s own site settings.',
      ),
      PushStatus.askable => Row(
        children: [
          const Expanded(
            child: Text(
              'Be told about messages and calls when this app is in the '
              'background. The notification says who it is from and '
              'never what it says.',
              style: TextStyle(fontSize: 12),
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
          const Expanded(
            child: Text(
              'This device will be notified about messages and calls.',
              style: TextStyle(fontSize: 12),
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
