import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/export_log.dart';
import '../../core/format.dart';
import '../../core/pdf_kit.dart' show LetterheadMode;
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/ea_form_repository.dart';
import 'ea_form_pdf.dart';

/// The EA forms an employer owes for a year of assessment.
///
/// Every employee paid in the year gets one by the end of February, and
/// it is what they file their own return from. Three things about this
/// screen are decisions rather than layout:
///
/// **Leavers are on it.** Somebody who resigned in March is owed an EA
/// form for the months they were here, and a list built from current
/// employees would omit exactly the people most likely to chase it.
/// `ea_statements` joins through the payslips instead.
///
/// **What is missing is named before the form is produced.** An EA form
/// without the employee's income tax number is one they cannot file
/// against. The database names what is wrong; this shows it beside the
/// person rather than leaving it to be discovered at the counter.
///
/// **The year is the year of the pay date.** A December salary paid on
/// 5 January is income for the new year. The year picker is therefore
/// about when people were PAID, which the note under it says out loud,
/// because "2025 payroll" and "the 2025 EA form" are not the same
/// twelve payslips.
class EaFormsScreen extends ConsumerStatefulWidget {
  const EaFormsScreen({super.key});

  @override
  ConsumerState<EaFormsScreen> createState() => _EaFormsScreenState();
}

class _EaFormsScreenState extends ConsumerState<EaFormsScreen> {
  /// The year before this one, because an EA form is issued in February
  /// for the year that has just ended. Opening on the current year
  /// would show a form nobody can file yet.
  late int _year = DateTime.now().year - 1;

  /// The years worth offering. Far enough back to reissue a form
  /// somebody has lost and one forward for a company reading it in
  /// December to see where the current year has got to.
  List<int> get _years {
    final now = DateTime.now().year;
    return [for (var y = now; y >= now - 6; y--) y];
  }

  Future<void> _download(BuildContext context, EaSummary row) async {
    final messenger = ScaffoldMessenger.of(context);
    final org = ref.read(currentOrgProvider).valueOrNull;
    final repo = ref.read(eaFormsRepoProvider);
    if (org == null || repo == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No company selected')),
      );
      return;
    }

    final ea = await repo.statement(row.employeeId, _year);
    final bytes = await buildEaFormPdf(
      org: org,
      ea: ea,
      logo: await ref.read(orgLogoProvider.future),
      mode: org.usesPreprintedLetterhead
          ? LetterheadMode.stationery
          : LetterheadMode.printed,
    );
    final stem = [row.employeeNo ?? row.name, '$_year']
        .join('-')
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
        .toLowerCase();
    final saved = await exportBytesFile(
      ref,
      'ea-$stem.pdf',
      'application/pdf',
      bytes,
      what: 'EA form',
      detail: '${row.name} $_year',
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          saved
              ? 'Downloaded'
              : 'PDF download is only available in the browser',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(eaFormsProvider(_year));

    return Scaffold(
      appBar: AppBar(
        title: const Text('EA forms'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: Space.lg),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                key: const ValueKey('ea-year'),
                value: _year,
                items: [
                  for (final y in _years)
                    DropdownMenuItem(value: y, child: Text('$y')),
                ],
                onChanged: (v) => setState(() => _year = v ?? _year),
              ),
            ),
          ),
        ],
      ),
      body: AsyncView(
        value: rows,
        onRetry: () => ref.invalidate(eaFormsProvider(_year)),
        builder: (list) {
          if (list.isEmpty) {
            return EmptyState(
              icon: Icons.description_outlined,
              title: 'Nobody was paid in $_year',
              message:
                  'An EA form covers what was PAID in a year, not what '
                  'was earned in it. A December salary paid on 5 January '
                  'belongs to the following year — try that one.',
            );
          }

          final incomplete = list.where((r) => !r.isReady).length;

          return ListView(
            padding: const EdgeInsets.all(Space.lg),
            children: [
              PageBody(
                maxWidth: 900,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'What was paid in $_year, which is what an EA form '
                      'covers — not what was earned in it.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.scheme.onSurfaceVariant,
                      ),
                    ),
                    if (incomplete > 0) ...[
                      const SizedBox(height: Space.md),
                      Card(
                        color: context.scheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(Space.md),
                          child: Text(
                            incomplete == 1
                                ? 'One form is missing something an '
                                      'employee needs in order to file '
                                      'against it. It is marked below.'
                                : '$incomplete forms are missing something '
                                      'an employee needs in order to file '
                                      'against them. They are marked below.',
                            style: TextStyle(
                              color: context.scheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: Space.md),
                    for (final row in list)
                      _EaRow(
                        row: row,
                        onDownload: () => _download(context, row),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _EaRow extends StatelessWidget {
  const _EaRow({required this.row, required this.onDownload});

  final EaSummary row;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant);

    return Card(
      child: ListTile(
        title: Wrap(
          spacing: Space.sm,
          runSpacing: Space.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(row.name),
            if (row.employmentStatus == 'resigned' ||
                row.employmentStatus == 'terminated')
              const StatusChip('left', compact: true),
            // Not decoration: this employee holds a second EA form for
            // the same year, and the two do not add up to their income
            // unless both are declared.
            if (row.hasPreviousEmployer)
              const StatusChip('earlier_job', compact: true),
            if (!row.isReady) const StatusChip('incomplete', compact: true),
          ],
        ),
        subtitle: Text(
          [
            if (row.employeeNo != null) row.employeeNo!,
            '${row.monthsPaid} month${row.monthsPaid == 1 ? '' : 's'}',
            Fmt.money(row.grossPay),
            if (!row.isReady) 'No ${row.missing.join(', no ')}',
          ].join(' · '),
          style: muted,
        ),
        trailing: IconButton(
          key: ValueKey('ea-download-${row.employeeId}'),
          icon: const Icon(Icons.download_outlined),
          tooltip: 'Download the EA form',
          onPressed: onDownload,
        ),
      ),
    );
  }
}
