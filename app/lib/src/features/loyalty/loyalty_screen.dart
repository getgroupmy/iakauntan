import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
// `RepoLoyaltyAdmin` and `RepoPos` are extensions, and a Dart extension
// is only in scope where its declaring library is imported.
import '../../data/repository.dart';

/// The points a shop owes, and the two things nobody could do about
/// them.
///
/// 0212 built the programme, the entries, the balance, a signed
/// adjustment and a dormancy sweep. The till reached the parts that
/// happen during a sale — looking a member up, redeeming at the tender
/// sheet — and these three were granted to `authenticated` and never
/// called from anywhere.
///
/// ## The sweep is the reason this screen exists
///
/// `expire_loyalty_points` is on no schedule and had no caller, so a
/// shop that set `dormancy_expiry_months` has points that never expire.
/// Unredeemed points are a liability; one that only ever grows is one
/// nobody has priced. Running it is deliberately a person pressing a
/// button rather than a nightly job, because it takes points away from
/// named customers and somebody should be able to say when that
/// happened and see who it hit.
///
/// ## Handing out points is handing out money
///
/// So adjusting is narrower than selling: the server requires an owner
/// or admin, refuses an adjustment of zero, refuses one with no reason,
/// and refuses one that would take an account below nothing. This
/// screen asks for the note and otherwise stays out of the way — every
/// one of those refusals is better delivered by the thing that enforces
/// it than paraphrased by a screen that might drift.
class LoyaltyScreen extends ConsumerStatefulWidget {
  const LoyaltyScreen({super.key});

  @override
  ConsumerState<LoyaltyScreen> createState() => _LoyaltyScreenState();
}

class _LoyaltyScreenState extends ConsumerState<LoyaltyScreen> {
  final _search = TextEditingController();
  List<Map<String, dynamic>> _found = const [];
  Map<String, dynamic>? _selected;
  bool _busy = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    setState(() => _busy = true);
    final rows = await repo.loyaltyLookup(_search.text);
    if (!mounted) return;
    setState(() {
      _found = rows;
      _busy = false;
      _selected = rows.length == 1 ? rows.first : null;
    });
  }

  Future<void> _adjust(Map<String, dynamic> account) async {
    final answer = await showDialog<({int points, String note})>(
      context: context,
      builder: (_) => const _AdjustDialog(),
    );
    if (answer == null || !mounted) return;

    final id = account['account_id'] as String?;
    if (id == null) return;
    await runWithFeedback(
      context,
      successMessage: 'Adjusted, and written down',
      action: () =>
          ref.read(repoProvider)!.adjustLoyaltyPoints(id, answer.points, answer.note),
    );
    if (!mounted) return;
    final contactId = account['contact_id'] as String?;
    if (contactId != null) {
      ref.invalidate(loyaltyAccountBalanceProvider(contactId));
    }
    await _find();
  }

  Future<void> _expire() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Expire dormant points'),
        content: const Text(
          'This clears the balance of every account that has been quiet '
          'for longer than the programme allows, and writes an entry '
          'against each one saying why. Customers who come back will see '
          'their points are gone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Expire them'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;

    List<Map<String, dynamic>> cleared = const [];
    final ok = await runWithFeedback(
      context,
      pendingMessage: 'Sweeping…',
      // Said afterwards from what came back. "Done" over a sweep that
      // cleared nobody reads as though it cleared everybody.
      successMessage: null,
      action: () async {
        cleared = await ref.read(repoProvider)!.expireLoyaltyPoints();
      },
    );
    if (!ok || !mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          cleared.isEmpty
              ? 'Nothing was dormant'
              : '${cleared.length} account${cleared.length == 1 ? '' : 's'} cleared',
        ),
        content: SizedBox(
          width: 480,
          child: cleared.isEmpty
              ? const Text(
                  'Either no account has been quiet long enough, or the '
                  'programme has no dormancy period set.',
                )
              : SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final row in cleared)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text('${row['contact']}'),
                          subtitle: Text(
                            'Last active '
                            '${Fmt.date(Fmt.parseDate(row['last_activity']))}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: Text('−${row['points']}'),
                        ),
                    ],
                  ),
                ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!moduleEnabled(ref, 'loyalty')) {
      return Scaffold(
        appBar: AppBar(title: const Text('Loyalty')),
        body: const EmptyState(
          icon: Icons.card_giftcard_outlined,
          title: 'Loyalty is not switched on',
          message:
              'This company does not have the loyalty module, or has put '
              'it away in settings.',
        ),
      );
    }

    final isAdmin = ref.watch(canAdminProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Loyalty'),
        actions: [
          if (isAdmin)
            Padding(
              padding: const EdgeInsets.only(right: Space.md),
              child: OutlinedButton.icon(
                onPressed: _expire,
                icon: const Icon(Icons.auto_delete_outlined, size: 18),
                label: const Text('Expire dormant'),
              ),
            ),
        ],
      ),
      body: PageBody(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: 'Card number, mobile, or name',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: _busy ? null : _find,
                ),
              ),
              onSubmitted: (_) => _find(),
            ),
            const SizedBox(height: Space.md),
            if (_busy) const LinearProgressIndicator(),
            if (!_busy && _found.isEmpty)
              const Expanded(
                child: EmptyState(
                  icon: Icons.card_giftcard_outlined,
                  title: 'Find a member',
                  message:
                      'An exact card match sorts first, so scanning a card '
                      'gives an answer rather than a shortlist.',
                ),
              ),
            if (_found.isNotEmpty)
              Expanded(
                child: ListView(
                  children: [
                    for (final m in _found)
                      Card(
                        child: ListTile(
                          selected: _selected?['account_id'] == m['account_id'],
                          title: Text('${m['name'] ?? m['contact'] ?? '—'}'),
                          subtitle: Text(
                            [
                              if (m['card_no'] != null) 'Card ${m['card_no']}',
                              if (m['points'] != null) '${m['points']} points',
                            ].join(' · '),
                          ),
                          trailing: isAdmin
                              ? TextButton(
                                  onPressed: () => _adjust(m),
                                  child: const Text('Adjust'),
                                )
                              // Said rather than left blank. Somebody who
                              // cannot do it should know it exists and
                              // who to ask, not wonder where the button
                              // went.
                              : const Text(
                                  'Adjusting needs an admin',
                                  style: TextStyle(fontSize: 12),
                                ),
                          onTap: () => setState(() => _selected = m),
                        ),
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

/// How many, and why.
///
/// The note is required here as well as on the server, because the
/// server's refusal arrives after the person has already pressed the
/// button — and "say why, an unexplained adjustment is the one the
/// auditor asks about" is better read before typing a number than
/// after.
class _AdjustDialog extends StatefulWidget {
  const _AdjustDialog();

  @override
  State<_AdjustDialog> createState() => _AdjustDialogState();
}

class _AdjustDialogState extends State<_AdjustDialog> {
  final _points = TextEditingController();
  final _note = TextEditingController();

  @override
  void dispose() {
    _points.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Adjust points'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _points,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              decoration: const InputDecoration(
                labelText: 'Points',
                helperText: 'Negative takes them away',
              ),
            ),
            const SizedBox(height: Space.sm),
            TextField(
              controller: _note,
              decoration: const InputDecoration(
                labelText: 'Why',
                hintText: 'Goodwill after the March promotion',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final points = int.tryParse(_points.text.trim());
            final note = _note.text.trim();
            if (points == null || points == 0 || note.isEmpty) return;
            Navigator.of(context).pop((points: points, note: note));
          },
          child: const Text('Adjust'),
        ),
      ],
    );
  }
}
