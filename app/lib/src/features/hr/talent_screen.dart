import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'appraisal_cycles_dialog.dart';
import 'appraisal_goals_dialog.dart';
import 'appraisal_part.dart';
import 'appraisal_review.dart';
import 'interviews_dialog.dart';

/// Recruitment and performance. Applicant data is HR-only — it is not
/// company reading material, and the policies enforce that rather than
/// this screen hiding a tab.
class TalentScreen extends ConsumerWidget {
  const TalentScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Talent'),
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Open roles'),
              Tab(text: 'Candidates'),
              Tab(text: 'Appraisals'),
            ],
          ),
        ),
        body: const TabBarView(children: [
          _RequisitionsTab(),
          _CandidatesTab(),
          _AppraisalsTab(),
        ]),
      ),
    );
  }
}

class _RequisitionsTab extends ConsumerWidget {
  const _RequisitionsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reqs = ref.watch(requisitionsProvider);

    return AsyncView(
      value: reqs,
      onRetry: () => ref.invalidate(requisitionsProvider),
      builder: (list) => list.isEmpty
          ? const EmptyState(
              icon: Icons.work_outline,
              title: 'No open roles',
              message: 'Raise a requisition when you need to hire.',
            )
          : ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final r = list[i];
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: Space.lg, vertical: Space.sm),
                  title: Row(children: [
                    Flexible(
                      child: Text(r.title,
                          overflow: TextOverflow.ellipsis,
                          style:
                              const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: Space.sm),
                    StatusChip(r.status, compact: true),
                  ]),
                  subtitle: Text(
                    [
                      r.requisitionNo,
                      if (r.departmentName != null) r.departmentName,
                      '${r.headcount} position(s)',
                      if (r.location != null) r.location,
                    ].whereType<String>().join(' · '),
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: r.salaryMin == null
                      ? null
                      : Text(
                          '${Fmt.money(r.salaryMin!)} – ${Fmt.money(r.salaryMax ?? r.salaryMin!)}',
                          style: Theme.of(context).textTheme.bodySmall),
                );
              },
            ),
    );
  }
}

class _CandidatesTab extends ConsumerWidget {
  const _CandidatesTab();

  /// The pipeline in order, so a candidate can be nudged to the next
  /// stage without a dropdown of every possible state.
  static const _stages = [
    'applied',
    'screening',
    'interview',
    'assessment',
    'offer',
    'hired',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final applicants = ref.watch(applicantsProvider);

    return AsyncView(
      value: applicants,
      onRetry: () => ref.invalidate(applicantsProvider),
      builder: (list) {
        if (list.isEmpty) {
          return const EmptyState(
            icon: Icons.person_search_outlined,
            title: 'No candidates yet',
            message: 'Applicants appear here as they come in.',
          );
        }
        return ListView.separated(
          itemCount: list.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final a = list[i];
            final at = _stages.indexOf(a.status);
            final next = at >= 0 && at < _stages.length - 1
                ? _stages[at + 1]
                : null;

            return ListTile(
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: Space.lg, vertical: Space.sm),
              leading: CircleAvatar(
                backgroundColor: context.scheme.primaryContainer,
                child: Text(Fmt.initials(a.fullName),
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700)),
              ),
              title: Row(children: [
                Flexible(
                  child: Text(a.fullName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: Space.sm),
                StatusChip(a.status, compact: true),
              ]),
              subtitle: Text(
                [
                  if (a.requisitionTitle != null) a.requisitionTitle,
                  if (a.currentPosition != null) a.currentPosition,
                  if (a.expectedSalary != null)
                    'expects ${Fmt.money(a.expectedSalary!)}',
                  if (a.source != null) 'via ${a.source}',
                ].whereType<String>().join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                TextButton(
                  onPressed: () => showInterviews(context, a.id, a.fullName),
                  child: const Text('Interviews'),
                ),
                if (next != null) ...[
                  const SizedBox(width: Space.xs),
                  OutlinedButton(
                    onPressed: () => _advance(context, ref, a, next),
                    child: Text('Move to ${Fmt.label(next)}'),
                  ),
                ],
              ]),
            );
          },
        );
      },
    );
  }

  Future<void> _advance(
      BuildContext context, WidgetRef ref, Applicant a, String next) async {
    await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.moveApplicant(a.id, a.status, next),
      successMessage: '${a.fullName} moved to ${Fmt.label(next)}',
    );
    ref.invalidate(applicantsProvider);
  }
}

class _AppraisalsTab extends ConsumerWidget {
  const _AppraisalsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appraisals = ref.watch(appraisalsProvider);
    // Whose half is whose, from `my_appraisal_parts`. Asked for rather
    // than worked out here: the same function the trigger in `0379`
    // judges changes by, so a button offered is a button that works.
    final parts = ref.watch(myAppraisalPartsProvider);
    final isHr = ref.watch(canManageHrProvider);

    return Scaffold(
      floatingActionButton: isHr
          ? FloatingActionButton.extended(
              onPressed: () => showAppraisalCycles(context),
              icon: const Icon(Icons.event_repeat_outlined),
              label: const Text('Cycles'),
            )
          : null,
      body: AsyncView(
        value: appraisals,
        onRetry: () {
          ref.invalidate(appraisalsProvider);
          ref.invalidate(myAppraisalPartsProvider);
        },
        builder: (list) => list.isEmpty
            ? EmptyState(
                icon: Icons.assessment_outlined,
                title: 'No appraisals yet',
                message: isHr
                    ? 'Open a cycle and everybody gets one to write.'
                    : 'Nothing to write yet. HR opens a cycle and one '
                        'appears here.',
              )
            : Column(
                children: [
                  if (isHr) const _OverdueBanner(),
                  Expanded(
                    child: ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) => _AppraisalTile(
                        appraisal: list[i],
                        part: partFromName(
                            parts.valueOrNull?[list[i].id]),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Who has not written their half, and by how long.
///
/// `self_review_due` and `manager_review_due` have been columns since
/// talent management landed and nothing read either, which made a cycle
/// with deadlines and a cycle without indistinguishable. It is a banner
/// rather than a screen because the answer is only interesting in the
/// week the deadline passes.
class _OverdueBanner extends ConsumerWidget {
  const _OverdueBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final due = ref.watch(appraisalsDueProvider).valueOrNull ?? const [];
    if (due.isEmpty) return const SizedBox.shrink();

    final worst = due.first;
    return Container(
      width: double.infinity,
      color: context.colors.warning.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(
          horizontal: Space.lg, vertical: Space.sm),
      child: Text(
        due.length == 1
            ? '${worst.employeeName} is ${worst.daysLate} day'
                '${worst.daysLate == 1 ? '' : 's'} late on their '
                '${worst.waitingOn}.'
            : '${due.length} reviews are late, the oldest by '
                '${worst.daysLate} day${worst.daysLate == 1 ? '' : 's'} '
                '(${worst.employeeName}, ${worst.waitingOn}).',
        style: TextStyle(fontSize: 12, color: context.colors.warning),
      ),
    );
  }
}

class _AppraisalTile extends ConsumerWidget {
  const _AppraisalTile({required this.appraisal, required this.part});

  final Appraisal appraisal;
  final AppraisalPart part;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = appraisal;
    final action = appraisalAction(
      part: part,
      selfSubmitted: a.selfSubmitted,
      managerSubmitted: a.managerSubmitted,
      completed: a.isComplete,
      selfDue: a.selfReviewDue,
      today: DateTime.now(),
    );

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
          horizontal: Space.lg, vertical: Space.sm),
      title: Row(children: [
        Flexible(
          child: Text(a.employeeName ?? '—',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: Space.sm),
        StatusChip(a.status, compact: true),
      ]),
      subtitle: Text(
        [
          if (a.cycleName != null) a.cycleName,
          'self ${_score(a.selfRating, a.ratingScaleMax)}',
          'manager ${_score(a.managerRating, a.ratingScaleMax)}',
        ].whereType<String>().join(' · '),
        style: const TextStyle(fontSize: 12),
      ),
      onTap: () => _open(context, ref),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (action != AppraisalAction.waiting)
          // The one thing this appraisal is waiting for from this
          // person. Two buttons would be a screen that has not decided.
          FilledButton.tonal(
            onPressed: () => _open(context, ref),
            child: Text(switch (action) {
              AppraisalAction.writeSelf => 'Write mine',
              AppraisalAction.writeManager => 'Review',
              AppraisalAction.finalise => 'Settle',
              AppraisalAction.waiting => '',
            }),
          )
        else if (a.finalRating != null)
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(Fmt.qty(a.finalRating!),
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
              if (a.recommendedIncrement != null)
                Text('+${Fmt.qty(a.recommendedIncrement!)}% proposed',
                    style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        IconButton(
          tooltip: 'Goals',
          icon: const Icon(Icons.flag_outlined, size: 18),
          onPressed: () => showAppraisalGoals(
              context, a.id, a.employeeName ?? 'Appraisal'),
        ),
      ]),
    );
  }

  String _score(double? rating, int scale) =>
      rating == null ? '—' : '${Fmt.qty(rating)}/$scale';

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final changed = await showAppraisalReview(context, appraisal, part);
    if (changed == true) {
      ref.invalidate(appraisalsProvider);
      ref.invalidate(appraisalsDueProvider);
    }
  }
}
