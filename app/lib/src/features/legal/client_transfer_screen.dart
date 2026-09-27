import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'matter_transfer.dart';

/// Client money moved between one client's matters, with a page of its
/// own.
///
/// `0358` built the movement and put it on the matter screen, behind
/// the matter you were already looking at. That is the right door when
/// you know which file you want and the wrong one for the job this
/// actually is: a balance left on a finished conveyance belongs to a
/// client, not to a matter somebody has already navigated to, and the
/// person moving it is working from the client's name.
///
/// So this is the third page beside `/legal/receipts` and
/// `/legal/payouts`, for the reason those two exist — `0549` built both
/// movements and left the matter screen as the only way in.
class ClientTransferScreen extends ConsumerWidget {
  const ClientTransferScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(clientTransfersProvider);
    final canPost = ref.watch(canPostProvider);

    return Scaffold(
      floatingActionButton: !canPost
          ? null
          : FloatingActionButton.extended(
              key: const ValueKey('client-transfer-new'),
              onPressed: () => _record(context, ref),
              icon: const Icon(Icons.swap_horiz),
              label: const Text('Move'),
            ),
      body: SingleChildScrollView(
        child: PageBody(
          maxWidth: 980,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionHeader(
                'Moved between matters',
                subtitle:
                    'A balance left on one matter, carried across to '
                    'another of the same client’s. Nothing leaves the '
                    'client account — only which matter it is held '
                    'against.',
              ),
              const SizedBox(height: Space.md),
              AsyncView<List<Map<String, dynamic>>>(
                value: rows,
                onRetry: () => ref.invalidate(clientTransfersProvider),
                skeleton: const ListSkeleton(rows: 5, leading: false),
                builder: (list) => list.isEmpty
                    ? const EmptyState(
                        icon: Icons.swap_horiz,
                        title: 'Nothing moved between matters yet',
                        message:
                            'A client finishes a conveyance with a balance '
                            'still held and starts a tenancy; the deposit '
                            'follows them, without a withdrawal that did '
                            'not have to happen.',
                      )
                    : Card(
                        child: Column(
                          children: [
                            for (final r in list) _TransferLine(row: r),
                          ],
                        ),
                      ),
              ),
              const SizedBox(height: Space.xxl),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _record(BuildContext context, WidgetRef ref) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => const _TransferDialog(),
    );
    if (saved == true) {
      ref
        ..invalidate(clientTransfersProvider)
        ..invalidate(matterClientBalancesProvider)
        ..invalidate(matterSummaryProvider);
    }
  }
}

/// One leg of a transfer.
///
/// Both legs are listed rather than one row per pair, because that is
/// what the client ledger holds and a screen that folded them would be
/// showing something the ledger does not say. The sign tells them
/// apart: out of one matter, into another.
class _TransferLine extends StatelessWidget {
  const _TransferLine({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final amount = Fmt.toDouble(row['amount']);
    final out = amount < 0;
    final matter = row['matters'] as Map<String, dynamic>?;
    final client = (matter?['contacts'] as Map<String, dynamic>?)?['name'];

    return ListTile(
      leading: Icon(
        out ? Icons.north_east : Icons.south_west,
        color: out ? context.colors.danger : context.colors.success,
      ),
      title: Text(
        '${matter?['matter_no'] ?? ''} · ${matter?['name'] ?? ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          if (client != null) client.toString(),
          if ((row['description'] ?? '').toString().trim().isNotEmpty)
            row['description'].toString(),
        ].join(' · '),
      ),
      trailing: Text(
        Fmt.money(amount.abs()),
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: out ? context.colors.danger : context.colors.success,
        ),
      ),
    );
  }
}

class _TransferDialog extends ConsumerStatefulWidget {
  const _TransferDialog();

  @override
  ConsumerState<_TransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends ConsumerState<_TransferDialog> {
  final _amount = TextEditingController();
  final _description = TextEditingController();

  String? _fromId;
  String? _toId;
  DateTime _date = DateTime.now();
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save(Matter from, Matter to) async {
    final amount = double.tryParse(_amount.text.trim()) ?? 0;
    setState(() => _busy = true);
    final repo = ref.read(repoProvider)!;
    final ok = await runWithFeedback(
      context,
      pendingMessage: 'Moving…',
      successMessage: 'Moved to ${to.matterNo}',
      action: () => repo.transferBetweenMatters(
        fromMatterId: from.id,
        toMatterId: to.id,
        amount: amount,
        date: _date,
        description: _description.text.trim().isEmpty
            ? null
            : _description.text.trim(),
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final matters =
        ref.watch(mattersProvider((status: 'open', search: ''))).valueOrNull ??
            const <Matter>[];
    final balances =
        ref.watch(matterClientBalancesProvider).valueOrNull ?? const {};

    final from = matters.where((m) => m.id == _fromId).firstOrNull;
    final to = matters.where((m) => m.id == _toId).firstOrNull;
    final held = _fromId == null ? 0.0 : (balances[_fromId] ?? 0);
    final amount = double.tryParse(_amount.text.trim()) ?? 0;

    // The same client's other matters and nothing else. Not tidiness:
    // money held for one client may not be applied for another, and the
    // ordinary way that goes wrong is a mistyped matter number in a
    // list where both are open. The server refuses it too, by naming
    // both clients — this is the list that cannot contain the wrong
    // answer in the first place.
    final destinations =
        from == null ? const <Matter>[] : transferDestinations(matters, from);

    // The client check, belt and braces over the list that cannot
    // contain the wrong answer. A destination chosen against one source
    // and left behind when the source changed would be a pair the
    // picker never offered — and `transferBlockedBecause` cannot see
    // it, because it is handed the destination and not the source.
    //
    // The server refuses it too, by naming both clients. This is so the
    // refusal arrives while both are still on screen.
    final crossClient =
        from != null && to != null && to.clientId != from.clientId;

    final blocked = from == null
        ? 'Choose the matter it moves from.'
        : crossClient
        ? 'Money held for ${from.clientName ?? 'this client'} cannot be '
            'moved to ${to.clientName ?? 'another client'}’s matter.'
        : transferBlockedBecause(held: held, amount: amount, to: to);

    return AlertDialog(
      title: const Text('Move client money to another matter'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SearchablePicker<String>(
                key: const ValueKey('transfer-from'),
                options: [
                  for (final m in matters)
                    PickerOption<String>(
                      value: m.id,
                      label: '${m.matterNo} · ${m.name}',
                      sublabel: m.clientName,
                    ),
                ],
                value: _fromId,
                label: 'From *',
                hint: 'Type a matter number, a name or the client',
                onChanged: (v) => setState(() {
                  _fromId = v;
                  // The destination belongs to the client that was
                  // chosen, so a new source cannot keep the old one —
                  // which would be the one arrangement this screen
                  // exists to make impossible.
                  _toId = null;
                }),
              ),
              if (from != null) ...[
                const SizedBox(height: Space.xs),
                Text(
                  'Holds ${Fmt.money(held)}.',
                  key: const ValueKey('transfer-held'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: Space.sm),
                SearchablePicker<String>(
                  key: const ValueKey('transfer-to'),
                  options: [
                    for (final m in destinations)
                      PickerOption<String>(
                        value: m.id,
                        label: '${m.matterNo} · ${m.name}',
                      ),
                  ],
                  value: _toId,
                  label: 'To *',
                  hint: destinations.isEmpty
                      ? 'This client has no other open matter'
                      : 'Another of ${from.clientName ?? 'this client'}’s '
                          'matters',
                  onChanged: (v) => setState(() => _toId = v),
                ),
                const SizedBox(height: Space.xs),
                Text(
                  transferBlurb(from, to),
                  key: const ValueKey('transfer-blurb'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: Space.sm),
              TextField(
                key: const ValueKey('transfer-amount'),
                controller: _amount,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Amount *',
                  prefixText: 'RM ',
                ),
              ),
              const SizedBox(height: Space.sm),
              InkWell(
                key: const ValueKey('transfer-date'),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _date,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) setState(() => _date = picked);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Date',
                    suffixIcon: Icon(Icons.calendar_today, size: 18),
                  ),
                  child: Text(Fmt.date(_date)),
                ),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _description,
                decoration: const InputDecoration(
                  labelText: 'Why it moved',
                  helperText: 'The first thing anybody asks about a '
                      'transfer a year later.',
                ),
              ),
              if (blocked != null) ...[
                const SizedBox(height: Space.sm),
                Text(
                  blocked,
                  key: const ValueKey('transfer-blocked'),
                  style: TextStyle(color: context.colors.danger),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('transfer-save'),
          onPressed: _busy || blocked != null || from == null || to == null
              ? null
              : () => _save(from, to),
          child: const Text('Move'),
        ),
      ],
    );
  }
}
