import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/download.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import 'payslip_pdf.dart';

/// One payslip, laid out the way a Malaysian payslip is read: what was
/// earned, what was taken off, what the company paid on top, and the
/// wage each authority actually charged on.
class PayslipScreen extends ConsumerWidget {
  const PayslipScreen({super.key, required this.payslipId});

  final String payslipId;

  /// The payslip as a document the employee can keep. Falls back to
  /// saying so rather than pretending, because saveBytesFile only works
  /// in the browser.
  Future<void> _downloadPdf(
      BuildContext context, WidgetRef ref, Payslip slip) async {
    final messenger = ScaffoldMessenger.of(context);
    final org = ref.read(currentOrgProvider).valueOrNull;
    if (org == null) {
      messenger.showSnackBar(
          const SnackBar(content: Text('No company selected')));
      return;
    }

    final bytes = await buildPayslipPdf(org: org, payslip: slip);
    final stem = [
      slip.employeeNo ?? slip.employeeName,
      slip.periodCode ?? '',
    ].join('-').replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-').toLowerCase();
    final saved =
        await saveBytesFile('payslip-$stem.pdf', 'application/pdf', bytes);
    messenger.showSnackBar(SnackBar(
      content: Text(saved
          ? 'Downloaded'
          : 'PDF download is only available in the browser'),
    ));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final payslip = ref.watch(payslipProvider(payslipId));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/hr/me'),
        ),
        title: const Text('Payslip'),
        actions: [
          if (payslip.valueOrNull != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.md),
              child: OutlinedButton.icon(
                onPressed: () => _downloadPdf(context, ref, payslip.value!),
                icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                label: const Text('PDF'),
              ),
            ),
        ],
      ),
      body: AsyncView(
        value: payslip,
        onRetry: () => ref.invalidate(payslipProvider),
        builder: (slip) {
          if (slip == null) {
            return const EmptyState(
                icon: Icons.error_outline, title: 'Payslip not found');
          }
          final earnings =
              slip.lines.where((l) => l.kind == 'earning').toList();
          final deductions =
              slip.lines.where((l) => l.kind == 'deduction').toList();
          final employer = slip.lines
              .where((l) => l.kind == 'employer_contribution')
              .toList();

          return SingleChildScrollView(
            child: PageBody(
              maxWidth: 900,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!slip.schedulesVerified) const _UnverifiedBanner(),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(Space.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(slip.employeeName,
                              style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 2),
                          Text(
                            [
                              slip.employeeNo,
                              slip.positionTitle,
                              slip.departmentName,
                              slip.periodCode,
                            ].whereType<String>().join(' · '),
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                    color: context.scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: Space.lg),
                  _LinesCard(
                    title: 'Earnings',
                    lines: earnings,
                    total: slip.grossPay,
                    totalLabel: 'Gross pay',
                  ),
                  const SizedBox(height: Space.lg),
                  _LinesCard(
                    title: 'Deductions',
                    lines: deductions,
                    total: slip.totalDeductions,
                    totalLabel: 'Total deductions',
                    negative: true,
                  ),
                  const SizedBox(height: Space.lg),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(Space.lg),
                      child: Row(children: [
                        Expanded(
                          child: Text('Net pay',
                              style:
                                  Theme.of(context).textTheme.titleMedium),
                        ),
                        Text(Fmt.money(slip.netPay),
                            style: Theme.of(context)
                                .textTheme
                                .headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                      ]),
                    ),
                  ),
                  const SizedBox(height: Space.lg),
                  if (employer.isNotEmpty)
                    _LinesCard(
                      title: 'Paid by the company',
                      subtitle: 'Never deducted from your pay',
                      lines: employer,
                      total: employer.fold<double>(0, (s, l) => s + l.amount),
                      totalLabel: 'Employer cost',
                    ),
                  const SizedBox(height: Space.lg),
                  _BasesCard(slip: slip),
                  const SizedBox(height: Space.xxl),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A payslip produced from a schedule nobody has checked against the
/// gazetted table should say so on its face.
class _UnverifiedBanner extends StatelessWidget {
  const _UnverifiedBanner();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.lg),
      child: Container(
        padding: const EdgeInsets.all(Space.md),
        decoration: BoxDecoration(
          color: context.colors.warning.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(
              color: context.colors.warning.withValues(alpha: 0.35)),
        ),
        child: Row(children: [
          Icon(Icons.info_outline, size: 20, color: context.colors.warning),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              'Calculated from the published statutory percentages. Load the '
              'authority’s gazetted contribution table and mark it verified '
              'before filing returns from these figures.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ]),
      ),
    );
  }
}

class _LinesCard extends StatelessWidget {
  const _LinesCard({
    required this.title,
    required this.lines,
    required this.total,
    required this.totalLabel,
    this.subtitle,
    this.negative = false,
  });

  final String title;
  final String? subtitle;
  final List<PayslipLine> lines;
  final double total;
  final String totalLabel;
  final bool negative;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(title, subtitle: subtitle),
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.xs),
                child: Row(children: [
                  Expanded(
                    child: Text(
                      l.quantity != null
                          ? '${l.description}  (${Fmt.days(l.quantity!)})'
                          : l.description,
                    ),
                  ),
                  Money(negative ? -l.amount : l.amount),
                ]),
              ),
            const Divider(),
            Row(children: [
              Expanded(
                child: Text(totalLabel,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              Money(negative ? -total : total, bold: true),
            ]),
          ],
        ),
      ),
    );
  }
}

/// The wage each authority charged on. SOCSO and EIS cap at the insured
/// ceiling, so these will not match gross pay for higher earners — which
/// is exactly the number people ring up about.
class _BasesCard extends StatelessWidget {
  const _BasesCard({required this.slip});

  final Payslip slip;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader('Contribution wages',
                subtitle: 'The wage each authority charged on'),
            for (final r in <(String, double)>[
              ('EPF wage', slip.epfWage),
              ('SOCSO insured wage', slip.socsoWage),
              ('EIS insured wage', slip.eisWage),
              ('Taxable income', slip.taxableIncome),
            ])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.xs),
                child: Row(children: [
                  Expanded(child: Text(r.$1)),
                  Money(r.$2),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}
