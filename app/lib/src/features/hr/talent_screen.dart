import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/row_actions.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'requisition_editor.dart';
import 'applicant_editor.dart';
import 'appraisal_cycles_dialog.dart';
import 'appraisal_goals_dialog.dart';
import 'appraisal_part.dart';
import 'appraisal_review.dart';
import 'hire_dialog.dart';
import 'referrals_dialog.dart';
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
          actions: [
            IconButton(
              tooltip: 'Referrals',
              icon: const Icon(Icons.groups_outlined),
              onPressed: () => showReferralHires(context),
            ),
          ],
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

  /// Put a drafted vacancy out.
  ///
  /// The rule about who may be opened is `openBlockedBecause`, which
  /// `requisition_editor.dart` has carried since the editor was
  /// written and which nothing consulted, because nothing could open
  /// one. Read here rather than restated: the hiring manager rule has
  /// teeth, and applications to a vacancy nobody owns go into a queue
  /// nobody is reading.
  Future<void> _open(BuildContext context, WidgetRef ref, dynamic r) async {
    final ok = await runWithFeedback(
      context,
      doing: 'open the vacancy',
      successMessage: 'Open. It takes applications now.',
      action: () => ref.read(repoProvider)!.openRequisition(r.id),
    );
    if (ok) ref.invalidate(requisitionsProvider);
  }

  /// Stop one.
  ///
  /// Cancelled rather than deleted: a vacancy that was advertised and
  /// withdrawn is a thing that happened, and the applications against
  /// it are somebody's record of having applied.
  Future<void> _cancel(BuildContext context, WidgetRef ref, dynamic r) async {
    final go = await confirm(
      context,
      title: 'Cancel ${r.title}?',
      message: 'It stops taking applications. Everything already '
          'applied against it stays where it is.',
      confirmLabel: 'Cancel it',
    );
    if (!go || !context.mounted) return;
    final ok = await runWithFeedback(
      context,
      doing: 'cancel the vacancy',
      successMessage: 'Cancelled.',
      action: () => ref.read(repoProvider)!.closeRequisition(r.id),
    );
    if (ok) ref.invalidate(requisitionsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reqs = ref.watch(requisitionsProvider);

    return AsyncView(
      value: reqs,
      onRetry: () => ref.invalidate(requisitionsProvider),
      skeleton: const ListSkeleton(rows: 6, leading: false),
      builder: (list) => list.isEmpty
          ? EmptyState(
              icon: Icons.work_outline,
              title: 'No open roles',
              message: 'Raise a requisition when you need to hire.',
              // Said this and offered no way to do it: nothing in the
              // client wrote to `job_requisitions` at all.
              action: FilledButton.icon(
                key: const ValueKey('req-new-empty'),
                onPressed: () async {
                  if (await showRequisitionEditor(context)) {
                    ref.invalidate(requisitionsProvider);
                  }
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Raise a vacancy'),
              ),
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
                  // `open_requisition` and `close_requisition` have
                  // existed since the table did and nothing called
                  // either, so a vacancy could be drafted and never
                  // opened: `openBlockedBecause` was written, sitting in
                  // the editor, deciding nothing. A draft nobody can
                  // open takes no applications at all.
                  trailing: RowActions(
                    menuKey: 'requisition-actions-${r.id}',
                    leading: r.salaryMin == null
                        ? null
                        : Text(
                            '${Fmt.money(r.salaryMin!)} – ${Fmt.money(r.salaryMax ?? r.salaryMin!)}',
                            style: Theme.of(context).textTheme.bodySmall),
                    actions: [
                      if (openBlockedBecause(r.raw) == null)
                        RowAction(
                          actionKey: 'open-${r.id}',
                          label: 'Open it',
                          icon: Icons.campaign_outlined,
                          onTap: () => _open(context, ref, r),
                        ),
                      // Cancelled and filled are where a requisition
                      // stops, so neither is offered on one already
                      // there.
                      if (r.status == 'draft' ||
                          r.status == 'open' ||
                          r.status == 'on_hold')
                        RowAction(
                          actionKey: 'cancel-${r.id}',
                          label: 'Cancel it',
                          icon: Icons.block_outlined,
                          onTap: () => _cancel(context, ref, r),
                        ),
                    ],
                  ),
                  onTap: () async {
                    if (await showRequisitionEditor(context,
                        requisition: r.raw)) {
                      ref.invalidate(requisitionsProvider);
                    }
                  },
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
  // `hired` is deliberately not on this list. It is not the next label
  // on the pipeline: `0381` refuses a status of hired with nobody on
  // the payroll, because that is what used to happen — the label moved
  // and somebody typed the person into the employee editor again.
  static const _stages = [
    'applied',
    'screening',
    'interview',
    'assessment',
    'offer',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final applicants = ref.watch(applicantsProvider);

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showApplicantEditor(context),
        icon: const Icon(Icons.person_add_outlined),
        label: const Text('Candidate'),
      ),
      body: AsyncView(
      value: applicants,
      onRetry: () => ref.invalidate(applicantsProvider),
      skeleton: const ListSkeleton(rows: 6),
      builder: (list) {
        if (list.isEmpty) {
          return const EmptyState(
            icon: Icons.person_search_outlined,
            title: 'No candidates yet',
            message: 'Add one, and everything recorded here comes across '
                'when they are hired.',
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
                  if (a.currentEmployer != null) 'at ${a.currentEmployer}',
                  if (a.currentPosition != null) a.currentPosition,
                  if (a.expectedSalary != null)
                    'expects ${Fmt.money(a.expectedSalary!)}',
                  if (a.noticePeriodDays != null && a.noticePeriodDays! > 0)
                    '${a.noticePeriodDays}d notice',
                  // Who introduced them, which is what a referral scheme
                  // pays on and what nothing recorded before `0381`.
                  if (a.referrerName != null) 'via ${a.referrerName}'
                  else if (a.source != null) 'via ${a.source}',
                ].whereType<String>().join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
              onTap: () => showApplicantEditor(context, applicant: a),
              // "Interviews" and "Move to Shortlisted" together want
              // more than a phone has, so below a breakpoint they are
              // one menu. `scripts/check_narrow_rows.py` measured this
              // row at 104 pixels PAST the edge of a 360px screen.
              trailing: RowActions(
                menuKey: 'applicant-actions-${a.id}',
                actions: [
                  RowAction(
                    actionKey: 'interviews-${a.id}',
                    label: 'Interviews',
                    icon: Icons.event_outlined,
                    onTap: () => showInterviews(context, a.id, a.fullName),
                  ),
                  // Hiring is not the next label on the pipeline: it
                  // makes the employee record out of this one and links
                  // the two, so nobody retypes the name, the phone
                  // number and the NRIC from the record in front of
                  // them.
                  if (!a.isHired && a.status == 'offer')
                    RowAction(
                      actionKey: 'hire-${a.id}',
                      label: 'Hire',
                      icon: Icons.badge_outlined,
                      emphasis: RowActionEmphasis.filled,
                      onTap: () => _hire(context, ref, a),
                    )
                  else if (next != null && !a.isHired)
                    RowAction(
                      actionKey: 'advance-${a.id}',
                      label: 'Move to ${Fmt.label(next)}',
                      icon: Icons.arrow_forward,
                      emphasis: RowActionEmphasis.outlined,
                      onTap: () => _advance(context, ref, a, next),
                    ),
                ],
              ),
            );
          },
        );
      },
      ),
    );
  }

  Future<void> _hire(
      BuildContext context, WidgetRef ref, Applicant a) async {
    await showHireDialog(context, a);
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
        skeleton: const ListSkeleton(rows: 6, leading: false),
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
