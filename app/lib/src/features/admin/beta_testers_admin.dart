import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';

/// Who carries the report button on every screen.
///
/// `0663` is the list; this is the only way onto it. There is no write
/// policy on the table, so nobody can add themselves and nobody can add
/// anybody else except from here.
///
/// ## Why the search is a server call and not a dropdown
///
/// `core/searchable_picker.dart` filters a list already in memory,
/// which is right for the forty accounts in a chart and wrong for every
/// person on the platform. So this is a box that asks, with the two
/// consequences that follow from asking: it waits, and it says so.
///
/// Two characters before anything is sent, which `0663` enforces as
/// well. One letter matches most of the table, and a console that
/// renders four hundred rows is a console somebody scrolls instead of
/// typing one more letter.
class BetaTestersAdminTab extends ConsumerStatefulWidget {
  const BetaTestersAdminTab({super.key});

  @override
  ConsumerState<BetaTestersAdminTab> createState() =>
      _BetaTestersAdminTabState();
}

class _BetaTestersAdminTabState extends ConsumerState<BetaTestersAdminTab> {
  final _search = TextEditingController();

  /// What has actually been asked for, which lags what has been typed.
  ///
  /// Every keystroke would be a round trip, and a search that fires on
  /// every letter of a name arrives out of order as often as not — the
  /// answer to "sit" landing after the answer to "siti" and replacing
  /// it. A quarter of a second is about a word.
  String _asked = '';
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _typed(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _asked = value.trim());
    });
  }

  Future<void> _assign(PlatformUser user) async {
    final note = await showDialog<String?>(
      context: context,
      builder: (_) => _NoteDialog(user: user),
    );
    // Null is Cancel. An empty string is "add them, no reason given",
    // which is allowed — the reason is a kindness to whoever prunes the
    // list later, not a requirement.
    if (note == null || !mounted) return;

    await runWithFeedback(
      context,
      doing: 'add ${user.label} to the beta',
      successMessage: '${user.label} has the report button now',
      action: () => ref
          .read(platformRepoProvider)
          .assignBetaTester(user.userId, note: note.isEmpty ? null : note),
    );
    ref.invalidate(betaTestersProvider);
    // The search too: its rows carry `is_beta`, and leaving them stale
    // means the person just added still shows an Add button.
    ref.invalidate(platformUserSearchProvider);
  }

  Future<void> _remove(BetaTester tester) async {
    final yes = await confirm(
      context,
      title: 'Take ${tester.label} off the beta?',
      message:
          'The button goes from their screens. Everything they have '
          'already reported stays exactly where it is.',
      confirmLabel: 'Take them off',
    );
    if (!yes || !mounted) return;

    await runWithFeedback(
      context,
      doing: 'take ${tester.label} off the beta',
      successMessage: 'Done',
      action: () =>
          ref.read(platformRepoProvider).removeBetaTester(tester.userId),
    );
    ref.invalidate(betaTestersProvider);
    ref.invalidate(platformUserSearchProvider);
  }

  @override
  Widget build(BuildContext context) {
    final testers = ref.watch(betaTestersProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Beta testers')),
      body: ListView(
        padding: const EdgeInsets.all(Space.lg),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Space.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionHeader(
                    'Add somebody',
                    subtitle:
                        'A tester gets a round button on every screen that '
                        'takes the screenshot for them. Nothing else '
                        'changes — it opens no doors.',
                  ),
                  const SizedBox(height: Space.md),
                  TextField(
                    key: const ValueKey('beta-search'),
                    controller: _search,
                    onChanged: _typed,
                    decoration: InputDecoration(
                      labelText: 'Name or e-mail',
                      hintText: 'siti, or siti@kedai.my',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close),
                              tooltip: 'Clear',
                              onPressed: () {
                                _search.clear();
                                _typed('');
                              },
                            ),
                    ),
                  ),
                  const SizedBox(height: Space.md),
                  _SearchResults(query: _asked, onAssign: _assign),
                ],
              ),
            ),
          ),
          const SizedBox(height: Space.lg),
          const SectionHeader('On the beta now'),
          const SizedBox(height: Space.sm),
          AsyncView(
            value: testers,
            onRetry: () => ref.invalidate(betaTestersProvider),
            skeleton: const CardRowsSkeleton(
              rows: 4,
              leadingSize: 40,
              trailing: 1,
            ),
            builder: (rows) {
              if (rows.isEmpty) {
                return const EmptyState(
                  icon: Icons.science_outlined,
                  title: 'Nobody on the beta yet',
                  message:
                      'The people worth putting on it are the ones who '
                      'would have told you anyway — and now will, from '
                      'the screen it happened on.',
                );
              }
              return Column(
                children: [
                  for (final t in rows)
                    _TesterTile(tester: t, onRemove: () => _remove(t)),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// What the search box found, or why it found nothing.
///
/// Split out so the three states are three branches rather than three
/// nested ternaries: not asked yet, asked and empty, asked and found.
class _SearchResults extends ConsumerWidget {
  const _SearchResults({required this.query, required this.onAssign});

  final String query;
  final ValueChanged<PlatformUser> onAssign;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    // Under two characters nothing has been asked. Saying so beats an
    // empty list, which reads as "nobody by that name" — the one answer
    // that is definitely wrong here.
    if (query.length < 2) {
      return Text(
        'Two letters or more.',
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      );
    }

    return AsyncView(
      value: ref.watch(platformUserSearchProvider(query)),
      onRetry: () => ref.invalidate(platformUserSearchProvider(query)),
      skeleton: const CardRowsSkeleton(
        rows: 3,
        leadingSize: 32,
        trailing: 1,
      ),
      builder: (people) {
        if (people.isEmpty) {
          return Text(
            'Nobody matching “$query”.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          );
        }
        return Column(
          children: [
            for (final p in people)
              ListTile(
                key: ValueKey('beta-result-${p.userId}'),
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  child: Text(Fmt.initials(p.label)),
                ),
                title: Text(p.label),
                subtitle: p.email == null || p.email == p.label
                    ? null
                    : Text(p.email!),
                // A tick rather than a second Add button. Adding
                // somebody already on the list would succeed — `0663`
                // updates the note rather than failing — and the person
                // pressing it would have no idea they had not needed to.
                trailing: p.isBeta
                    ? const Chip(
                        avatar: Icon(Icons.check, size: 16),
                        label: Text('On the beta'),
                      )
                    : FilledButton.tonal(
                        onPressed: () => onAssign(p),
                        child: const Text('Add'),
                      ),
              ),
          ],
        );
      },
    );
  }
}

class _TesterTile extends StatelessWidget {
  const _TesterTile({required this.tester, required this.onRemove});

  final BetaTester tester;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Three things and any of them can be missing: why they are on it,
    // who put them there, and when. Joined rather than stacked, because
    // a card with three one-word lines is taller than the name it is
    // about.
    final detail = [
      if ((tester.note ?? '').trim().isNotEmpty) tester.note!.trim(),
      if ((tester.addedBy ?? '').trim().isNotEmpty) 'added by ${tester.addedBy}',
      if (tester.createdAt != null) Fmt.date(tester.createdAt!),
    ].join(' · ');

    return Card(
      margin: const EdgeInsets.only(bottom: Space.sm),
      child: ListTile(
        key: ValueKey('beta-tester-${tester.userId}'),
        leading: CircleAvatar(child: Text(Fmt.initials(tester.label))),
        title: Text(tester.label),
        subtitle: detail.isEmpty
            ? null
            : Text(detail, style: TextStyle(color: scheme.onSurfaceVariant)),
        trailing: IconButton(
          icon: const Icon(Icons.person_remove_outlined),
          tooltip: 'Take off the beta',
          onPressed: onRemove,
        ),
      ),
    );
  }
}

/// Why this person is on the list.
///
/// Optional, and the dialog says so. A required reason is a reason
/// somebody types "beta" into.
class _NoteDialog extends StatefulWidget {
  const _NoteDialog({required this.user});

  final PlatformUser user;

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Add ${widget.user.label}'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('beta-note'),
            controller: _note,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Why, if it is worth saying',
              hintText: 'Trying the new till before the outlets get it',
            ),
            onSubmitted: (v) => Navigator.pop(context, v.trim()),
          ),
          const SizedBox(height: Space.md),
          Text(
            'They get a report button on every screen. It opens no '
            'doors and shows them nothing new.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _note.text.trim()),
        child: const Text('Add'),
      ),
    ],
  );
}
