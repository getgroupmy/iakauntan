import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// One row per financial year, newest first.
///
/// The status is the whole story of a filing — draft, frozen, lodged —
/// and it is the only thing on this screen that is not a date, so it
/// carries the colour.
class FilingsScreen extends ConsumerWidget {
  const FilingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filings = ref.watch(fsFilingsProvider);
    final canWrite = ref.watch(canWriteProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Financial statements')),
      body: AsyncView(
        value: filings,
        onRetry: () => ref.invalidate(fsFilingsProvider),
        builder: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.description_outlined,
              title: 'No accounts prepared yet',
              message:
                  'Start a financial year to map it to the MBRS '
                  'taxonomy and prepare it for lodgement.',
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) => _FilingTile(row: list[i]),
          );
        },
      ),
      floatingActionButton: canWrite
          ? FloatingActionButton.extended(
              onPressed: () => _newFiling(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('Financial year'),
            )
          : null,
    );
  }

  Future<void> _newFiling(BuildContext context, WidgetRef ref) async {
    final year = await showDialog<({DateTime start, DateTime end})>(
      context: context,
      builder: (_) => const _NewFilingDialog(),
    );
    if (year == null || !context.mounted) return;

    String? id;
    final ok = await runWithFeedback(
      context,
      action: () async {
        id = await ref
            .read(repoProvider)!
            .createFsFiling(fyStart: year.start, fyEnd: year.end);
      },
      successMessage: null,
    );
    ref.invalidate(fsFilingsProvider);
    if (ok && id != null && context.mounted) {
      context.go('/financial-statements/${id!}');
    }
  }
}

class _FilingTile extends StatelessWidget {
  const _FilingTile({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final status = row['status']?.toString() ?? 'draft';
    final end = Fmt.parseDate(row['fy_end']);
    final audit = row['audit_status']?.toString() ?? 'audited';

    return ListTile(
      leading: Icon(
        switch (status) {
          'lodged' => Icons.verified_outlined,
          'frozen' => Icons.lock_outline,
          _ => Icons.edit_note_outlined,
        },
        color: switch (status) {
          'lodged' => context.colors.success,
          'frozen' => context.colors.info,
          _ => null,
        },
      ),
      title: Text(
        end == null ? 'Financial year' : 'Year ended ${Fmt.date(end)}',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [
          (row['framework']?.toString() ?? 'mpers').toUpperCase(),
          Fmt.label(audit),
          if (row['mbrs_reference'] != null) '${row['mbrs_reference']}',
        ].join(' · '),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: StatusChip(status),
      onTap: () => context.go('/financial-statements/${row['id']}'),
    );
  }
}

/// Asking for the year end and deriving the start, rather than asking
/// for both. A financial year that does not run to the day before the
/// next one starts is a data-entry slip, not a choice.
class _NewFilingDialog extends StatefulWidget {
  const _NewFilingDialog();

  @override
  State<_NewFilingDialog> createState() => _NewFilingDialogState();
}

class _NewFilingDialogState extends State<_NewFilingDialog> {
  DateTime _end = DateTime(DateTime.now().year - 1, 12, 31);

  DateTime get _start => DateTime(
    _end.year - 1,
    _end.month,
    _end.day,
  ).add(const Duration(days: 1));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Which financial year?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Year end'),
            subtitle: Text(Fmt.date(_end)),
            trailing: const Icon(Icons.calendar_today_outlined, size: 18),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _end,
                firstDate: DateTime(2015),
                lastDate: DateTime(2100),
              );
              if (picked != null) setState(() => _end = picked);
            },
          ),
          const SizedBox(height: Space.sm),
          Text(
            'The year will run from ${Fmt.date(_start)}.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, (start: _start, end: _end)),
          child: const Text('Create'),
        ),
      ],
    );
  }
}
