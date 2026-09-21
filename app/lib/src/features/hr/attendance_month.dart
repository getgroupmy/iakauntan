import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

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
    // Said on the row rather than behind a tap. A corrected timesheet
    // is a changed number, and the person it belongs to should be able
    // to see that it was changed without asking.
    if (r.isAdjusted) 'corrected',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Why this day cannot be corrected, or null when it can.
///
/// Not about who is asking — `adjust_attendance` refuses anybody who is
/// not HR and refuses a day inside a closed pay period, and both are
/// the server's to enforce. This is about which rows a correction is a
/// sensible offer on at all.
///
/// A day nobody clocked into has no times to correct: `absent` and
/// `on_leave` are rows about an absence, and giving them clock times
/// would turn an absence into a day worked without anybody saying so.
/// That is a different act — booking leave, or reversing it — and it
/// belongs on a different screen.
String? correctionBlockedBecause(AttendanceRecord r) {
  if (r.clockIn == null) {
    // The label first, so the sentence reads with `Fmt.label`'s title
    // case rather than around it.
    return '${Fmt.label(r.status)} is a day that was recorded rather '
        'than measured, so there are no times on it to correct.';
  }
  return null;
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
          skeleton: const ListSkeleton(rows: 6, leading: false),
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
                        // 0363. Only HR, and the server says so too —
                        // this is which rows to offer, not who may.
                        onTap: !ref.read(canManageHrProvider)
                            ? null
                            : () => showDialog<void>(
                                context: context,
                                builder: (_) => _CorrectDayDialog(record: r),
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

/// Correcting one day's clock times.
///
/// 0363. The three columns this writes — `is_adjusted`, `adjusted_by`
/// and `adjustment_reason` — have existed since 0027 and nothing had
/// ever written one. They are the right three: what anybody asks about
/// a corrected timesheet is who changed it and why, not what it says
/// now.
class _CorrectDayDialog extends ConsumerStatefulWidget {
  const _CorrectDayDialog({required this.record});

  final AttendanceRecord record;

  @override
  ConsumerState<_CorrectDayDialog> createState() => _CorrectDayDialogState();
}

class _CorrectDayDialogState extends ConsumerState<_CorrectDayDialog> {
  final _reason = TextEditingController();
  TimeOfDay? _in;
  TimeOfDay? _out;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final r = widget.record;
    _in = r.clockIn == null ? null : TimeOfDay.fromDateTime(r.clockIn!);
    _out = r.clockOut == null ? null : TimeOfDay.fromDateTime(r.clockOut!);
    _reason.text = r.adjustmentReason ?? '';
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  DateTime _at(TimeOfDay t) {
    final d = widget.record.workDate;
    return DateTime(d.year, d.month, d.day, t.hour, t.minute);
  }

  Future<void> _pick(bool arriving) async {
    final now = arriving ? _in : _out;
    final picked = await showTimePicker(
      context: context,
      initialTime: now ?? const TimeOfDay(hour: 9, minute: 0),
    );
    if (picked == null || !mounted) return;
    setState(() => arriving ? _in = picked : _out = picked);
  }

  Future<void> _save() async {
    final arrived = _in;
    if (arrived == null) return;
    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      pendingMessage: 'Correcting…',
      successMessage: 'Corrected',
      action: () => ref.read(repoProvider)!.adjustAttendance(
        recordId: widget.record.id,
        clockIn: _at(arrived),
        clockOut: _out == null ? null : _at(_out!),
        reason: _reason.text.trim(),
      ),
    );
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(attendanceProvider);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.record;
    final blocked = correctionBlockedBecause(r);
    if (blocked != null) {
      return AlertDialog(
        title: Text(Fmt.date(r.workDate)),
        content: Text(blocked),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    }

    // Blank until a reason is typed. The server refuses without one and
    // it is right to: a changed number nobody can account for is worse
    // than an uncorrected one, and the person it belongs to is who will
    // be asked about it.
    final ready = _in != null && _reason.text.trim().isNotEmpty;

    return AlertDialog(
      title: Text('Correct ${Fmt.date(r.workDate)}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Arrived'),
            trailing: Text(_in?.format(context) ?? '—'),
            onTap: _saving ? null : () => _pick(true),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Left'),
            // A day with no clock-out is a day nobody knows the length
            // of, which is what `incomplete` says. Leaving it blank
            // keeps it that way rather than inventing an hour.
            subtitle: _out == null
                ? const Text('Still open — leave it if you do not know')
                : null,
            trailing: Text(_out?.format(context) ?? '—'),
            onTap: _saving ? null : () => _pick(false),
          ),
          const SizedBox(height: Space.sm),
          TextField(
            controller: _reason,
            onChanged: (_) => setState(() {}),
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Why *',
              hintText: 'Forgot to clock out; confirmed with her supervisor',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving || !ready ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Correct it'),
        ),
      ],
    );
  }
}
