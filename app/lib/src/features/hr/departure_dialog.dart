import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'departure.dart';

/// Recording that somebody has left, and undoing it.
///
/// A dialog rather than three more fields on the editor, because a
/// departure is not an attribute of a person: it is the thing that takes
/// them off the payroll. `0371` will not accept a leaving status without
/// a last working day, and this is where the two are answered together.
Future<bool> showDepartureDialog(
  BuildContext context, {
  required Employee employee,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _DepartureDialog(employee: employee),
    ) ??
    false;

class _DepartureDialog extends ConsumerStatefulWidget {
  const _DepartureDialog({required this.employee});

  final Employee employee;

  @override
  ConsumerState<_DepartureDialog> createState() => _DepartureDialogState();
}

class _DepartureDialogState extends ConsumerState<_DepartureDialog> {
  final _reason = TextEditingController();

  String _kind = 'resigned';
  DateTime? _lastDay;
  DateTime? _noticeGiven;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.employee;
    // A record with no hire date is not something this dialog can fix,
    // and refusing to open would strand it. The database keeps the real
    // rule; here the earliest offered day is simply unbounded.
    final hired = e.hireDate ?? DateTime(1940);
    final why = departureBlockedBecause(
      kind: _kind,
      lastWorkingDay: _lastDay,
      hireDate: hired,
      resignationDate: _noticeGiven,
    );

    return AlertDialog(
      title: Text('${e.fullName} is leaving'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: _kind,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'How'),
                items: [
                  for (final k in departureKinds.entries)
                    DropdownMenuItem(value: k.key, child: Text(k.value)),
                ],
                onChanged: (v) => setState(() => _kind = v!),
              ),
              const SizedBox(height: Space.md),
              _PickDate(
                label: 'Last working day *',
                value: _lastDay,
                first: hired,
                onChanged: (d) => setState(() => _lastDay = d),
              ),
              Padding(
                padding: const EdgeInsets.only(top: Space.xs),
                child: Text(
                  departureEffect(_kind, _lastDay),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (takesResignationDate(_kind)) ...[
                const SizedBox(height: Space.md),
                _PickDate(
                  label: 'Notice given on',
                  value: _noticeGiven,
                  first: hired,
                  onChanged: (d) => setState(() => _noticeGiven = d),
                ),
              ],
              const SizedBox(height: Space.md),
              TextField(
                controller: _reason,
                decoration: const InputDecoration(labelText: 'Reason'),
                maxLines: 2,
              ),
              if (why != null)
                Padding(
                  padding: const EdgeInsets.only(top: Space.md),
                  child: Text(
                    why,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: why != null ? null : _record,
          child: const Text('Record departure'),
        ),
      ],
    );
  }

  Future<void> _record() async {
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.recordDeparture(
            employeeId: widget.employee.id,
            lastWorkingDay: _lastDay!,
            kind: _kind,
            reason: _reason.text.trim().isEmpty ? null : _reason.text.trim(),
            resignationDate: takesResignationDate(_kind) ? _noticeGiven : null,
          ),
      successMessage: 'Recorded. They are off the payroll after '
          '${Fmt.date(_lastDay!)}',
    );
    if (ok && mounted) Navigator.of(context).pop(true);
  }
}

/// Puts somebody back on the payroll.
Future<bool> confirmReinstate(
  BuildContext context,
  WidgetRef ref, {
  required Employee employee,
}) async {
  final yes = await confirm(
    context,
    title: 'Put ${employee.fullName} back on the payroll?',
    message: 'The last working day, the notice date and the reason are '
        'cleared, and the next payroll run pays them again.',
    confirmLabel: 'Reinstate',
  );
  if (!yes || !context.mounted) return false;
  return runWithFeedback(
    context,
    action: () => ref.read(repoProvider)!.reinstateEmployee(employee.id),
    successMessage: 'Back on the payroll',
  );
}

class _PickDate extends StatelessWidget {
  const _PickDate({
    required this.label,
    required this.value,
    required this.first,
    required this.onChanged,
  });

  final String label;
  final DateTime? value;
  final DateTime first;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.md),
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          // Never before the day they joined: the database refuses it and
          // a picker that offers it is a form asking to be rejected.
          firstDate: first,
          lastDate: DateTime(DateTime.now().year + 2),
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: const Icon(Icons.calendar_today_outlined, size: 18),
        ),
        child: Text(value == null ? '—' : Fmt.date(value)),
      ),
    );
  }
}
