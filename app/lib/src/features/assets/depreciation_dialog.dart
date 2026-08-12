import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';

/// Charges depreciation up to a date.
///
/// Shows what it will charge, per asset, before it charges it. The run
/// works out what accumulated depreciation ought to be at the date and
/// posts the difference, so this can be run monthly, quarterly, or once
/// in a panic before the year end, and the answer is the same.
Future<bool?> showDepreciationDialog(BuildContext context, WidgetRef ref) {
  return showDialog<bool>(
    context: context,
    builder: (_) => const _DepreciationDialog(),
  );
}

class _DepreciationDialog extends ConsumerStatefulWidget {
  const _DepreciationDialog();

  @override
  ConsumerState<_DepreciationDialog> createState() =>
      _DepreciationDialogState();
}

class _DepreciationDialogState extends ConsumerState<_DepreciationDialog> {
  /// End of last month, which is what a depreciation run is almost
  /// always dated.
  late DateTime _asAt = DateTime(DateTime.now().year, DateTime.now().month, 0);
  bool _working = false;

  @override
  Widget build(BuildContext context) {
    final preview = ref.watch(depreciationPreviewProvider(_asAt));

    return AlertDialog(
      title: const Text('Run depreciation'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _asAt,
                    firstDate: DateTime(1990),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) setState(() => _asAt = picked);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Charge up to',
                    suffixIcon: Icon(Icons.calendar_today, size: 18),
                  ),
                  child: Text(Fmt.date(_asAt)),
                ),
              ),
              const SizedBox(height: 14),
              preview.when(
                loading: () => const LinearProgressIndicator(),
                error: (e, _) => Text('$e'),
                data: (lines) {
                  final due = lines.where((l) => l.charge > 0).toList();
                  if (due.isEmpty) {
                    return Text(
                      'Everything is already depreciated to '
                      '${Fmt.date(_asAt)}.',
                      style: Theme.of(context).textTheme.bodySmall,
                    );
                  }
                  final total =
                      due.fold<double>(0, (s, l) => s + l.charge);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final line in due)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text('${line.assetNo} · ${line.name}'),
                                    Text(
                                      'net book value after: '
                                      '${Fmt.money(line.netBookValue)}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              Money(line.charge),
                            ],
                          ),
                        ),
                      const Divider(height: 20),
                      Row(children: [
                        const Expanded(
                          child: Text('Total charge',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                        ),
                        Money(total, bold: true),
                      ]),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _working ? null : _post,
          child: _working
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Post'),
        ),
      ],
    );
  }

  Future<void> _post() async {
    setState(() => _working = true);
    String? runId;
    final ok = await runWithFeedback(
      context,
      action: () async {
        runId = await ref.read(repoProvider)!.runDepreciation(_asAt);
      },
      // Null back from the function means every asset was already up to
      // date, which is a legitimate outcome and not a failure.
      successMessage: 'Depreciation posted',
      pendingMessage: 'Posting…',
    );

    if (!mounted) return;
    setState(() => _working = false);
    if (ok) {
      if (runId == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Nothing to charge — already up to date.'),
        ));
      }
      ref.invalidate(depreciationPreviewProvider);
      Navigator.pop(context, true);
    }
  }
}
