import 'package:flutter/material.dart';

import '../../core/format.dart';
import 'till_screen.dart' show posNum;

/// "Can we pay separately?"
///
/// Two different questions wear those words, and 0216 keeps them apart
/// in the database. This sheet is the structural one: **this** person
/// had the fish, **that** one had the steak, and the lines move onto a
/// bill of their own. The arithmetic one — one bill, four cards — is
/// [EvenSplitDialog] below, and it moves nothing at all.
///
/// Conflating them is how a till ends up issuing four invoices for one
/// meal, or one invoice that three of the four have no record of
/// paying.
class SplitSheet extends StatefulWidget {
  const SplitSheet({super.key, required this.lines});

  /// Rows from `pos_sale_lines`, in line order.
  final List<Map<String, dynamic>> lines;

  @override
  State<SplitSheet> createState() => _SplitSheetState();
}

class _SplitSheetState extends State<SplitSheet> {
  final _moving = <String>{};

  double get _total {
    var t = 0.0;
    for (final l in widget.lines) {
      if (_moving.contains(l['id'])) t += posNum(l['line_total']);
    }
    return t;
  }

  /// Everything moving is not a split, it is a rename. `split_pos_sale`
  /// would leave an empty bill behind, so the sheet refuses first —
  /// stopping short of the refusal rather than explaining it after.
  bool get _valid => _moving.isNotEmpty && _moving.length < widget.lines.length;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Move onto a second bill',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Tick what the other person is paying for.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final l in widget.lines)
                  CheckboxListTile(
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _moving.contains(l['id']),
                    onChanged: (on) => setState(() {
                      final id = l['id'] as String;
                      if (on ?? false) {
                        _moving.add(id);
                      } else {
                        _moving.remove(id);
                      }
                    }),
                    title: Text('${l['description']}'),
                    subtitle: Text(
                      '${Fmt.qty(posNum(l['quantity']))} × '
                      '${Fmt.money(posNum(l['unit_price']))}',
                    ),
                    secondary: Text(Fmt.money(posNum(l['line_total']))),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _valid
                    ? () => Navigator.of(context).pop(_moving.toList())
                    : null,
                child: Text(
                  _moving.isEmpty
                      ? 'Tick something to move'
                      : _moving.length == widget.lines.length
                      ? 'That is the whole bill'
                      : 'Move ${_moving.length} · ${Fmt.money(_total)}',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One bill, N people, N cards.
///
/// Shows what each person owes and nothing else — deliberately. It
/// raises no second invoice and moves no lines, because there was one
/// supply and LHDN should see one document. The shares are what the
/// cashier keys into the tender sheet.
class EvenSplitDialog extends StatelessWidget {
  const EvenSplitDialog({super.key, required this.shares});

  /// Rows from `pos_even_split`.
  final List<Map<String, dynamic>> shares;

  @override
  Widget build(BuildContext context) {
    var sum = 0.0;
    for (final s in shares) {
      sum += posNum(s['amount']);
    }
    return AlertDialog(
      title: Text('${shares.length} ways'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final s in shares)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('Person ${s['share_no']}'),
              trailing: Text(
                Fmt.money(posNum(s['amount'])),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          const Divider(),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            // Shown because it is the property that matters: the shares
            // are only how the total is reached. Ten ringgit three ways
            // is 3.34 + 3.33 + 3.33, and a split that quietly collected
            // 9.99 would leave a sen on the table for ever.
            title: const Text('They add up to'),
            trailing: Text(
              Fmt.money(sum),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
