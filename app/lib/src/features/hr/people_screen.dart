import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import 'attendance_month.dart';
import 'expiring_documents.dart';

/// The company directory. Everyone can see who works here; only HR and
/// the person themselves get the full record behind it, which is why
/// this list carries no pay figures at all.
class PeopleScreen extends ConsumerStatefulWidget {
  const PeopleScreen({super.key});

  @override
  ConsumerState<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends ConsumerState<PeopleScreen> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final people = ref.watch(directoryProvider);
    final canManageHr = ref.watch(canManageHrProvider);
    final narrow = MediaQuery.sizeOf(context).width < 700;

    return Scaffold(
      appBar: AppBar(
        title: const Text('People'),
        actions: [
          // Everybody's month. `attendance_records` has carried the
          // lateness and the overtime all along and nothing listed
          // them, so who was late was a question the HR module could
          // not answer.
          if (canManageHr)
            IconButton(
              key: const ValueKey('attendance-month'),
              tooltip: 'Attendance this month',
              icon: const Icon(Icons.fingerprint),
              onPressed: () => showAttendanceMonth(context),
            ),
          // The list `0025` built an index for and never wrote. Without
          // it a lapsing work permit is only findable by opening every
          // employee — and an expired pass is the company's offence.
          if (canManageHr)
            IconButton(
              key: const ValueKey('expiring-documents'),
              tooltip: 'Documents expiring',
              icon: const Icon(Icons.event_busy_outlined),
              onPressed: () => showExpiringDocuments(context),
            ),
          if (canManageHr)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.md),
              child: FilledButton.icon(
                onPressed: () => context.go('/hr/people/new'),
                icon: const Icon(Icons.person_add_alt, size: 18),
                // The noun goes on the narrowest phones. Measured: the
                // bar was two pixels over at 360 with both icon buttons
                // showing, and Flutter CLIPS a toolbar in a release
                // build rather than reporting it. The list behind the
                // button says who is being added.
                label: Text(narrow ? 'Add' : 'Add employee'),
              ),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.md),
            child: TextField(
              onChanged: (v) => setState(() => _search = v.toLowerCase()),
              decoration: const InputDecoration(
                hintText: 'Search by name, number or department',
                prefixIcon: Icon(Icons.search, size: 20),
              ),
            ),
          ),
        ),
      ),
      body: AsyncView(
        value: people,
        onRetry: () => ref.invalidate(directoryProvider),
        builder: (all) {
          final list = _search.isEmpty
              ? all
              : all
                  .where((e) =>
                      e.fullName.toLowerCase().contains(_search) ||
                      e.employeeNo.toLowerCase().contains(_search) ||
                      (e.departmentName ?? '').toLowerCase().contains(_search))
                  .toList();

          if (list.isEmpty) {
            return EmptyState(
              icon: Icons.groups_outlined,
              title: all.isEmpty ? 'No employees yet' : 'Nobody matches',
              message: all.isEmpty
                  ? 'Add your first employee to start running payroll.'
                  : 'Try a different name or department.',
            );
          }

          final byDept = <String, List<Employee>>{};
          for (final e in list) {
            byDept.putIfAbsent(e.departmentName ?? 'Unassigned', () => []).add(e);
          }
          final departments = byDept.keys.toList()..sort();

          return ListView(
            padding: const EdgeInsets.only(bottom: Space.xxl),
            children: [
              for (final dept in departments) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      Space.lg, Space.lg, Space.lg, Space.sm),
                  child: Row(children: [
                    Text(dept,
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(color: context.scheme.onSurfaceVariant)),
                    const SizedBox(width: Space.sm),
                    Text('${byDept[dept]!.length}',
                        style: Theme.of(context).textTheme.bodySmall),
                  ]),
                ),
                for (final e in byDept[dept]!)
                  _PersonTile(employee: e, canManageHr: canManageHr),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _PersonTile extends StatelessWidget {
  const _PersonTile({required this.employee, required this.canManageHr});

  final Employee employee;
  final bool canManageHr;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: () => context.go('/hr/people/${employee.id}'),
      leading: CircleAvatar(
        backgroundColor: context.scheme.primaryContainer,
        child: Text(Fmt.initials(employee.fullName),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
      ),
      title: Row(children: [
        Flexible(
          child: Text(employee.fullName,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        if (employee.employmentStatus != 'active') ...[
          const SizedBox(width: Space.sm),
          StatusChip(employee.employmentStatus, compact: true),
        ],
      ]),
      subtitle: Text(
        [
          employee.employeeNo,
          if (employee.positionTitle != null) employee.positionTitle,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: employee.email == null
          ? null
          : Text(employee.email!,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: context.scheme.onSurfaceVariant)),
    );
  }
}
