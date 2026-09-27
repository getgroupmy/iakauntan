import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error_text.dart';
import '../../core/format.dart';
import '../../core/picker_options.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/time_terminals_repository.dart';

/// The clocks on the walls.
///
/// `0612`. A biometric terminal has no login — `clock_in` reads
/// `auth.uid()` and a device bolted to a door frame has no session — so
/// it proves itself with a secret issued here.
///
/// ## The secret is shown once
///
/// The database stores a bcrypt hash and there is nothing to read back,
/// which is the point: a secret a support call can recover is a secret
/// anybody who can impersonate a support call can recover. So the
/// dialog that shows it says so, offers to copy it, and will not close
/// on a stray tap outside.
///
/// ## Punches that matched nobody
///
/// Their own list, and not a footnote. A finger nobody enrolled is a
/// day somebody is about to be short, and the only moment anybody finds
/// out is when they look at their payslip — unless this screen says so
/// first.
class TimeTerminalsTab extends ConsumerWidget {
  const TimeTerminalsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final terminals = ref.watch(timeTerminalsProvider);

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('add-terminal'),
        onPressed: () => _addTerminal(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add a terminal'),
      ),
      body: AsyncView(
        value: terminals,
        onRetry: () => ref.invalidate(timeTerminalsProvider),
        skeleton: const ListSkeleton(rows: 6, leading: false),
        builder: (list) => ListView(
          padding: const EdgeInsets.all(Space.lg),
          children: [
            PageBody(
              maxWidth: 900,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (list.isEmpty)
                    const EmptyState(
                      icon: Icons.fingerprint,
                      title: 'No clocks yet',
                      message:
                          'A biometric terminal posts its punches here. '
                          'Adding one gives you a secret to put into the '
                          'device — it is shown once and cannot be read '
                          'back afterwards.',
                    )
                  else
                    for (final t in list)
                      _TerminalCard(terminal: t),
                  const SizedBox(height: Space.xl),
                  const _UnmatchedPunches(),
                  const SizedBox(height: Space.xxl),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addTerminal(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController();
    final deviceRef = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a terminal'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey('terminal-name'),
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Front door',
                  helperText: 'What people call it. It goes on the '
                      'attendance record.',
                ),
              ),
              const SizedBox(height: Space.lg),
              TextField(
                controller: deviceRef,
                decoration: const InputDecoration(
                  labelText: 'Device serial (optional)',
                  helperText: 'Recorded, not trusted — the secret is what '
                      'proves the device.',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    if (name.text.trim().isEmpty) return;

    final repo = ref.read(timeTerminalsRepoProvider);
    if (repo == null) return;

    try {
      final made = await repo.register(
        name: name.text.trim(),
        deviceRef: deviceRef.text,
      );
      ref.invalidate(timeTerminalsProvider);
      if (!context.mounted) return;
      await _showSecret(context, name.text.trim(), made.secret);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }
}

/// The one time anybody sees it.
///
/// `barrierDismissible: false`, because a stray tap outside this dialog
/// loses a secret that cannot be recovered — only replaced, which means
/// walking back to the device.
Future<void> _showSecret(
  BuildContext context,
  String name,
  String secret,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (context) => AlertDialog(
    title: Text('$name — its secret'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Put this into the device. It is not stored anywhere you can '
            'read it back from — if it is lost, issue a new one and '
            'reconfigure the device.',
          ),
          const SizedBox(height: Space.lg),
          SelectableText(
            secret,
            key: const ValueKey('terminal-secret'),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
        ],
      ),
    ),
    actions: [
      TextButton.icon(
        onPressed: () => Clipboard.setData(ClipboardData(text: secret)),
        icon: const Icon(Icons.copy, size: 18),
        label: const Text('Copy'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('I have it'),
      ),
    ],
  ),
);

class _TerminalCard extends ConsumerWidget {
  const _TerminalCard({required this.terminal});

  final TimeTerminal terminal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant);

    return Card(
      margin: const EdgeInsets.only(bottom: Space.md),
      child: ExpansionTile(
        key: ValueKey('terminal-${terminal.id}'),
        title: Wrap(
          spacing: Space.sm,
          runSpacing: Space.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(terminal.name),
            if (!terminal.isActive) const StatusChip('off', compact: true),
            if (terminal.lastSeenAt == null)
              const StatusChip('never_seen', compact: true),
          ],
        ),
        subtitle: Text(
          [
            '${terminal.enrolments} enrolled',
            if (terminal.lastPunchAt != null)
              'last punch ${Fmt.dateTime(terminal.lastPunchAt!)}'
            else
              'no punches yet',
            if (terminal.deviceRef != null) terminal.deviceRef!,
          ].join(' · '),
          style: muted,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.lg,
              0,
              Space.lg,
              Space.lg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Enrolments(terminal: terminal),
                const SizedBox(height: Space.md),
                Wrap(
                  spacing: Space.sm,
                  children: [
                    TextButton.icon(
                      onPressed: () => _reissue(context, ref),
                      icon: const Icon(Icons.key_outlined, size: 18),
                      label: const Text('Issue a new secret'),
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        final repo = ref.read(timeTerminalsRepoProvider);
                        if (repo == null) return;
                        await repo.setActive(terminal.id, !terminal.isActive);
                        ref.invalidate(timeTerminalsProvider);
                      },
                      icon: Icon(
                        terminal.isActive
                            ? Icons.pause_circle_outline
                            : Icons.play_circle_outline,
                        size: 18,
                      ),
                      label: Text(
                        terminal.isActive ? 'Switch it off' : 'Switch it on',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _reissue(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(
      context,
      title: 'Issue a new secret?',
      message:
          'The old one stops working immediately, so ${terminal.name} will '
          'go quiet until somebody puts the new one into it. Its punches '
          'are kept on the device meanwhile and arrive when it '
          'reconnects.',
      confirmLabel: 'Issue a new one',
      destructive: true,
    );
    if (!ok || !context.mounted) return;

    final repo = ref.read(timeTerminalsRepoProvider);
    if (repo == null) return;
    final secret = await repo.reissue(terminal.id);
    if (!context.mounted) return;
    await _showSecret(context, terminal.name, secret);
  }
}

/// Which employee this terminal's user numbers are.
///
/// Per terminal, deliberately. Two devices number their users
/// independently — the front door's user 1 and the warehouse's are two
/// different people — and a single number on the employee would file
/// one person's hours against the other, silently.
class _Enrolments extends ConsumerWidget {
  const _Enrolments({required this.terminal});

  final TimeTerminal terminal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(terminalEnrolmentsProvider(terminal.id));
    final muted = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant);

    return AsyncView(
      value: rows,
      onRetry: () => ref.invalidate(terminalEnrolmentsProvider(terminal.id)),
      skeleton: const CardRowsSkeleton(rows: 3, trailing: 1),
      builder: (list) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (list.isEmpty)
            Text(
              'Nobody is enrolled on this terminal yet, so every punch it '
              'sends will match nobody.',
              style: muted,
            )
          else
            for (final e in list)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: SizedBox(
                  width: 56,
                  child: Text(
                    e.enrolmentNo,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
                title: Text(e.employeeName ?? e.employeeId),
                subtitle: e.employeeNo == null ? null : Text(e.employeeNo!),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Remove',
                  onPressed: () async {
                    final repo = ref.read(timeTerminalsRepoProvider);
                    if (repo == null) return;
                    await repo.unenrol(e.id);
                    ref
                      ..invalidate(terminalEnrolmentsProvider(terminal.id))
                      ..invalidate(timeTerminalsProvider);
                  },
                ),
              ),
          const SizedBox(height: Space.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: ValueKey('enrol-${terminal.id}'),
              onPressed: () => _enrol(context, ref),
              icon: const Icon(Icons.person_add_alt, size: 18),
              label: const Text('Enrol somebody'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _enrol(BuildContext context, WidgetRef ref) async {
    final number = TextEditingController();
    String? employeeId;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('Enrol on ${terminal.name}'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Consumer(
                  builder: (context, ref, _) {
                    final staff =
                        ref.watch(employeesProvider('active')).valueOrNull ??
                        const [];
                    return SearchablePicker<String>(
                      options: employeePickerOptions(staff),
                      value: employeeId,
                      label: 'Who',
                      hint: 'Type a name or a staff number',
                      onChanged: (v) => setState(() => employeeId = v),
                    );
                  },
                ),
                const SizedBox(height: Space.lg),
                TextField(
                  key: const ValueKey('enrolment-no'),
                  controller: number,
                  decoration: const InputDecoration(
                    labelText: 'User number on the device',
                    hintText: '42',
                    helperText: 'The number their fingerprint is registered '
                        'against on THIS terminal. Padding does not '
                        'matter — 0042 and 42 are the same person.',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Enrol'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    if (employeeId == null || number.text.trim().isEmpty) return;

    final repo = ref.read(timeTerminalsRepoProvider);
    if (repo == null) return;
    final done = await runWithFeedback(
      context,
      action: () => repo.enrol(
        terminalId: terminal.id,
        employeeId: employeeId!,
        enrolmentNo: number.text,
      ),
      successMessage: 'Enrolled',
    );
    if (done) {
      ref
        ..invalidate(terminalEnrolmentsProvider(terminal.id))
        ..invalidate(timeTerminalsProvider);
    }
  }
}

/// Punches that matched nobody.
///
/// A finger nobody enrolled is a day somebody is about to be short, and
/// the moment they find out is when they look at their payslip — unless
/// this says so first. Kept rather than dropped for the same reason.
class _UnmatchedPunches extends ConsumerWidget {
  const _UnmatchedPunches();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(unmatchedPunchesProvider);
    final muted = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant);

    return AsyncView(
      value: rows,
      onRetry: () => ref.invalidate(unmatchedPunchesProvider),
      skeleton: const CardRowsSkeleton(
          rows: 4, leadingSize: 24, trailing: 2),
      builder: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        return Card(
          key: const ValueKey('unmatched-punches'),
          color: context.scheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  list.length == 1
                      ? 'One punch in the last month matched nobody'
                      : '${list.length} punches in the last month matched '
                            'nobody',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: context.scheme.onErrorContainer,
                  ),
                ),
                const SizedBox(height: Space.xs),
                Text(
                  'Somebody pressed a finger to a machine and their day is '
                  'short. Enrol the number above and the next punch will '
                  'land — the ones already missed are corrected on the '
                  'attendance record.',
                  style: muted?.copyWith(
                    color: context.scheme.onErrorContainer,
                  ),
                ),
                const SizedBox(height: Space.md),
                for (final p in list.take(10))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '${p.terminalName ?? 'A terminal'} · user '
                      '${p.enrolmentNo} · ${Fmt.dateTime(p.punchedAt)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: context.scheme.onErrorContainer,
                      ),
                    ),
                  ),
                if (list.length > 10)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.xs),
                    child: Text(
                      'and ${list.length - 10} more',
                      style: muted?.copyWith(
                        color: context.scheme.onErrorContainer,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
