import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error_text.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../data/repository.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Pick a period, see exactly what it will raise, then raise it.
///
/// The preview is not a mock-up computed here. It is
/// `strata_charge_preview` and `rent_preview`, the same two functions the
/// engines loop over when they write the invoices, so what is on this
/// sheet is what the owners and tenants receive. Anything computed twice
/// eventually disagrees with itself, and the place that happens is a
/// screen that does its own arithmetic to look responsive.
Future<void> showChargeRunSheet(
  BuildContext context,
  WidgetRef ref, {
  required bool strata,
  required String id,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ChargeRunSheet(strata: strata, id: id),
  );
}

class _ChargeRunSheet extends ConsumerStatefulWidget {
  const _ChargeRunSheet({required this.strata, required this.id});

  final bool strata;

  /// The scheme for strata, the site for rent.
  final String id;

  @override
  ConsumerState<_ChargeRunSheet> createState() => _ChargeRunSheetState();
}

class _ChargeRunSheetState extends ConsumerState<_ChargeRunSheet> {
  late DateTime _from;
  late DateTime _to;
  DateTime? _due;
  List<Map<String, dynamic>>? _preview;
  String? _error;
  bool _loading = false;
  bool _raising = false;

  @override
  void initState() {
    super.initState();
    // The month just gone, which is what is being billed nine times in
    // ten. Whole calendar months, because the charge engine treats a
    // whole month as a month rather than as 30.4 days.
    final now = DateTime.now();
    _from = DateTime(now.year, now.month, 1);
    _to = DateTime(now.year, now.month + 1, 0);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(repoProvider)!;
      final rows = widget.strata
          ? await repo.strataChargePreview(widget.id, _from, _to)
          : await repo.rentPreview(widget.id, _from, _to);
      if (mounted) setState(() => _preview = rows);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickPeriod() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDateRange: DateTimeRange(start: _from, end: _to),
    );
    if (range == null) return;
    setState(() {
      _from = range.start;
      _to = range.end;
    });
    await _load();
  }

  Future<void> _raise() async {
    setState(() => _raising = true);
    final ok = await runWithFeedback(
      context,
      action: () async {
        final repo = ref.read(repoProvider)!;
        if (widget.strata) {
          await repo.raiseStrataCharges(widget.id, _from, _to, dueDate: _due);
        } else {
          await repo.raiseRentInvoices(widget.id, _from, _to, dueDate: _due);
        }
      },
      successMessage: widget.strata
          ? 'Charges raised and invoiced'
          : 'Rent invoiced',
      pendingMessage: 'Raising…',
    );
    if (!mounted) return;
    setState(() => _raising = false);
    if (ok) {
      ref.invalidate(strataChargeRunsProvider(widget.id));
      ref.invalidate(strataArrearsProvider(widget.id));
      ref.invalidate(tenanciesProvider(widget.id));
      ref.invalidate(documentsProvider);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _preview ?? const [];
    final total = rows.fold<num>(
      0,
      (a, r) =>
          a + ((widget.strata ? r['total_amount'] : r['amount']) as num? ?? 0),
    );

    return Padding(
      padding: EdgeInsets.only(
        left: Space.lg,
        right: Space.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + Space.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.strata ? 'Raise maintenance charges' : 'Raise rent',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _loading || _raising ? null : _pickPeriod,
            icon: const Icon(Icons.date_range, size: 18),
            label: Text('${Fmt.date(_from)} — ${Fmt.date(_to)}'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  _due == null
                      ? 'Due on the first day of the period'
                      : 'Due ${Fmt.date(_due)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              TextButton(
                onPressed: _raising
                    ? null
                    : () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _due ?? _from,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) setState(() => _due = picked);
                      },
                child: const Text('Change'),
              ),
            ],
          ),
          const Divider(),
          if (_loading)
            // A row per unit, each a name and an amount. The sheet is
            // opened from a period already chosen, so the list is the
            // only thing on the way.
            const Padding(
              padding: EdgeInsets.symmetric(vertical: Space.md),
              child: CardRowsSkeleton(
                rows: 5,
                leading: false,
                lines: 2,
                trailing: 1,
                trailingWidth: 80,
              ),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.lg),
              child: Text(
                _error!,
                style: TextStyle(color: context.colors.danger, fontSize: 12),
              ),
            )
          else if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: Space.lg),
              child: Text(
                'Nothing to raise for this period.',
                style: TextStyle(fontSize: 13),
              ),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final r = rows[i];
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      widget.strata
                          ? '${r['unit_no']} · ${r['owner_name'] ?? 'No owner'}'
                          : '${r['unit_no']} · ${r['tenant_name'] ?? '—'}',
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      widget.strata
                          ? '${r['share_units']} share units · charges '
                                '${Fmt.money(r['maintenance_amount'] as num?)} '
                                '+ sinking fund '
                                '${Fmt.money(r['sinking_amount'] as num?)}'
                          : '${r['months']} month(s) · '
                                '${Fmt.date(DateTime.parse(r['charge_from'] as String))}'
                                ' to '
                                '${Fmt.date(DateTime.parse(r['charge_to'] as String))}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: Money(
                      (widget.strata ? r['total_amount'] : r['amount']) as num?,
                    ),
                  );
                },
              ),
            ),
          const Divider(),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${rows.length} invoice${rows.length == 1 ? '' : 's'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Money(total, bold: true),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: rows.isEmpty || _loading || _raising ? null : _raise,
              child: _raising
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      'Raise ${rows.length} invoice'
                      '${rows.length == 1 ? '' : 's'}',
                    ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
