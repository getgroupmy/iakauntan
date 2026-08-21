import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/format.dart';
import '../../core/theme.dart';

/// What a discount is, as far as the till is concerned.
///
/// [clear] is not "a discount of nothing" — it is the instruction to put
/// the price back, which is a different act and needs no reason. The
/// server draws the same distinction: neither argument clears, and a
/// discount above nought without a reason is refused.
typedef DiscountAnswer = ({double? percent, double? amount, String reason});

/// Taking money off, on a line or on the whole bill.
///
/// One sheet for both, because they ask the same three questions and a
/// cashier should not have to learn two dialogs to answer them. What
/// differs is only what is being reduced, which is what [subject] says.
///
/// ## A rate and an amount are different promises
///
/// "Ten per cent" and "four ringgit" are not two ways of typing the
/// same thing, and the toggle is not a convenience. A rate goes on
/// applying when another plate arrives; an amount stays where it was
/// put. `recalc_pos_sale` re-derives the first on every change and
/// leaves the second alone, so the choice made here is still being
/// honoured an hour later.
///
/// ## The reason is required and is free text
///
/// A void has four reasons because the kitchen cares which of four
/// things happened to the food. A discount has no such list — "staff
/// meal", "hair in the soup", "regular, third time this week" are all
/// real — so what is asked for is a sentence, and what matters is that
/// somebody typed one and their name goes on it.
Future<({DiscountAnswer? answer, bool clear})?> showDiscountSheet(
  BuildContext context, {
  required String subject,
  required double full,
  double? currentPercent,
  double? currentAmount,
  String? currentReason,
}) {
  return showModalBottomSheet<({DiscountAnswer? answer, bool clear})>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _DiscountSheet(
      subject: subject,
      full: full,
      currentPercent: currentPercent,
      currentAmount: currentAmount,
      currentReason: currentReason,
    ),
  );
}

class _DiscountSheet extends StatefulWidget {
  const _DiscountSheet({
    required this.subject,
    required this.full,
    this.currentPercent,
    this.currentAmount,
    this.currentReason,
  });

  final String subject;

  /// What it comes to before anything is taken off. Used for the
  /// preview and for the one check worth making on the device: a
  /// discount larger than the thing it is reducing.
  final double full;

  final double? currentPercent;
  final double? currentAmount;
  final String? currentReason;

  @override
  State<_DiscountSheet> createState() => _DiscountSheetState();
}

class _DiscountSheetState extends State<_DiscountSheet> {
  late bool _byRate = (widget.currentPercent ?? 0) > 0 ||
      (widget.currentAmount ?? 0) == 0;
  late final _value = TextEditingController(
    text: (widget.currentPercent ?? 0) > 0
        ? Fmt.qty(widget.currentPercent)
        : (widget.currentAmount ?? 0) > 0
            ? Fmt.qty(widget.currentAmount)
            : '',
  );
  late final _reason = TextEditingController(text: widget.currentReason ?? '');
  String? _error;

  bool get _hasOne =>
      (widget.currentPercent ?? 0) > 0 || (widget.currentAmount ?? 0) > 0;

  double get _typed => double.tryParse(_value.text.trim()) ?? 0;

  /// What would come off, at the moment. Shown rather than computed
  /// silently, because "10" means two very different sums depending on
  /// which side of the toggle it is on and the number is the only thing
  /// that says which one the cashier picked.
  double get _off => _byRate
      ? double.parse((widget.full * _typed / 100).toStringAsFixed(2))
      : _typed;

  @override
  void dispose() {
    _value.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    final n = _typed;
    if (n <= 0) {
      setState(() => _error = 'How much is coming off?');
      return;
    }
    if (_byRate && n > 100) {
      setState(() => _error = 'A discount stops at a hundred per cent');
      return;
    }
    if (!_byRate && n > widget.full) {
      setState(() {
        _error = 'That is more than ${Fmt.money(widget.full)}. '
            'Take it off the bill instead.';
      });
      return;
    }
    if (_reason.text.trim().isEmpty) {
      setState(() => _error = 'Say why the price is coming down');
      return;
    }
    Navigator.of(context).pop((
      answer: (
        percent: _byRate ? n : null,
        amount: _byRate ? null : n,
        reason: _reason.text.trim(),
      ),
      clear: false,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: Space.lg,
          right: Space.lg,
          top: Space.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + Space.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.subject,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              'Comes to ${Fmt.money(widget.full)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: Space.md),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: true,
                  icon: Icon(Icons.percent, size: 16),
                  label: Text('Per cent'),
                ),
                ButtonSegment(
                  value: false,
                  icon: Icon(Icons.payments_outlined, size: 16),
                  label: Text('Ringgit'),
                ),
              ],
              selected: {_byRate},
              onSelectionChanged: (s) => setState(() {
                _byRate = s.first;
                _error = null;
              }),
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _value,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              onChanged: (_) => setState(() => _error = null),
              decoration: InputDecoration(
                labelText: _byRate ? 'Per cent off' : 'Ringgit off',
                prefixText: _byRate ? null : Fmt.prefix('MYR'),
                suffixText: _byRate ? '%' : null,
                // The rate's own answer, in money, because a cashier
                // standing at a counter is being asked about money.
                helperText: _typed <= 0
                    ? null
                    : 'Takes off ${Fmt.money(_off)}, leaving '
                        '${Fmt.money(widget.full - _off)}',
              ),
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _reason,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() => _error = null),
              decoration: const InputDecoration(
                labelText: 'Why',
                hintText: 'Staff meal',
                helperText: 'Goes on the discount report with your name.',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: Space.sm),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: Space.lg),
            Row(
              children: [
                // Only where there is one to undo. A "put it back" that
                // is always there invites a cashier to press it on a
                // full-price line and wonder what it did.
                if (_hasOne)
                  TextButton(
                    onPressed: () => Navigator.of(context)
                        .pop((answer: null, clear: true)),
                    child: const Text('Put the price back'),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: Space.sm),
                FilledButton(
                  onPressed: _submit,
                  child: const Text('Take it off'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
