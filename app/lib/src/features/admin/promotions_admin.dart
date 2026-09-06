import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/platform_live.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/platform_catalog_repository.dart';

/// Promotions: a price that is not the price list's.
///
/// `platform_modules.monthly_price` was the only number this product
/// could charge for an add-on. There was no way to offer a trial, no
/// way to run a launch discount, and no way to give one customer a
/// module while it was still being finished — changing the price
/// changed it for everybody, at once, retrospectively from the next
/// invoice.
///
/// 0548 is where the arithmetic lives. This screen is the only place
/// that writes it.
///
/// There is no delete, for the reason the module list has none: a
/// promotion that has priced an invoice is part of why that invoice
/// says what it says. Ending one stops it from today and leaves the
/// months it covered alone.
class PromotionsAdminTab extends ConsumerWidget {
  const PromotionsAdminTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final promotions = ref.watch(platformPromotionsAdminProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('Add a promotion'),
      ),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: promotions,
        onRetry: () => ref.invalidate(platformPromotionsAdminProvider),
        builder: (rows) => rows.isEmpty
            ? const EmptyState(
                icon: Icons.local_offer_outlined,
                title: 'No promotions',
                message:
                    'Every company pays the price on the module list. Add '
                    'a promotion to offer a trial period, give a module '
                    'away, or price one differently for a while.',
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  for (final r in rows)
                    ListTile(
                      key: ValueKey('promotion-${r['id']}'),
                      title: Row(
                        children: [
                          Flexible(child: Text('${r['name']}')),
                          if (r['is_active'] != true) ...[
                            const SizedBox(width: Space.sm),
                            const StatusChip('ended', compact: true),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        promotionSummary(r),
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: r['is_active'] != true
                          ? null
                          : IconButton(
                              tooltip: 'End it today',
                              icon: const Icon(Icons.block_outlined),
                              onPressed: () => _end(context, ref, r),
                            ),
                      onTap: () => _edit(context, ref, r),
                    ),
                ],
              ),
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic>? existing,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _PromotionDialog(existing: existing),
    );
    // The catalogue's own screens as well as this list: a promotion is
    // a price, and the settings card that offers the module reads it.
    if (saved == true) invalidatePlatformTable(ref, 'module_promotions');
  }

  Future<void> _end(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> row,
  ) async {
    final ok = await confirm(
      context,
      title: 'End ${row['name']}?',
      message:
          'It stops applying today. Companies already on it go back to the '
          'price list from tomorrow, this month is billed at the promotional '
          'price for the days it ran, and the invoices it has already priced '
          'are left alone.',
      confirmLabel: 'End it',
    );
    if (!ok || !context.mounted) return;
    final done = await runWithFeedback(
      context,
      successMessage: 'Promotion ended',
      action: () =>
          ref.read(platformCatalogProvider).endPromotion('${row['id']}'),
    );
    if (done) invalidatePlatformTable(ref, 'module_promotions');
  }
}

/// The one-line description under a promotion's name.
///
/// Public and pure so it can be asserted: this sentence is the only
/// place the console says what a promotion actually does, and every
/// word of it is about money.
String promotionSummary(Map<String, dynamic> r) {
  final module = r['module_name'] ?? r['module_code'] ?? 'Every add-on';
  final who = r['org_name'] ?? 'Every company';
  final from = DateTime.tryParse('${r['starts_on'] ?? ''}');
  final until = DateTime.tryParse('${r['ends_on'] ?? ''}');
  final when = until == null
      ? 'from ${Fmt.date(from)}'
      : '${Fmt.date(from)} to ${Fmt.date(until)}';
  return '${promotionOffer(r)} · $module · $who · $when';
}

/// What the promotion takes off, in words.
String promotionOffer(Map<String, dynamic> r) {
  switch ('${r['kind']}') {
    case 'trial':
      return 'Free for the first ${r['trial_days']} days';
    case 'free':
      return 'Free while it runs';
    case 'percent_off':
      return '${Fmt.qty(Fmt.toDouble(r['percent_off']))}% off';
    case 'fixed_price':
      return '${Fmt.money(Fmt.toDouble(r['fixed_price']))} a month';
  }
  return '${r['kind']}';
}

/// The four shapes, and what each one is for.
const promotionKinds = <String, String>{
  'trial': 'Trial period — free for a number of days after they add it',
  'free': 'Unlimited use — free for as long as this runs',
  'percent_off': 'A percentage off the price list',
  'fixed_price': 'A different monthly price',
};

class _PromotionDialog extends ConsumerStatefulWidget {
  const _PromotionDialog({required this.existing});

  final Map<String, dynamic>? existing;

  @override
  ConsumerState<_PromotionDialog> createState() => _PromotionDialogState();
}

class _PromotionDialogState extends ConsumerState<_PromotionDialog> {
  late final _name = TextEditingController(
    text: '${widget.existing?['name'] ?? ''}',
  );
  late final _number = TextEditingController(text: _initialNumber());
  late final _notes = TextEditingController(
    text: '${widget.existing?['notes'] ?? ''}',
  );
  late String _kind = '${widget.existing?['kind'] ?? 'trial'}';
  late String? _module = widget.existing?['module_code'] as String?;
  late String? _org = widget.existing?['org_id'] as String?;
  late DateTime _from =
      DateTime.tryParse('${widget.existing?['starts_on'] ?? ''}') ??
      DateTime.now();
  late DateTime? _until = DateTime.tryParse(
    '${widget.existing?['ends_on'] ?? ''}',
  );
  late bool _active = widget.existing?['is_active'] != false;
  bool _busy = false;

  String _initialNumber() {
    final e = widget.existing;
    if (e == null) return '30';
    return switch ('${e['kind']}') {
      'trial' => '${e['trial_days'] ?? ''}',
      'percent_off' => '${Fmt.toDouble(e['percent_off'])}',
      'fixed_price' => Fmt.toDouble(e['fixed_price']).toStringAsFixed(2),
      _ => '',
    };
  }

  @override
  void dispose() {
    for (final c in [_name, _number, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  /// What the number beside the kind means. Null for the two kinds that
  /// need no number at all, which is how the field knows to disappear
  /// rather than sit there asking for something nobody reads.
  String? get _numberLabel => switch (_kind) {
    'trial' => 'Days free',
    'percent_off' => 'Percent off',
    'fixed_price' => 'Monthly price',
    _ => null,
  };

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('A promotion needs a name — it goes on the invoice.'),
        ),
      );
      return;
    }
    final number = double.tryParse(_number.text.trim());
    if (_numberLabel != null && (number == null || number <= 0)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${_numberLabel!} has to be a number.')),
      );
      return;
    }

    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Promotion saved',
      action: () => ref
          .read(platformCatalogProvider)
          .savePromotion(
            id: widget.existing?['id'] as String?,
            name: name,
            moduleCode: _module,
            orgId: _org,
            kind: _kind,
            trialDays: _kind == 'trial' ? number!.round() : null,
            percentOff: _kind == 'percent_off' ? number : null,
            fixedPrice: _kind == 'fixed_price' ? number : null,
            startsOn: _from,
            endsOn: _until,
            isActive: _active,
            notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
          ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final modules =
        ref.watch(platformModulesAdminProvider).valueOrNull ?? const [];
    final orgs = ref.watch(platformOrgsProvider).valueOrNull ?? const [];
    return AlertDialog(
      title: Text(
        widget.existing == null ? 'Add a promotion' : _name.text,
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  helperText: 'What the customer is told it is. It goes on '
                      'the invoice line.',
                ),
              ),
              const SizedBox(height: Space.sm),
              DropdownButtonFormField<String>(
                key: const ValueKey('promotion-kind'),
                value: _kind,
                decoration: const InputDecoration(labelText: 'What it does'),
                items: [
                  for (final e in promotionKinds.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setState(() => _kind = v ?? _kind),
              ),
              if (_numberLabel != null) ...[
                const SizedBox(height: Space.sm),
                TextField(
                  key: const ValueKey('promotion-number'),
                  controller: _number,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: _numberLabel,
                    helperText: _kind == 'trial'
                        ? 'Counted from the day each company adds it, not '
                              'from the day this promotion opened.'
                        : null,
                  ),
                ),
              ],
              const SizedBox(height: Space.sm),
              // Both of these are lists that grow: the catalogue gains
              // a module every few releases and the company list gains
              // one every time somebody signs up. Neither is a set
              // anybody can scroll.
              SearchablePicker<String>(
                key: const ValueKey('promotion-module'),
                options: [
                  for (final m in modules)
                    if (m['is_core'] != true)
                      PickerOption<String>(
                        value: '${m['code']}',
                        label: '${m['name']}',
                        sublabel: '${m['code']}',
                      ),
                ],
                value: _module,
                label: 'Which module',
                hint: 'Type a module name',
                allowEmpty: true,
                emptyLabel: 'Every add-on',
                onChanged: (v) => setState(() => _module = v),
              ),
              const SizedBox(height: Space.sm),
              SearchablePicker<String>(
                key: const ValueKey('promotion-org'),
                options: [
                  for (final o in orgs)
                    PickerOption<String>(value: o.id, label: o.name),
                ],
                value: _org,
                label: 'Which company',
                hint: 'Type a company name',
                allowEmpty: true,
                emptyLabel: 'Every company',
                onChanged: (v) => setState(() => _org = v),
              ),
              const SizedBox(height: Space.sm),
              Row(
                children: [
                  Expanded(
                    child: _DayField(
                      label: 'Opens',
                      value: _from,
                      onPicked: (d) => setState(() => _from = d),
                    ),
                  ),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: _DayField(
                      label: 'Closes',
                      value: _until,
                      hint: 'Open-ended',
                      onPicked: (d) => setState(() => _until = d),
                      onCleared: () => setState(() => _until = null),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _notes,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  helperText: 'For the console. The customer never sees it.',
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _active,
                onChanged: (v) => setState(() => _active = v),
                title: const Text('Running'),
                subtitle: const Text(
                  'Off, it prices nothing from today. The months it has '
                  'already priced are left as they were.',
                ),
              ),
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
          onPressed: _busy ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _DayField extends StatelessWidget {
  const _DayField({
    required this.label,
    required this.value,
    required this.onPicked,
    this.hint,
    this.onCleared,
  });

  final String label;
  final DateTime? value;
  final String? hint;
  final ValueChanged<DateTime> onPicked;
  final VoidCallback? onCleared;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(labelText: label),
      child: Row(
        children: [
          Expanded(
            child: Text(value == null ? (hint ?? '') : Fmt.date(value)),
          ),
          if (value != null && onCleared != null)
            IconButton(
              tooltip: 'Leave it open-ended',
              icon: const Icon(Icons.clear, size: 18),
              onPressed: onCleared,
            ),
          IconButton(
            icon: const Icon(Icons.event, size: 18),
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: value ?? DateTime.now(),
                firstDate: DateTime(2020),
                lastDate: DateTime(2100),
              );
              if (picked != null) onPicked(picked);
            },
          ),
        ],
      ),
    );
  }
}
