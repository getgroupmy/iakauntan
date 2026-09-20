import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// What has been closed, and the only place it can be brought back.
///
/// `0619`. Three things in this product are called an account — a
/// login, a company, and a line of the chart of accounts — and all
/// three can now be closed without being destroyed. To the person who
/// closed it, to their colleagues and to every other screen, the thing
/// is gone. Here it is not.
///
/// That asymmetry is the whole feature and it is worth being blunt
/// about what it means on this page: the name, email address and phone
/// number of somebody who asked to be deleted are printed below. They
/// are here because the alternative — destroying them — answers no
/// question anybody can ask afterwards, not "who was this", not "put
/// them back", not "how many accounts were closed this year". A locked
/// drawer, not an open one; but a drawer.
class ClosedAccountsAdminTab extends ConsumerStatefulWidget {
  const ClosedAccountsAdminTab({super.key});

  @override
  ConsumerState<ClosedAccountsAdminTab> createState() =>
      _ClosedAccountsAdminTabState();
}

class _ClosedAccountsAdminTabState
    extends ConsumerState<ClosedAccountsAdminTab> {
  /// Null means all three kinds.
  String? _kind;
  bool _includeRestored = false;

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(
      platformClosuresProvider((kind: _kind, includeRestored: _includeRestored)),
    );

    return AsyncView(
      value: rows,
      onRetry: () => ref.invalidate(platformClosuresProvider),
      // Five rather than six: the card above the list carries a row of
      // filter chips, so a longer outline runs past the fold on a
      // laptop and looks like content that then vanished.
      skeleton: const ListSkeleton(rows: 5, trailing: false),
      builder: (list) => SingleChildScrollView(
        child: PageBody(
          maxWidth: 1000,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(
                        'Closed accounts',
                        subtitle:
                            'Gone from the product and kept here. This is '
                            'the only place any of it can be reopened.',
                      ),
                      Wrap(
                        spacing: Space.sm,
                        runSpacing: Space.sm,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          for (final choice in _kinds)
                            ChoiceChip(
                              key: ValueKey('closure-filter-${choice.$1}'),
                              label: Text(choice.$2),
                              selected: _kind == choice.$1,
                              onSelected: (_) =>
                                  setState(() => _kind = choice.$1),
                            ),
                          const SizedBox(width: Space.sm),
                          FilterChip(
                            key: const ValueKey('closure-show-restored'),
                            label: const Text('Include reopened'),
                            selected: _includeRestored,
                            onSelected: (v) =>
                                setState(() => _includeRestored = v),
                          ),
                        ],
                      ),
                      const SizedBox(height: Space.md),
                      if (list.isEmpty)
                        const EmptyState(
                          icon: Icons.inventory_2_outlined,
                          title: 'Nothing has been closed',
                          message:
                              'Closures appear here as people and companies '
                              'leave.',
                        )
                      else
                        for (var i = 0; i < list.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          ClosureRow(closure: list[i]),
                        ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const _kinds = <(String?, String)>[
    (null, 'Everything'),
    ('user', 'Logins'),
    ('organization', 'Companies'),
    ('ledger_account', 'Ledger accounts'),
  ];
}

/// One closure, with what the product no longer shows.
///
/// Public so a test can pump one row on its own. What it has to get
/// right is not layout: a login's real address appears here and only
/// here, and a closure that has already been reopened must not offer
/// to be reopened again -- the database refuses that, and a button
/// that always fails is worse than one that is absent.
class ClosureRow extends ConsumerWidget {
  const ClosureRow({super.key, required this.closure});

  final Map<String, dynamic> closure;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = (closure['detail'] as Map?)?.cast<String, dynamic>() ?? {};
    final restored = closure['restored_at'] != null;
    final kind = '${closure['subject_kind']}';

    // The identity, and only for a login: a company's name and a ledger
    // account's code are already on the label, and repeating them would
    // make the line longer without saying more.
    final identity = kind == 'user'
        ? [
            detail['email'],
            detail['phone'],
          ].whereType<String>().where((s) => s.isNotEmpty).join(' · ')
        : '';

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(_icon(kind)),
      title: Row(
        children: [
          Flexible(
            child: Text(
              '${closure['label']}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 10),
          StatusChip(restored ? 'reopened' : 'closed', compact: true),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              _kindLabel(kind),
              if (identity.isNotEmpty) identity,
              if (closure['org_name'] != null) '${closure['org_name']}',
              Fmt.dateTime(Fmt.parseDate(closure['closed_at'])),
              closure['closed_via'] == 'console'
                  ? 'closed from the console'
                  : 'closed by the account holder',
            ].join(' · '),
            style: const TextStyle(fontSize: 12),
          ),
          if (closure['reason'] != null)
            Text(
              '“${closure['reason']}”',
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: context.scheme.onSurfaceVariant,
              ),
            ),
          if (restored)
            Text(
              'Reopened ${Fmt.dateTime(Fmt.parseDate(closure['restored_at']))}'
              '${closure['restore_note'] == null ? '' : ' — ${closure['restore_note']}'}',
              style: const TextStyle(fontSize: 12),
            ),
        ],
      ),
      trailing: restored
          ? null
          : TextButton.icon(
              key: ValueKey('closure-restore-${closure['id']}'),
              onPressed: () => _restore(context, ref),
              icon: const Icon(Icons.restore, size: 18),
              label: const Text('Reopen'),
            ),
    );
  }

  static IconData _icon(String kind) => switch (kind) {
    'user' => Icons.person_off_outlined,
    'organization' => Icons.business_outlined,
    _ => Icons.account_balance_outlined,
  };

  static String _kindLabel(String kind) => switch (kind) {
    'user' => 'Login',
    'organization' => 'Company',
    _ => 'Ledger account',
  };

  Future<void> _restore(BuildContext context, WidgetRef ref) async {
    final note = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Reopen ${closure['label']}?'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                switch ('${closure['subject_kind']}') {
                  'user' =>
                    'The name, address and phone number go back on the '
                        'profile, sign-in opens again, and every '
                        'membership returns to what it was.',
                  'organization' =>
                    'The company reappears in its members’ switcher '
                        'with the status it had, and its books are '
                        'reachable again.',
                  _ =>
                    'The account is switched back on and reappears in the '
                        'chart.',
                },
              ),
              const SizedBox(height: Space.md),
              TextField(
                key: const ValueKey('closure-restore-note'),
                controller: note,
                decoration: const InputDecoration(
                  labelText: 'Note (optional)',
                  helperText: 'Why it was reopened. Kept with the closure.',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('closure-restore-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Reopen'),
          ),
        ],
      ),
    );
    final why = note.text.trim();
    note.dispose();
    if (go != true || !context.mounted) return;

    await runWithFeedback(
      context,
      doing: 'reopen it',
      action: () => ref.read(platformRepoProvider).restoreAccount(
        '${closure['id']}',
        note: why.isEmpty ? null : why,
      ),
      successMessage: '${closure['label']} is open again',
    );
    ref.invalidate(platformClosuresProvider);
  }
}
