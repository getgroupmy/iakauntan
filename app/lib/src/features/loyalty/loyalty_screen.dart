import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'loyalty_tiers_dialog.dart';
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
      action: () => ref
          .read(repoProvider)!
          .adjustLoyaltyPoints(id, answer.points, answer.note),
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
          // Setup rather than daily work, but it belongs beside the
          // members it names rather than in a settings screen nobody
          // opens while thinking about loyalty.
          if (isAdmin)
            IconButton(
              tooltip: 'Tiers',
              icon: const Icon(Icons.workspace_premium_outlined, size: 20),
              onPressed: () => showLoyaltyTiers(context),
            ),
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
            if (_selected != null) _SelectedMember(member: _selected!),
            if (_found.isNotEmpty)
              Expanded(
                child: ListView(
                  children: [
                    for (final m in _found)
                      Card(
                        child: ListTile(
                          selected: _selected?['account_id'] == m['account_id'],
                          title: Text('${m['name'] ?? m['contact'] ?? '—'}'),
                          subtitle: _MemberLine(member: m),
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

/// A member's line: what they hold, and what they are called.
///
/// The tier is a second round trip per member rather than a column on
/// `loyalty_lookup`, because a lookup with a queue behind it must not
/// wait on a band calculation — the name arrives a moment later and
/// the row is useful without it.
class _MemberLine extends ConsumerWidget {
  const _MemberLine({required this.member});

  final Map<String, dynamic> member;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = member['account_id'] as String?;
    final tier = id == null
        ? null
        : ref.watch(loyaltyMemberTierProvider(id)).valueOrNull;
    final name = tier?['tier_name'];

    return Text(
      [
        if (member['card_no'] != null) 'Card ${member['card_no']}',
        if (member['points'] != null) '${member['points']} points',
        if (name != null) '$name',
      ].join(' · '),
    );
  }
}

/// How long since a point last moved on this account.
///
/// The dormancy sweep at the top of this screen clears the balance of
/// every account quiet for longer than the programme allows, and until
/// now no screen in the app said when any account was last active. A
/// shop pressing "Expire dormant" could not tell beforehand who it
/// would hit; it found out from the list of names afterwards.
///
/// "No points have moved yet" is a different statement from "quiet for
/// a long time", and is said as such: an account enrolled this morning
/// has no activity and is not dormant.
///
/// Deliberately approximate past two months. A shopkeeper deciding
/// whether to sweep needs "about eight months", not "247 days"; and
/// months here are thirtieths of the elapsed days rather than calendar
/// months, which is why it says "about".
String loyaltyLastActive(DateTime? last, {DateTime? now}) {
  if (last == null) return 'No points have moved on this account yet';
  final days = (now ?? DateTime.now()).difference(last).inDays;
  final on = Fmt.date(last);
  if (days <= 0) return 'Last active today';
  if (days == 1) return 'Last active yesterday';
  if (days < 60) return 'Last active $on — $days days ago';
  final months = days ~/ 30;
  return 'Last active $on — about $months months ago';
}

/// Everything the programme knows about the member somebody tapped.
///
/// `loyalty_account_balance` has returned this since 0212 and
/// `loyaltyAccountBalanceProvider` has wrapped it, and this screen has
/// invalidated the provider after every adjustment — and nothing read
/// it. What the list shows comes from `loyalty_lookup`, which carries
/// the points and what they are worth but neither the programme's name
/// nor when the account was last active.
///
/// The last of those is the one this screen could least afford to be
/// missing, because the button in its own app bar takes points away on
/// exactly that basis.
class _SelectedMember extends ConsumerWidget {
  const _SelectedMember({required this.member});

  final Map<String, dynamic> member;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contactId = member['contact_id'] as String?;
    if (contactId == null) return const SizedBox.shrink();
    final balance = ref.watch(loyaltyAccountBalanceProvider(contactId));

    // Quiet while it loads and quiet if it fails: the row above already
    // carries the points, and this panel is the detail behind a row
    // that is useful without it.
    final row = balance.valueOrNull;
    if (row == null) return const SizedBox.shrink();

    final points = Fmt.toInt(row['points']);
    return Card(
      key: const ValueKey('loyalty-balance'),
      margin: const EdgeInsets.only(bottom: Space.md),
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              '${row['program'] ?? 'Loyalty'}',
              subtitle: row['card_no'] == null
                  ? 'No card issued'
                  : 'Card ${row['card_no']}',
            ),
            Row(
              children: [
                Expanded(
                  child: StatTile(label: 'Points', value: '$points'),
                ),
                Expanded(
                  child: StatTile(
                    label: 'Worth',
                    // What the shop owes if they spend the lot today.
                    // Points are a liability, and a liability with no
                    // figure beside it is one nobody has priced.
                    value: Fmt.money(Fmt.toDouble(row['worth'])),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.sm),
            Text(
              loyaltyLastActive(Fmt.parseDate(row['last_activity'])),
              key: const ValueKey('loyalty-last-active'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
