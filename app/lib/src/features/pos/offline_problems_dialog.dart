import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'offline_controller.dart' show posOfflineProblemsProvider;

/// Sales a till took that the server could not accept.
///
/// `0219` says why they are kept rather than logged: "Money crossed a
/// counter for each of these, so they are listed rather than logged and
/// forgotten." `pos_offline_problems` lists them, `posOfflineProblems`
/// calls it, `posOfflineProblemsProvider` wraps it — and nothing
/// watched the provider, so nothing listed them. A till with no signal
/// took money, the batch was refused when the signal came back, and the
/// only trace was a row nobody could see.
///
/// Found by widening the provider sweep past `providers.dart`, which
/// sixteen other files also declare providers in — the same mistake as
/// opening only `repository.dart`, one layer up.

/// Which register took it, and when.
String problemLine(Map<String, dynamic> row) {
  final at = Fmt.parseDate(row['taken_at']);
  return [
    '${row['register'] ?? 'a till nobody can name'}',
    if (at != null) Fmt.dateTime(at),
  ].join(' · ');
}

/// Why the server would not take it.
///
/// The server's own sentence where there is one, and the SQLSTATE only
/// where there is not. A code on its own tells a shop manager nothing,
/// but it is better than a blank line.
String problemReason(Map<String, dynamic> row) {
  final message = '${row['message'] ?? ''}'.trim();
  if (message.isNotEmpty) return message;
  final code = '${row['error_code'] ?? ''}'.trim();
  return code.isEmpty ? 'Refused, with no reason given.' : 'Refused: $code';
}

/// Whether money actually crossed the counter for this one.
///
/// A refused payload with nothing on it is a bug in the till, not a
/// hole in the takings. Both are worth showing; only one is worth
/// counting into the figure a manager acts on.
bool tookMoney(Map<String, dynamic> row) =>
    (double.tryParse('${row['total'] ?? 0}') ?? 0) > 0;

/// What the shop is short, and over how many sales.
({int sales, double total}) offlineProblemTotals(
  Iterable<Map<String, dynamic>> rows,
) {
  var sales = 0;
  var total = 0.0;
  for (final r in rows) {
    if (!tookMoney(r)) continue;
    sales++;
    total += double.tryParse('${r['total'] ?? 0}') ?? 0;
  }
  return (sales: sales, total: double.parse(total.toStringAsFixed(2)));
}

/// The line at the top, in the words the shop would use.
String problemsHeadline(({int sales, double total}) totals) {
  if (totals.sales == 0) return 'Nothing took money.';
  return '${totals.sales} sale${totals.sales == 1 ? '' : 's'} '
      'worth ${Fmt.money(totals.total)} never landed.';
}

/// What the tills took and the server would not have.
Future<void> showOfflineProblems(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => const _ProblemsDialog(),
    );

class _ProblemsDialog extends ConsumerWidget {
  const _ProblemsDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final problems = ref.watch(posOfflineProblemsProvider);
    final small = Theme.of(context).textTheme.bodySmall;

    return AlertDialog(
      title: const Text('What the tills could not land'),
      content: SizedBox(
        width: 560,
        height: 440,
        child: AsyncView<List<Map<String, dynamic>>>(
          value: problems,
          onRetry: () => ref.invalidate(posOfflineProblemsProvider),
          builder: (rows) {
            if (rows.isEmpty) {
              return const EmptyState(
                icon: Icons.cloud_done_outlined,
                title: 'Everything landed',
                message: 'Every sale a till took with no signal has since '
                    'been accepted.',
              );
            }
            final totals = offlineProblemTotals(rows);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  problemsHeadline(totals),
                  style: small?.copyWith(color: context.colors.danger),
                ),
                const SizedBox(height: Space.sm),
                Text(
                  'A sale stops appearing here the moment the same payload '
                  'lands, so a till that gets its signal back clears its '
                  'own list. One still here is one the server refused for '
                  'a reason that has not gone away.',
                  style: small,
                ),
                const Divider(height: Space.lg),
                Expanded(
                  child: ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final r = rows[i];
                      return ListTile(
                        dense: true,
                        title: Text(problemLine(r)),
                        subtitle: Text(
                          problemReason(r),
                          style: small?.copyWith(color: context.colors.danger),
                        ),
                        trailing: tookMoney(r)
                            ? Money(
                                double.tryParse('${r['total'] ?? 0}'),
                                bold: true,
                              )
                            : Text('nothing on it', style: small),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
