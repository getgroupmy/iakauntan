import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';

/// The attendance month.
///
/// `attendance_records` carries the day, the two stamps, the minutes
/// worked, the minutes late and the overtime, and `attendanceProvider`
/// reads the month — watched by nothing. My HR shows today and only
/// today, so an employee could not check the month before payroll ran
/// and nobody in HR could see who had been late. The numbers were all
/// there; the register was not.

/// How one day reads.
///
/// The two stamps are the fact; the minutes are what payroll uses. A
/// day with no clock-out is shown as still open rather than as zero
/// hours, because those are different days and only one of them needs
/// chasing.
String attendanceLine(AttendanceRecord r) {
  if (r.clockIn == null) return Fmt.label(r.status);
  if (r.clockOut == null) {
    return 'In ${Fmt.time(r.clockIn)} · still open';
  }
  return 'In ${Fmt.time(r.clockIn)} · out ${Fmt.time(r.clockOut)}';
}

/// Hours, in the shape a payslip states them.
String workedLabel(int minutes) => '${(minutes / 60).toStringAsFixed(2)}h';

/// What is worth flagging on a day, or null when nothing is.
///
/// Lateness and overtime are the two things anybody looks for. Said
/// only where there is some: a column of "0 late" trains people to
/// stop reading it.
String? attendanceFlags(AttendanceRecord r) {
  final parts = <String>[
    if (r.lateMinutes > 0) '${r.lateMinutes} min late',
    if (r.otMinutes > 0) '${workedLabel(r.otMinutes)} overtime',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// The month, added up.
({int days, int worked, int late, int overtime}) attendanceTotals(
  Iterable<AttendanceRecord> rows,
) {
  var days = 0, worked = 0, late = 0, ot = 0;
  for (final r in rows) {
    // A day nobody clocked into is a row about an absence, not a day
    // worked, and counting it would flatter the total.
    if (r.clockIn != null) days++;
    worked += r.workedMinutes;
    late += r.lateMinutes;
    ot += r.otMinutes;
  }
  return (days: days, worked: worked, late: late, overtime: ot);
}

/// The month somebody actually worked.
Future<void> showAttendanceMonth(
  BuildContext context, {
  String? employeeId,
  String? name,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _MonthDialog(employeeId: employeeId, name: name),
    );

class _MonthDialog extends ConsumerWidget {
  const _MonthDialog({this.employeeId, this.name});

  /// Null for everybody, which is what HR wants; an id for one person,
  /// which is what that person wants.
  final String? employeeId;
  final String? name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(attendanceProvider(employeeId));

    return AlertDialog(
      title: Text(name == null ? 'Attendance this month' : '$name this month'),
      content: SizedBox(
        width: 560,
        height: 460,
        child: AsyncView<List<AttendanceRecord>>(
          value: rows,
          onRetry: () => ref.invalidate(attendanceProvider(employeeId)),
          builder: (list) {
            if (list.isEmpty) {
              return const EmptyState(
                icon: Icons.fingerprint,
                title: 'Nothing recorded',
                message: 'Nobody has clocked in this month.',
              );
            }
            final totals = attendanceTotals(list);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r = list[i];
                      final flags = attendanceFlags(r);
                      return ListTile(
                        dense: true,
                        title: Text(
                          [
                            Fmt.date(r.workDate),
                            if (employeeId == null && r.employeeName != null)
                              r.employeeName!,
                          ].join(' · '),
                        ),
                        subtitle: Text(
                          [
                            attendanceLine(r),
                            if (flags != null) flags,
                          ].join(' · '),
                          style: TextStyle(
                            fontSize: 12,
                            color: flags == null ? null : context.colors.warning,
                          ),
                        ),
                        trailing: Text(
                          workedLabel(r.workedMinutes),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      );
                    },
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.only(top: Space.sm),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          [
                            '${totals.days} day'
                                '${totals.days == 1 ? '' : 's'}',
                            if (totals.late > 0) '${totals.late} min late',
                            if (totals.overtime > 0)
                              '${workedLabel(totals.overtime)} overtime',
                          ].join(' · '),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      Text(
                        workedLabel(totals.worked),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
