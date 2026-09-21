import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';

/// What LHDN is waiting for, and when.
///
/// Every other statutory calendar in this product is computed — SSM's
/// from the incorporation date, SST's from the registration date, quit
/// rent from the state — and income tax, which carries the largest
/// penalties of the three, had none at all until `0668`.
///
/// The screen makes three distinctions the figures alone would not:
///
///   * **What is late comes first and stays.** An obligation missed
///     last month is the one somebody most needs to see; dropping it
///     the day after it was due is exactly backwards.
///   * **The e-filing date is a concession, not a deadline.** It is
///     shown as extra time somebody may have, beside the date they
///     definitely have — never instead of it.
///   * **A period is not always the financial year.** Form E covers a
///     calendar year whatever the year end is, and the row says so.
class TaxCalendarScreen extends ConsumerWidget {
  const TaxCalendarScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filings = ref.watch(taxFilingCalendarProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Tax calendar')),
      body: SingleChildScrollView(
        child: PageBody(
          maxWidth: 900,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionHeader(
                'Falling due',
                subtitle: 'Computed from this company’s own basis periods '
                    'against the section that imposes each one — nothing '
                    'here was typed in, so nothing here can be typed in '
                    'wrongly',
              ),
              AsyncView(
                value: filings,
                onRetry: () => ref.invalidate(taxFilingCalendarProvider),
                skeleton: const CardRowsSkeleton(
                  rows: 5,
                  leadingSize: 28,
                  trailing: 2,
                ),
                builder: (list) {
                  if (list.isEmpty) {
                    return const EmptyState(
                      icon: Icons.event_available_outlined,
                      title: 'Nothing falling due',
                      message:
                          'No income tax deadline lands in the next eight '
                          'months. Start a financial year if this company '
                          'has none — every date here is measured from one.',
                    );
                  }
                  return Column(
                    children: [
                      for (final f in list) _FilingTile(filing: f),
                    ],
                  );
                },
              ),
              const SizedBox(height: Space.lg),
              const _Caveat(),
              const SizedBox(height: Space.xxl),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilingTile extends StatelessWidget {
  const _FilingTile({required this.filing});

  final TaxFiling filing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final late = filing.isOverdue;
    final soon = filing.isImminent;
    final accent = late
        ? scheme.error
        : soon
        ? scheme.tertiary
        : scheme.onSurfaceVariant;

    return Card(
      key: ValueKey('filing-${filing.filingType}-${filing.yearOfAssessment}'),
      margin: const EdgeInsets.only(bottom: Space.sm),
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The form label is what somebody looks for on LHDN's site,
            // so it leads rather than the description of it.
            Container(
              width: 56,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              alignment: Alignment.center,
              child: Text(
                filing.formLabel,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    filing.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (filing.periodFrom != null && filing.periodTo != null)
                    Text(
                      'For ${Fmt.date(filing.periodFrom!)} to '
                      '${Fmt.date(filing.periodTo!)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  if (filing.statuteRef != null)
                    Text(
                      filing.statuteRef!,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  if (filing.description != null) ...[
                    const SizedBox(height: Space.xs),
                    Text(
                      filing.description!,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  // Where the working already exists, this is the way
                  // into it. Where it does not, saying nothing is
                  // better than a button that makes a document
                  // somebody did not ask for.
                  if (filing.hasWorking) ...[
                    const SizedBox(height: Space.xs),
                    _OpenWorking(filing: filing),
                  ],
                ],
              ),
            ),
            const SizedBox(width: Space.md),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  filing.dueDate == null ? '—' : Fmt.date(filing.dueDate!),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: accent,
                  ),
                ),
                Text(
                  _countdown(filing),
                  key: ValueKey(
                    'filing-countdown-${filing.filingType}'
                    '-${filing.yearOfAssessment}',
                  ),
                  style: TextStyle(fontSize: 11, color: accent),
                ),
                // Said as extra time rather than as the date, because
                // the Filing Programme granting it is republished every
                // year and has been changed.
                if (filing.efilingDueDate != null)
                  Text(
                    'e-Filing to ${Fmt.date(filing.efilingDueDate!)}',
                    key: ValueKey(
                      'filing-efiling-${filing.filingType}'
                      '-${filing.yearOfAssessment}',
                    ),
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _countdown(TaxFiling f) {
    if (f.isOverdue) {
      final days = -f.daysLeft;
      return days == 1 ? '1 day late' : '$days days late';
    }
    if (f.daysLeft == 0) return 'Due today';
    return f.daysLeft == 1 ? '1 day left' : '${f.daysLeft} days left';
  }
}

class _OpenWorking extends StatelessWidget {
  const _OpenWorking({required this.filing});

  final TaxFiling filing;

  @override
  Widget build(BuildContext context) {
    final estimate = filing.estimateId;
    final computation = filing.computationId;
    // A CP204 row leads to the estimate; everything else to the
    // computation. A Form C row that opened the estimate would be the
    // right screen for the wrong half of the year.
    final wantsEstimate = filing.filingType.startsWith('cp204');
    final target = wantsEstimate ? estimate : computation;
    if (target == null) return const SizedBox.shrink();

    return TextButton.icon(
      key: ValueKey('filing-open-${filing.filingType}'
          '-${filing.yearOfAssessment}'),
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: () => context.push(
        wantsEstimate
            ? '/tax-estimate/$target'
                '${computation == null ? '' : '?computation=$computation'}'
            : '/tax-computation/$target',
      ),
      icon: const Icon(Icons.open_in_new, size: 14),
      label: Text(
        wantsEstimate ? 'Open the estimate' : 'Open the working',
        style: const TextStyle(fontSize: 12),
      ),
    );
  }
}

class _Caveat extends StatelessWidget {
  const _Caveat();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Text(
        'A calendar, not a filing. Nothing here is submitted to LHDN '
        'and nothing marks an obligation as met. The dates are computed '
        'from the Act and from this company’s own periods; the '
        'e-Filing dates come from the Return Form Filing Programme, '
        'which LHDN republishes each year and has changed — so the '
        'statutory date is the one to work to. A company in its first '
        'basis period, and one claiming an exemption, both have rules '
        'this does not model.',
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
    );
  }
}
