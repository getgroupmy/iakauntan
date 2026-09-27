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
///   * **Started is not done.** A Form C somebody has opened stays on
///     the list. Only `filed` and `does not apply` take one off, and
///     both of those move it to the recorded side rather than
///     deleting it.
class TaxCalendarScreen extends ConsumerStatefulWidget {
  const TaxCalendarScreen({super.key});

  @override
  ConsumerState<TaxCalendarScreen> createState() =>
      _TaxCalendarScreenState();
}

class _TaxCalendarScreenState extends ConsumerState<TaxCalendarScreen> {
  bool _showRecorded = false;

  void _reload() {
    ref.invalidate(taxFilingCalendarProvider);
    ref.invalidate(taxFilingHistoryProvider);
  }

  Future<void> _record(TaxFiling f) async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _RecordDialog(filing: f),
    );
    if (done == true) _reload();
  }

  Future<void> _putBack(TaxFilingRecord r) async {
    final periodTo = r.periodTo;
    if (periodTo == null) return;
    final done = await runWithFeedback(
      context,
      doing: 'put the deadline back',
      successMessage: 'Back on the list',
      action: () => ref.read(repoProvider)!.clearTaxFiling(
        filingType: r.filingType,
        periodTo: periodTo,
      ),
    );
    if (done) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final filings = ref.watch(taxFilingCalendarProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Tax calendar')),
      body: SingleChildScrollView(
        child: PageBody(
          maxWidth: 900,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: Space.md),
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: false,
                      label: Text('Falling due'),
                      icon: Icon(Icons.event_outlined, size: 16),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text('Recorded'),
                      icon: Icon(Icons.fact_check_outlined, size: 16),
                    ),
                  ],
                  selected: {_showRecorded},
                  onSelectionChanged: (v) =>
                      setState(() => _showRecorded = v.first),
                ),
              ),
              if (_showRecorded)
                _History(onPutBack: _putBack)
              else ...[
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
                      for (final f in list)
                        _FilingTile(filing: f, onRecord: () => _record(f)),
                    ],
                  );
                },
              ),
              ],
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
  const _FilingTile({required this.filing, required this.onRecord});

  final TaxFiling filing;
  final VoidCallback onRecord;

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
                  // Started, and still owed. Said plainly rather than
                  // shown as a tick, because a Form C somebody opened
                  // is exactly as unfiled as one nobody has touched.
                  if (filing.isStarted)
                    Padding(
                      padding: const EdgeInsets.only(top: Space.xs),
                      child: Text(
                        'Started — not filed',
                        key: ValueKey(
                          'filing-started-${filing.filingType}'
                          '-${filing.yearOfAssessment}',
                        ),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: scheme.tertiary,
                        ),
                      ),
                    ),
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
                TextButton(
                  key: ValueKey('filing-record-${filing.filingType}'
                      '-${filing.yearOfAssessment}'),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: onRecord,
                  child: const Text('Record', style: TextStyle(fontSize: 12)),
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

/// What was recorded, after the fact.
///
/// Nothing disappears when a deadline comes off the calendar — it
/// moves here, including a dismissal and the reason given for it. A
/// CP58 somebody clicked away has to be findable when LHDN asks about
/// it, and this is where they find it.
class _History extends ConsumerWidget {
  const _History({required this.onPutBack});

  final Future<void> Function(TaxFilingRecord) onPutBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(
          'Recorded',
          subtitle: 'What somebody said was done about each obligation — '
              'a note, not a submission, and nothing here was checked '
              'with LHDN',
        ),
        AsyncView(
          value: ref.watch(taxFilingHistoryProvider),
          onRetry: () => ref.invalidate(taxFilingHistoryProvider),
          skeleton: const CardRowsSkeleton(
            rows: 4,
            leadingSize: 28,
            trailing: 2,
          ),
          builder: (list) {
            if (list.isEmpty) {
              return const EmptyState(
                icon: Icons.fact_check_outlined,
                title: 'Nothing recorded yet',
                message:
                    'Record a filing from the list of what is falling '
                    'due, and it moves here.',
              );
            }
            return Column(
              children: [
                for (final r in list)
                  Card(
                    key: ValueKey(
                      'recorded-${r.filingType}-${r.yearOfAssessment}',
                    ),
                    margin: const EdgeInsets.only(bottom: Space.sm),
                    child: Padding(
                      padding: const EdgeInsets.all(Space.md),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 56,
                            padding:
                                const EdgeInsets.symmetric(vertical: 6),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(Radii.sm),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              r.formLabel,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: Space.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  r.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (r.periodTo != null)
                                  Text(
                                    'To ${Fmt.date(r.periodTo!)}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                if (r.reference != null &&
                                    r.reference!.isNotEmpty)
                                  Text(
                                    'Acknowledgement ${r.reference}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                if (r.notes != null && r.notes!.isNotEmpty)
                                  Padding(
                                    padding:
                                        const EdgeInsets.only(top: Space.xs),
                                    child: Text(
                                      r.notes!,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                TextButton.icon(
                                  key: ValueKey('recorded-clear-'
                                      '${r.filingType}-'
                                      '${r.yearOfAssessment}'),
                                  style: TextButton.styleFrom(
                                    padding: EdgeInsets.zero,
                                    minimumSize: const Size(0, 28),
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  onPressed: () => onPutBack(r),
                                  icon: const Icon(Icons.undo, size: 14),
                                  label: const Text(
                                    'Put it back on the list',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: Space.md),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                r.isDismissed
                                    ? 'Does not apply'
                                    : r.filedOn == null
                                    ? 'Filed'
                                    : Fmt.date(r.filedOn!),
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: r.isDismissed
                                      ? scheme.onSurfaceVariant
                                      : scheme.onSurface,
                                ),
                              ),
                              // Late is its own answer rather than two
                              // dates for the reader to subtract: it is
                              // what a penalty is assessed on.
                              if (r.wasLate)
                                Text(
                                  'After the deadline',
                                  key: ValueKey('recorded-late-'
                                      '${r.filingType}-'
                                      '${r.yearOfAssessment}'),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: scheme.error,
                                  ),
                                ),
                              if (r.dueDate != null)
                                Text(
                                  'Was due ${Fmt.date(r.dueDate!)}',
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
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// Recording one.
///
/// Two outcomes, and they are not the same act. "Filed" wants an
/// acknowledgement number, because that is the only thing that proves
/// it happened. "Does not apply" wants a REASON, and the database
/// refuses it without one — dismissing a statutory obligation is
/// exactly the thing somebody should have to own.
class _RecordDialog extends ConsumerStatefulWidget {
  const _RecordDialog({required this.filing});

  final TaxFiling filing;

  @override
  ConsumerState<_RecordDialog> createState() => _RecordDialogState();
}

class _RecordDialogState extends ConsumerState<_RecordDialog> {
  final _reference = TextEditingController();
  final _notes = TextEditingController();
  String _status = 'filed';
  late DateTime _filedOn = DateTime.now();

  @override
  void dispose() {
    _reference.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final periodTo = widget.filing.periodTo;
    if (periodTo == null) return;
    // Said here as well as in the database, because a check constraint
    // surfacing as a message about a column name is not an answer
    // somebody can act on.
    if (_status == 'not_applicable' && _notes.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Say why it does not apply — it has to be answerable later.',
          ),
        ),
      );
      return;
    }
    final done = await runWithFeedback(
      context,
      doing: 'record the filing',
      successMessage: 'Recorded',
      action: () => ref.read(repoProvider)!.recordTaxFiling(
        filingType: widget.filing.filingType,
        periodTo: periodTo,
        status: _status,
        filedOn: _status == 'filed' ? _filedOn : null,
        reference: _reference.text.trim().isEmpty
            ? null
            : _reference.text.trim(),
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      ),
    );
    if (done && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.filing;
    return AlertDialog(
      title: Text('${f.formLabel} — ${f.name}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'in_preparation',
                    label: Text('Started'),
                  ),
                  ButtonSegment(value: 'filed', label: Text('Filed')),
                  ButtonSegment(
                    value: 'not_applicable',
                    label: Text('Does not apply'),
                  ),
                ],
                selected: {_status},
                onSelectionChanged: (v) =>
                    setState(() => _status = v.first),
              ),
              const SizedBox(height: Space.md),
              if (_status == 'in_preparation')
                Text(
                  'It stays on the list. Starting a return is not '
                  'filing it, and a calendar that cleared on the '
                  'intention to do something would be worse than one '
                  'that never cleared at all.',
                  key: const ValueKey('record-stays'),
                  style: Theme.of(context).textTheme.bodySmall,
                )
              else if (_status == 'filed') ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Filed on ${Fmt.date(_filedOn)}',
                        key: const ValueKey('record-filed-on'),
                      ),
                    ),
                    TextButton(
                      key: const ValueKey('record-pick-date'),
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _filedOn,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) {
                          setState(() => _filedOn = picked);
                        }
                      },
                      child: const Text('Change'),
                    ),
                  ],
                ),
                const SizedBox(height: Space.sm),
                TextField(
                  key: const ValueKey('record-reference'),
                  controller: _reference,
                  decoration: const InputDecoration(
                    labelText: 'LHDN acknowledgement',
                    helperText: 'The only thing that proves it happened. '
                        'The format differs by form and by year, so it '
                        'is not checked.',
                    helperMaxLines: 3,
                  ),
                ),
              ] else
                Text(
                  'It comes off the list and the reason stays readable '
                  'here. A dismissal has to be answerable when LHDN '
                  'asks about it.',
                  key: const ValueKey('record-dismissal'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: Space.md),
              TextField(
                key: const ValueKey('record-notes'),
                controller: _notes,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: _status == 'not_applicable'
                      ? 'Why it does not apply'
                      : 'Notes',
                ),
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
          key: const ValueKey('record-save'),
          onPressed: _save,
          child: const Text('Record'),
        ),
      ],
    );
  }
}
