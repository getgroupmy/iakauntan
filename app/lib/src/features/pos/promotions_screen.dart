import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// A price the shop decided in advance.
///
/// 0255 gave the till a discount button, which is the right control for
/// "the steak was burnt" and the wrong one for "teh tarik is two
/// ringgit before eleven". A happy hour typed in by hand is wrong on
/// the till nobody told and missing on the Tuesday the manager was off.
/// This is where the rule gets written down once.
///
/// ## What each row has to say
///
/// A promotion nobody used and a promotion that gave away four thousand
/// ringgit look identical in a list of names, so the money and the
/// count are on every row — the same reason a loyalty tier carries its
/// member count.
///
/// ## Retired, never deleted
///
/// Last April's receipt has to keep saying which promotion it was, so
/// the row is switched off and stays. Editing a retired one brings it
/// back, which is the rule everywhere else in this module.
class PromotionsScreen extends ConsumerWidget {
  const PromotionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!moduleEnabled(ref, 'pos')) {
      return Scaffold(
        appBar: AppBar(title: const Text('Promotions')),
        body: const EmptyState(
          icon: Icons.local_offer_outlined,
          title: 'The till is not switched on',
          message: 'A promotion is a price a till charges, and this company '
              'has no till.',
        ),
      );
    }

    final promos = ref.watch(posPromotionsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Promotions')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('New promotion'),
      ),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: promos,
        onRetry: () => ref.invalidate(posPromotionsProvider),
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.local_offer_outlined,
              title: 'No promotions',
              message: 'Ten per cent off before eleven, three teh tarik for '
                  'the price of two, or a voucher code on a printed slip.',
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [for (final p in rows) _PromoTile(promo: p)],
          );
        },
      ),
    );
  }
}

Future<void> _edit(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic>? promo,
) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _PromoDialog(promo: promo),
  );
  if (saved == true) ref.invalidate(posPromotionsProvider);
}

/// What a promotion does, in one line of English.
///
/// Exported for the test: this is the sentence a shopkeeper checks their
/// own rule against, and a wrong one here means a shop discovers what it
/// published from the takings.
String promotionRule(Map<String, dynamic> p) {
  final kind = '${p['kind']}';
  final pct = Fmt.toDouble(p['percent']);
  final amt = Fmt.toDouble(p['amount']);
  if (kind == 'percent_off') return '${Fmt.qty(pct)}% off';
  if (kind == 'amount_off') return '${Fmt.money(amt)} off';
  final buy = Fmt.toInt(p['buy_quantity']);
  final get = Fmt.toInt(p['get_quantity']);
  // "Three for two" is what a shop says; buy 2 get 1 free is what it
  // means. Say the second, because the first is only true at a hundred
  // per cent and this field is not always a hundred.
  return pct >= 100
      ? 'Buy $buy, get $get free'
      : 'Buy $buy, get $get at ${Fmt.qty(pct)}% off';
}

/// When it runs, in one line, or null when the answer is "always".
String? promotionWindow(Map<String, dynamic> p) {
  final bits = <String>[];
  final from = Fmt.parseDate(p['starts_on']);
  final to = Fmt.parseDate(p['ends_on']);
  if (from != null && to != null) {
    bits.add('${Fmt.date(from)} – ${Fmt.date(to)}');
  } else if (from != null) {
    bits.add('from ${Fmt.date(from)}');
  } else if (to != null) {
    bits.add('until ${Fmt.date(to)}');
  }

  final days = (p['weekdays'] as List?)?.map(Fmt.toInt).toList();
  if (days != null && days.isNotEmpty && days.length < 7) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    bits.add([for (final d in days) names[(d - 1) % 7]].join(' '));
  }

  final start = '${p['starts_at'] ?? ''}';
  final end = '${p['ends_at'] ?? ''}';
  if (start.isNotEmpty && end.isNotEmpty) {
    bits.add('${_hhmm(start)}–${_hhmm(end)}');
  }
  return bits.isEmpty ? null : bits.join(' · ');
}

/// Postgres hands a `time` back as HH:MM:SS. Nobody writes a happy hour
/// to the second.
String _hhmm(String t) => t.length >= 5 ? t.substring(0, 5) : t;

class _PromoTile extends ConsumerWidget {
  const _PromoTile({required this.promo});

  final Map<String, dynamic> promo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = promo['is_active'] == true;
    final code = '${promo['code'] ?? ''}';
    final used = Fmt.toInt(promo['times_used']);
    final away = Fmt.toDouble(promo['given_away']);
    final window = promotionWindow(promo);
    final minSpend = Fmt.toDouble(promo['min_subtotal']);

    return ListTile(
      onTap: () => _edit(context, ref, promo),
      leading: Icon(
        code.isEmpty ? Icons.auto_awesome : Icons.confirmation_number_outlined,
        size: 20,
        color: live ? null : Theme.of(context).disabledColor,
      ),
      title: Text(
        '${promo['name']}',
        style: TextStyle(
          fontWeight: FontWeight.w500,
          color: live ? null : Theme.of(context).disabledColor,
        ),
      ),
      subtitle: Text(
        [
          if (!live) 'retired',
          promotionRule(promo),
          if (code.isNotEmpty) 'code $code',
          if (window != null) window,
          if (minSpend > 0) 'over ${Fmt.money(minSpend)}',
          // The two numbers a list of names cannot tell apart.
          '$used bill${used == 1 ? '' : 's'}',
          if (away > 0) '${Fmt.money(away)} given away',
        ].join(' · '),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: live
          ? IconButton(
              tooltip: 'Retire',
              icon: const Icon(Icons.block_outlined, size: 18),
              onPressed: () async {
                final repo = ref.read(repoProvider);
                if (repo == null) return;
                final ok = await runWithFeedback(
                  context,
                  successMessage: 'Retired',
                  action: () => repo.retirePosPromotion(promo['id'] as String),
                );
                if (ok) ref.invalidate(posPromotionsProvider);
              },
            )
          : null,
    );
  }
}

class _PromoDialog extends ConsumerStatefulWidget {
  const _PromoDialog({this.promo});

  final Map<String, dynamic>? promo;

  @override
  ConsumerState<_PromoDialog> createState() => _PromoDialogState();
}

class _PromoDialogState extends ConsumerState<_PromoDialog> {
  final _formKey = GlobalKey<FormState>();

  late String _kind = '${widget.promo?['kind'] ?? 'percent_off'}';
  late final _name = TextEditingController(
    text: '${widget.promo?['name'] ?? ''}',
  );
  late final _code = TextEditingController(
    text: '${widget.promo?['code'] ?? ''}',
  );
  late final _percent = TextEditingController(
    text: widget.promo == null
        ? ''
        : Fmt.qty(Fmt.toDouble(widget.promo!['percent'])),
  );
  late final _amount = TextEditingController(
    text: widget.promo == null
        ? ''
        : Fmt.qty(Fmt.toDouble(widget.promo!['amount'])),
  );
  late final _buy = TextEditingController(
    text: '${Fmt.toInt(widget.promo?['buy_quantity'])}',
  );
  late final _get = TextEditingController(
    text: '${Fmt.toInt(widget.promo?['get_quantity'])}',
  );
  late final _minSpend = TextEditingController(
    text: widget.promo == null
        ? ''
        : Fmt.qty(Fmt.toDouble(widget.promo!['min_subtotal'])),
  );
  late final _maxUses = TextEditingController(
    text: widget.promo?['max_uses'] == null
        ? ''
        : '${Fmt.toInt(widget.promo!['max_uses'])}',
  );

  late TimeOfDay? _from = _parseTime(widget.promo?['starts_at']);
  late TimeOfDay? _to = _parseTime(widget.promo?['ends_at']);
  late final Set<int> _days = {
    ...?(widget.promo?['weekdays'] as List?)?.map(Fmt.toInt),
  };

  bool _saving = false;

  static TimeOfDay? _parseTime(Object? v) {
    final s = '${v ?? ''}';
    if (s.length < 5) return null;
    return TimeOfDay(
      hour: int.tryParse(s.substring(0, 2)) ?? 0,
      minute: int.tryParse(s.substring(3, 5)) ?? 0,
    );
  }

  static String _wire(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:00';

  @override
  void dispose() {
    for (final c in [
      _name,
      _code,
      _percent,
      _amount,
      _buy,
      _get,
      _minSpend,
      _maxUses,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    // Both or neither. The server refuses a half-window too; catching it
    // here saves a round trip and says which half is missing.
    if ((_from == null) != (_to == null)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('An hours window needs both a start and an end.'),
        ),
      );
      return;
    }

    setState(() => _saving = true);
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    final ok = await runWithFeedback(
      context,
      successMessage: 'Saved',
      action: () => repo.savePosPromotion(
        id: widget.promo?['id'] as String?,
        name: _name.text.trim(),
        kind: _kind,
        code: _code.text.trim().isEmpty ? null : _code.text.trim(),
        percent: double.tryParse(_percent.text.trim()) ?? 0,
        amount: double.tryParse(_amount.text.trim()) ?? 0,
        buy: int.tryParse(_buy.text.trim()) ?? 0,
        get: int.tryParse(_get.text.trim()) ?? 0,
        weekdays: _days.isEmpty ? null : (_days.toList()..sort()),
        startsAt: _from == null ? null : _wire(_from!),
        endsAt: _to == null ? null : _wire(_to!),
        minSubtotal: double.tryParse(_minSpend.text.trim()) ?? 0,
        maxUses: int.tryParse(_maxUses.text.trim()),
        // Editing a retired promotion brings it back, the same way an
        // answer to a modifier question does.
        isActive: true,
      ),
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    return AlertDialog(
      title: Text(widget.promo == null ? 'New promotion' : 'Edit promotion'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Name *',
                    hintText: 'Happy hour',
                    helperText: 'Goes on the receipt.',
                  ),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Required' : null,
                ),
                const SizedBox(height: Space.md),
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'percent_off', label: Text('Per cent')),
                    ButtonSegment(value: 'amount_off', label: Text('Ringgit')),
                    ButtonSegment(
                      value: 'buy_x_get_y',
                      label: Text('Buy X get Y'),
                    ),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (s) => setState(() => _kind = s.first),
                ),
                const SizedBox(height: Space.md),
                if (_kind == 'amount_off')
                  TextFormField(
                    controller: _amount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    decoration: InputDecoration(
                      labelText: 'Off the bill',
                      prefixText: Fmt.prefix('MYR'),
                    ),
                    validator: (v) =>
                        (double.tryParse((v ?? '').trim()) ?? 0) <= 0
                        ? 'More than nought'
                        : null,
                  )
                else ...[
                  TextFormField(
                    controller: _percent,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    decoration: InputDecoration(
                      labelText: _kind == 'buy_x_get_y'
                          ? 'Off the free ones'
                          : 'Off the bill',
                      suffixText: '%',
                      helperText: _kind == 'buy_x_get_y'
                          ? 'A hundred is free. Fifty is half price.'
                          : null,
                    ),
                    validator: (v) {
                      final n = double.tryParse((v ?? '').trim()) ?? 0;
                      if (n <= 0) return 'More than nought';
                      if (n > 100) return 'A hundred at most';
                      return null;
                    },
                  ),
                  if (_kind == 'buy_x_get_y') ...[
                    const SizedBox(height: Space.md),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _buy,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Buy',
                              helperText: 'Three for two is buy 2',
                            ),
                            validator: (v) =>
                                (int.tryParse((v ?? '').trim()) ?? 0) <= 0
                                ? 'At least one'
                                : null,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextFormField(
                            controller: _get,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Get',
                              helperText: 'and get 1',
                            ),
                            validator: (v) =>
                                (int.tryParse((v ?? '').trim()) ?? 0) <= 0
                                ? 'At least one'
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
                const SizedBox(height: Space.md),
                TextFormField(
                  controller: _code,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Voucher code',
                    hintText: 'RAYA5',
                    helperText: 'Leave empty and the till applies it by '
                        'itself. Give it a code and nothing happens until '
                        'somebody types it.',
                  ),
                ),
                const SizedBox(height: Space.md),
                // Every one of these is empty-means-always, which is why
                // none of them is required.
                Text(
                  'When it runs',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: Space.xs),
                Text(
                  'Leave these alone and it runs all the time.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: Space.sm),
                Wrap(
                  spacing: 4,
                  children: [
                    for (var d = 1; d <= 7; d++)
                      FilterChip(
                        label: Text(dayNames[d - 1]),
                        selected: _days.contains(d),
                        onSelected: (on) => setState(() {
                          if (on) {
                            _days.add(d);
                          } else {
                            _days.remove(d);
                          }
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: Space.sm),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          final t = await showTimePicker(
                            context: context,
                            initialTime: _from ?? const TimeOfDay(hour: 11, minute: 0),
                          );
                          if (t != null) setState(() => _from = t);
                        },
                        child: Text(_from == null ? 'From' : _from!.format(context)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          final t = await showTimePicker(
                            context: context,
                            initialTime: _to ?? const TimeOfDay(hour: 19, minute: 0),
                          );
                          if (t != null) setState(() => _to = t);
                        },
                        child: Text(_to == null ? 'To' : _to!.format(context)),
                      ),
                    ),
                    if (_from != null || _to != null)
                      IconButton(
                        tooltip: 'All day',
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => setState(() {
                          _from = null;
                          _to = null;
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: Space.md),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _minSpend,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        ],
                        decoration: InputDecoration(
                          labelText: 'Only over',
                          prefixText: Fmt.prefix('MYR'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _maxUses,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Total uses',
                          helperText: 'Empty is no limit',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
