import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

/// Who is away, and how to reach them.
///
/// `leave_requests.contact_while_away` has been a column since `0027`
/// and nothing ever wrote it. The only write path is a SECURITY
/// DEFINER function that had no parameter for it, so no form could
/// have reached it however it was built — which is why the fix was a
/// migration and not a text field. `0395` gives it, lets the person
/// who is away correct it after the request has left their hands, and
/// adds the report this dialog reads.
///
/// It is deliberately narrow. HR sees the organization; anybody else
/// sees their own reporting line and their own leave, which is the set
/// the table's select policy already allows. A contact-while-away is a
/// personal number, not a directory entry.

/// How a row reads in a list.
///
/// The window matters more than the two dates: somebody whose leave
/// started last week and runs to next week is away *now*, and printing
/// a date range makes the reader work that out for themselves.
String describeAbsence(Map<String, dynamic> row, {DateTime? asAt}) {
  final today = _dayOf(asAt ?? DateTime.now());
  final start = Fmt.parseDate(row['start_date']);
  final end = Fmt.parseDate(row['end_date']);
  if (start == null || end == null) return 'Away';

  final from = _dayOf(start);
  final to = _dayOf(end);
  if (today.isBefore(from)) {
    return from.difference(today).inDays == 1
        ? 'Away from tomorrow'
        : 'Away from ${Fmt.date(from)}';
  }
  if (today.isAfter(to)) return 'Back since ${Fmt.date(to)}';
  return to.difference(today).inDays == 0
      ? 'Back tomorrow'
      : 'Away until ${Fmt.date(to)}';
}

/// What goes where the contact goes.
///
/// A row with no contact is the interesting one — it is the absence
/// nobody can do anything about — so it says so rather than leaving a
/// blank that reads as a rendering fault.
String describeContact(Map<String, dynamic> row) {
  final contact = row['contact_while_away']?.toString().trim();
  if (contact == null || contact.isEmpty) return 'No contact given';
  return contact;
}

/// True when nobody knows how to reach this person.
///
/// Read off the report's own `has_contact` rather than recomputed from
/// the text, so a contact of `''` cannot count as one on this side
/// after the database went to the trouble of storing it as null.
bool needsContact(Map<String, dynamic> row) => row['has_contact'] != true;

DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

/// Whether there is any point offering to change the contact.
///
/// The same rule `update_leave_contact` enforces, so the screen does
/// not offer a button the database will refuse: a live request, and
/// leave that has not already ended. This is a convenience, not the
/// control — the control is in the function, which is where it has to
/// be, and a build of this that got the rule wrong would produce a
/// refusal and not a bad row.
bool canEditContact(LeaveRequest request, {DateTime? asAt}) {
  if (!const ['draft', 'submitted', 'approved'].contains(request.status)) {
    return false;
  }
  final today = _dayOf(asAt ?? DateTime.now());
  return !_dayOf(request.endDate).isBefore(today);
}

/// Ask for the number to call, on a request already submitted.
Future<bool> showEditLeaveContact(
  BuildContext context,
  LeaveRequest request,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _EditContactDialog(request: request),
    ) ??
    false;

class _EditContactDialog extends ConsumerStatefulWidget {
  const _EditContactDialog({required this.request});

  final LeaveRequest request;

  @override
  ConsumerState<_EditContactDialog> createState() =>
      _EditContactDialogState();
}

class _EditContactDialogState extends ConsumerState<_EditContactDialog> {
  late final TextEditingController _contact =
      TextEditingController(text: widget.request.contactWhileAway ?? '');
  bool _saving = false;

  @override
  void dispose() {
    _contact.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Where to reach you'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Leave ${widget.request.requestNo}, '
                '${describeAbsence({
                  'start_date': Fmt.iso(widget.request.startDate),
                  'end_date': Fmt.iso(widget.request.endDate),
                })}.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: Space.md),
              TextField(
                controller: _contact,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Number or address',
                  helperText: 'Leave it empty to remove the contact.',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save'),
          ),
        ],
      );

  Future<void> _save() async {
    setState(() => _saving = true);
    final text = _contact.text.trim();
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.updateLeaveContact(
            widget.request.id,
            text.isEmpty ? null : text,
          ),
      successMessage:
          text.isEmpty ? 'Contact removed' : 'Saved — the office has it',
    );
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }
}

/// Everyone away over the coming month, and how to reach them.
Future<void> showWhoIsAway(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => const _WhoIsAwayDialog(),
    );

class _WhoIsAwayDialog extends ConsumerStatefulWidget {
  const _WhoIsAwayDialog();

  @override
  ConsumerState<_WhoIsAwayDialog> createState() => _WhoIsAwayDialogState();
}

class _WhoIsAwayDialogState extends ConsumerState<_WhoIsAwayDialog> {
  /// Thirty days ahead. Far enough to see the trip somebody has not
  /// left a number for while there is still time to ask them for one,
  /// which is the whole use of the list.
  int _days = 30;

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(whoIsAwayProvider(_days));

    return AlertDialog(
      title: const Text('Who is away'),
      content: SizedBox(
        width: 640,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Today')),
                ButtonSegment(value: 7, label: Text('This week')),
                ButtonSegment(value: 30, label: Text('30 days')),
              ],
              selected: {_days},
              onSelectionChanged: (v) => setState(() => _days = v.first),
            ),
            const SizedBox(height: Space.md),
            Expanded(
              child: AsyncView(
                value: rows,
                onRetry: () => ref.invalidate(whoIsAwayProvider(_days)),
                skeleton: const ListSkeleton(rows: 6, leading: false),
                builder: (list) {
                  if (list.isEmpty) {
                    return const EmptyState(
                      icon: Icons.event_available_outlined,
                      title: 'Nobody is away',
                      message: 'Approved leave inside this window shows '
                          'here, with the number to call.',
                    );
                  }
                  return ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final row = list[i];
                      final missing = needsContact(row);
                      return ListTile(
                        title: Text(row['employee_name']?.toString() ?? ''),
                        subtitle: Text(
                          '${row['leave_type'] ?? ''} — '
                          '${describeAbsence(row)}',
                        ),
                        trailing: Text(
                          describeContact(row),
                          style: missing
                              ? TextStyle(
                                  color: Theme.of(context).colorScheme.error)
                              : null,
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
