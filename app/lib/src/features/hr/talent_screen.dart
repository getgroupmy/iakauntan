import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

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
              trailing: next == null
                  ? null
                  : OutlinedButton(
                      onPressed: () => _advance(context, ref, a, next),
                      child: Text('Move to ${Fmt.label(next)}'),
                    ),
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

    return AsyncView(
      value: appraisals,
      onRetry: () => ref.invalidate(appraisalsProvider),
      builder: (list) => list.isEmpty
          ? const EmptyState(
              icon: Icons.assessment_outlined,
              title: 'No appraisals yet',
              message: 'Start a cycle to open self and manager reviews.',
            )
          : ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final a = list[i];
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: Space.lg, vertical: Space.sm),
                  title: Row(children: [
                    Flexible(
                      child: Text(a.employeeName ?? '—',
                          overflow: TextOverflow.ellipsis,
                          style:
                              const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: Space.sm),
                    StatusChip(a.status, compact: true),
                  ]),
                  subtitle: Text(
                    [
                      if (a.cycleName != null) a.cycleName,
                      if (a.selfRating != null) 'self ${a.selfRating}',
                      if (a.managerRating != null)
                        'manager ${a.managerRating}',
                    ].whereType<String>().join(' · '),
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: a.finalRating == null
                      ? null
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text('${a.finalRating}',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700)),
                            if (a.recommendedIncrement != null)
                              Text('+${a.recommendedIncrement}% proposed',
                                  style:
                                      Theme.of(context).textTheme.bodySmall),
                          ],
                        ),
                );
              },
            ),
    );
  }
}
