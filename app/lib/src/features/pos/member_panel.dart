import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import 'till_screen.dart' show posNum;

/// The card, at the counter.
///
/// ## Why this sits on the tender sheet
///
/// "Do you have a card?" is asked while the money is being handed over,
/// not while the shopping is being rung up. Putting it on the basket
/// would ask it at the wrong moment and ask it of every sale, including
/// the four hundred a day that walk out with a drink.
///
/// ## What it will not do
///
/// It does not work out a discount. `redeem_loyalty_points` decides how
/// many points a basket can absorb, floors them so a redemption never
/// takes more than the goods are worth, and returns the new total —
/// every figure below came back from the server. A screen that did that
/// arithmetic itself would be a second implementation of the programme
/// rules, disagreeing with the receipt on exactly the sales that get
/// argued about.
///
/// It also does not deduct anything. The ledger is untouched until the
/// sale completes, so the panel shows the balance *and* what it will be
/// afterwards rather than pretending the points have already gone.
class MemberPanel extends ConsumerWidget {
  const MemberPanel({super.key, required this.saleId});

  final String saleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Loyalty is its own module. A shop that has not bought it gets no
    // panel rather than an empty one — and the server agrees: since
    // 0231 every loyalty function is gated on `loyalty` rather than on
    // the till, so a client that showed this anyway would be offering
    // buttons that come back refused.
    if (!moduleEnabled(ref, 'loyalty')) return const SizedBox.shrink();

    final member = ref.watch(posSaleMemberProvider(saleId));
    return member.maybeWhen(
      data: (row) => row == null ? const SizedBox.shrink() : _Panel(
        saleId: saleId,
        row: row,
      ),
      // Silent while it loads and silent when it fails. This is an
      // extra on a screen whose job is taking money: a spinner or an
      // error box above the total would make a loyalty outage look like
      // a till outage.
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _Panel extends ConsumerWidget {
  const _Panel({required this.saleId, required this.row});

  final String saleId;
  final Map<String, dynamic> row;

  /// Both, because a redemption changes the bill as well as the panel:
  /// `redeem_loyalty_points` recalculates the sale, and a total left
  /// stale on the tender sheet is the number somebody is about to be
  /// charged.
  void _refresh(WidgetRef ref) {
    ref
      ..invalidate(posSaleMemberProvider(saleId))
      ..invalidate(posSaleProvider(saleId));
  }

  Future<void> _find(BuildContext context, WidgetRef ref) async {
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const MemberLookupSheet(),
    );
    if (picked == null || !context.mounted) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: null,
      action: () =>
          repo.namePosSaleCustomer(saleId, picked['contact_id'] as String),
    );
    if (ok) _refresh(ref);
  }

  Future<void> _clear(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: null,
      action: () => repo.namePosSaleCustomer(saleId, null),
    );
    if (ok) _refresh(ref);
  }

  Future<void> _redeem(
    BuildContext context,
    WidgetRef ref, {
    required int points,
    required int most,
    required int least,
    required double perPoint,
  }) async {
    final asked = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RedeemSheet(
        held: points,
        most: most,
        least: least,
        perPoint: perPoint,
      ),
    );
    if (asked == null || !context.mounted) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    Map<String, dynamic>? result;
    final ok = await runWithFeedback(
      context,
      successMessage: null,
      action: () async {
        result = await repo.redeemLoyaltyPoints(saleId, asked);
      },
    );
    if (!ok || !context.mounted) return;
    _refresh(ref);
    final r = result;
    // What actually went on, which is not always what was asked for:
    // points cannot buy more than the basket, so the server floors them
    // and the cashier is told the real figure rather than their own.
    if (r != null && context.mounted) {
      final applied = (r['points_applied'] as num?)?.toInt() ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            applied == 0
                ? 'Points taken off this bill'
                : '$applied points, ${Fmt.money(posNum(r['discount']))} off',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = row['account_id'] as String?;
    final contact = row['contact_id'] as String?;
    final program = row['program'] as String?;

    // No programme running in this company. Not an empty panel — no
    // panel, because there is nothing to join and nothing to spend.
    if (program == null) return const SizedBox.shrink();

    final points = (row['points'] as num?)?.toInt() ?? 0;
    final after = (row['points_after'] as num?)?.toInt() ?? points;
    final redeemed = (row['points_redeemed'] as num?)?.toInt() ?? 0;
    final least = (row['min_redeem'] as num?)?.toInt() ?? 0;
    final earn = (row['would_earn'] as num?)?.toInt() ?? 0;
    final perPoint = posNum(row['value_per_point']);
    final worth = posNum(row['worth']);
    final discount = posNum(row['discount']);

    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;

    if (account == null) {
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: ListTile(
          leading: const Icon(Icons.card_membership_outlined),
          title: Text(contact == null ? program : '${row['contact_name']}'),
          subtitle: Text(
            contact == null
                ? 'No card on this bill'
                // A named customer who is not a member is the one case
                // worth a nudge, because signing them up is one tap and
                // the points start with this bill.
                : 'Not a member yet — joining earns $earn on this bill',
          ),
          trailing: contact == null
              ? TextButton(
                  onPressed: () => _find(context, ref),
                  child: const Text('Find'),
                )
              : TextButton(
                  onPressed: () async {
                    final repo = ref.read(repoProvider);
                    if (repo == null) return;
                    final ok = await runWithFeedback(
                      context,
                      successMessage: 'Signed up',
                      action: () => repo.enrolLoyaltyMember(contact),
                    );
                    if (ok) _refresh(ref);
                  },
                  child: const Text('Sign up'),
                ),
        ),
      );
    }

    final canRedeem = points > 0 && points >= least;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.card_membership, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${row['contact_name']}',
                    style: Theme.of(context).textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Not this customer',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => _clear(context, ref),
                ),
              ],
            ),
            Text(
              [
                if (row['card_no'] != null) '${row['card_no']}',
                '$points points',
                'worth ${Fmt.money(worth)}',
              ].join(' · '),
              style: small,
            ),
            // Said out loud rather than left to be inferred. The ledger
            // is not touched until the sale completes, so "506 points"
            // is true now and misleading in a minute.
            if (redeemed > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '$redeemed points on this bill — '
                  '${Fmt.money(discount)} off, $after left after paying',
                  style: small?.copyWith(color: scheme.primary),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Paying this bill earns about $earn', style: small),
              ),
            const SizedBox(height: 4),
            Row(
              children: [
                if (redeemed > 0)
                  TextButton(
                    onPressed: () => _redeem(
                      context,
                      ref,
                      points: points,
                      most: points,
                      least: least,
                      perPoint: perPoint,
                    ),
                    child: const Text('Change'),
                  ),
                if (redeemed > 0)
                  TextButton(
                    onPressed: () async {
                      final repo = ref.read(repoProvider);
                      if (repo == null) return;
                      final ok = await runWithFeedback(
                        context,
                        successMessage: null,
                        action: () => repo.redeemLoyaltyPoints(saleId, 0),
                      );
                      if (ok) _refresh(ref);
                    },
                    child: const Text('Take it off'),
                  ),
                if (redeemed == 0)
                  TextButton(
                    // Offered rather than hidden when the balance is
                    // short: a disabled button with the reason beside it
                    // tells the customer why, and "you need 100" is the
                    // answer they actually want.
                    onPressed: canRedeem
                        ? () => _redeem(
                            context,
                            ref,
                            points: points,
                            most: points,
                            least: least,
                            perPoint: perPoint,
                          )
                        : null,
                    child: Text(
                      canRedeem ? 'Use points' : 'Redeems from $least',
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Finding the member from what the customer said.
///
/// One box, three things searched. A cashier does not know whether they
/// were handed a card number or told a phone number, and asking them to
/// choose a search mode first is asking them to classify what they just
/// heard.
class MemberLookupSheet extends ConsumerStatefulWidget {
  const MemberLookupSheet({super.key});

  @override
  ConsumerState<MemberLookupSheet> createState() => _MemberLookupSheetState();
}

class _MemberLookupSheetState extends ConsumerState<MemberLookupSheet> {
  final _query = TextEditingController();
  List<Map<String, dynamic>> _hits = const [];
  bool _looking = false;
  bool _searched = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search(String text) async {
    final repo = ref.read(repoProvider);
    if (repo == null || text.trim().isEmpty) return;
    setState(() => _looking = true);
    final rows = await repo.loyaltyLookup(text.trim());
    if (!mounted) return;
    setState(() {
      _hits = rows;
      _looking = false;
      _searched = true;
    });
    // A scanned card is an answer, not a shortlist. One exact match
    // takes itself, because making somebody tap the only row is making
    // them confirm what they already told the till.
    if (rows.length == 1 && rows.first['matched_on'] == 'card') {
      Navigator.of(context).pop(rows.first);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Card, phone or name',
                prefixIcon: Icon(Icons.search),
              ),
              onSubmitted: _search,
            ),
            const SizedBox(height: 12),
            if (_looking) const LinearProgressIndicator(),
            if (!_looking && _searched && _hits.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('Nobody by that card, number or name.'),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final h in _hits)
                    ListTile(
                      dense: true,
                      title: Text('${h['name']}'),
                      subtitle: Text(
                        [
                          if (h['card_no'] != null) '${h['card_no']}',
                          if (h['phone'] != null) '${h['phone']}',
                          '${h['points']} points',
                        ].join(' · '),
                      ),
                      trailing: Text(Fmt.money(posNum(h['worth']))),
                      onTap: () => Navigator.of(context).pop(h),
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

/// How many points, of the ones they hold.
///
/// A slider rather than a number pad. "Use them all" is what nearly
/// everybody says, and a keypad makes the common answer the slowest one
/// — but a partial redemption has to stay possible, because a customer
/// saving up for something is the reason a scheme works at all.
class _RedeemSheet extends StatefulWidget {
  const _RedeemSheet({
    required this.held,
    required this.most,
    required this.least,
    required this.perPoint,
  });

  final int held;
  final int most;
  final int least;
  final double perPoint;

  @override
  State<_RedeemSheet> createState() => _RedeemSheetState();
}

class _RedeemSheetState extends State<_RedeemSheet> {
  late double _points = widget.most.toDouble();

  @override
  Widget build(BuildContext context) {
    final n = _points.round();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Use points',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              '${widget.held} on the card. '
              'They cannot buy more than the bill is worth — the till '
              'takes what is needed and leaves the rest.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Text(
              '$n points — ${Fmt.money(n * widget.perPoint)}',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            Slider(
              value: _points.clamp(0, widget.most.toDouble()),
              min: 0,
              max: widget.most.toDouble(),
              divisions: widget.most > 0 ? widget.most : null,
              label: '$n',
              onChanged: (v) => setState(() => _points = v),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: n >= widget.least && n > 0
                  ? () => Navigator.of(context).pop(n)
                  : null,
              child: Text(
                n >= widget.least || n == 0
                    ? 'Use $n'
                    : 'Redeems from ${widget.least}',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
