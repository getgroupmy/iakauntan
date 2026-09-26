import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error_text.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'knock_off.dart';

/// Where an accounts clerk lives at month end.
///
/// `0629` and `0630`. Pick a customer, see what they owe on the left and
/// what they have in hand on the right, tick both sides, apply.
///
/// Until `0629` the right-hand column could not exist: a credit note had
/// nowhere to be applied to, because nothing had ever written
/// `payment_allocations.credit_note_id`. This screen is the reason that
/// migration was written, and it is deliberately the only thing in the
/// product that can spend several credits in one action.
///
/// **It moves no money.** Every credit on the right already credited the
/// receivable — the credit note when it was raised, the receipt when it
/// was banked — so applying one records WHICH invoice it is against and
/// posts nothing. A deposit is different and is shown greyed with the
/// reason, because a clerk looking at what a customer has in hand needs
/// to see all of it.
class KnockOffScreen extends ConsumerStatefulWidget {
  const KnockOffScreen({super.key});

  @override
  ConsumerState<KnockOffScreen> createState() => KnockOffScreenState();
}

class KnockOffScreenState extends ConsumerState<KnockOffScreen> {
  String? _contactId;
  final _ticked = <String>{};
  bool _busy = false;

  List<OpenItem> _items = const [];

  List<OpenItem> get _tickedOwed => [
    for (final i in _items)
      if (i.owed && _ticked.contains(i.id)) i,
  ];

  List<OpenItem> get _tickedCredits => [
    for (final i in _items)
      if (!i.owed && _ticked.contains(i.id)) i,
  ];

  /// What the button would do. Public so a test can read it without
  /// pumping a Supabase client, the same arrangement
  /// `bank_rules_card.dart` uses.
  List<KnockOffLine> get lines =>
      spreadCredits(invoices: _tickedOwed, credits: _tickedCredits);

  String? get problem => knockOffProblem(
    invoices: _tickedOwed,
    credits: _tickedCredits,
    lines: lines,
  );

  Future<void> _apply() async {
    final contactId = _contactId;
    if (contactId == null) return;
    setState(() => _busy = true);
    try {
      final n = await ref
          .read(repoProvider)!
          .knockOff(contactId, [for (final l in lines) l.toJson()]);
      if (!mounted) return;
      setState(_ticked.clear);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$n applied')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        ref.invalidate(openItemsProvider(contactId));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final canPost = ref.watch(canPostProvider);
    final contacts = ref
        .watch(contactsProvider((type: 'customer', search: '')))
        .valueOrNull ??
        const <Contact>[];

    return Scaffold(
      appBar: AppBar(title: const Text('Knock off')),
      body: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SearchablePicker<String>(
              key: const ValueKey('knock-off-contact'),
              options: [
                for (final c in contacts)
                  PickerOption(
                    value: c.id,
                    label: c.name,
                    sublabel: c.code,
                    keywords: [c.code],
                  ),
              ],
              value: _contactId,
              label: 'Customer',
              hint: 'Type a name or a code',
              onChanged: (v) => setState(() {
                _contactId = v;
                // A tick belongs to the account it was made on. Carrying
                // one across would apply somebody's credit to somebody
                // else's invoice, which the database refuses and the
                // screen should never propose.
                _ticked.clear();
              }),
            ),
            const SizedBox(height: Space.lg),
            if (_contactId == null)
              const Expanded(
                child: Center(
                  child: Text('Pick a customer to see their account.'),
                ),
              )
            else
              Expanded(child: _account(_contactId!, canPost: canPost)),
          ],
        ),
      ),
    );
  }

  Widget _account(String contactId, {required bool canPost}) {
    final async = ref.watch(openItemsProvider(contactId));
    return AsyncView(
      value: async,
      onRetry: () => ref.invalidate(openItemsProvider(contactId)),
      // Two columns side by side -- what is owed and what is on
      // account -- each a list of tickable rows. Which side a row
      // lands on is what the query decides; that there are two sides
      // is not.
      skeleton: const Padding(
        padding: EdgeInsets.all(Space.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: CardRowsSkeleton(
                rows: 6,
                leadingSize: 20,
                lines: 2,
                trailing: 1,
                trailingWidth: 90,
              ),
            ),
            SizedBox(width: Space.lg),
            Expanded(
              child: CardRowsSkeleton(
                rows: 3,
                leadingSize: 20,
                lines: 2,
                trailing: 1,
                trailingWidth: 90,
              ),
            ),
          ],
        ),
      ),
      builder: (rows) {
        _items = [for (final r in rows) OpenItem.fromMap(r)];
        final owed = [for (final i in _items) if (i.owed) i];
        final credits = [for (final i in _items) if (!i.owed) i];
        final currency = _items.isEmpty ? 'MYR' : _items.first.currency;
        final why = problem;

        if (_items.isEmpty) {
          return const Center(
            child: Text('Nothing outstanding and nothing on account.'),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _Column(
                      title: 'Owed',
                      items: owed,
                      ticked: _ticked,
                      onTick: _tick,
                    ),
                  ),
                  const SizedBox(width: Space.lg),
                  Expanded(
                    child: _Column(
                      title: 'In hand',
                      items: credits,
                      ticked: _ticked,
                      onTick: _tick,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),
            Text(
              knockOffSummary(lines, currency: currency),
              key: const ValueKey('knock-off-summary'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 2),
            Text(
              knockOffRemainder(
                invoices: _tickedOwed,
                lines: lines,
                currency: currency,
              ),
              key: const ValueKey('knock-off-remainder'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (why != null) ...[
              const SizedBox(height: 4),
              Text(
                why,
                key: const ValueKey('knock-off-problem'),
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: context.scheme.error),
              ),
            ],
            const SizedBox(height: Space.md),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                key: const ValueKey('knock-off-apply'),
                onPressed: why != null || _busy || !canPost ? null : _apply,
                child: const Text('Apply'),
              ),
            ),
          ],
        );
      },
    );
  }

  void _tick(OpenItem item, bool on) => setState(() {
    if (on) {
      _ticked.add(item.id);
    } else {
      _ticked.remove(item.id);
    }
  });
}

class _Column extends StatelessWidget {
  const _Column({
    required this.title,
    required this.items,
    required this.ticked,
    required this.onTick,
  });

  final String title;
  final List<OpenItem> items;
  final Set<String> ticked;
  final void Function(OpenItem, bool) onTick;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: text.titleSmall),
        const SizedBox(height: Space.sm),
        Expanded(
          child: ListView(
            children: [
              for (final i in items)
                CheckboxListTile(
                  key: ValueKey('knock-off-item-${i.id}'),
                  dense: true,
                  value: ticked.contains(i.id),
                  // Greyed rather than hidden. A clerk looking at what a
                  // customer has in hand needs to see all of it, and a
                  // deposit left off the list entirely would have them
                  // believe the account was clear.
                  onChanged: i.allocatable
                      ? (v) => onTick(i, v ?? false)
                      : null,
                  title: Text('${openItemKind(i.kind)} ${i.docNo}'),
                  subtitle: Text(
                    [
                      Fmt.money(i.remaining, currency: i.currency),
                      if (i.partly)
                        'of ${Fmt.money(i.total, currency: i.currency)}',
                      if (i.dueDate != null) 'due ${Fmt.date(i.dueDate)}',
                      if (openItemLocked(i) != null) openItemLocked(i)!,
                    ].join(' · '),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
