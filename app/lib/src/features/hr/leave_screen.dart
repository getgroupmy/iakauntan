import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'who_is_away.dart';

/// Leave requests and approvals in one place. What you see depends on
/// who you are: your own requests, your team's if you manage anyone, the
/// whole company if you are HR — all decided by RLS, not by this screen.
class LeaveScreen extends ConsumerStatefulWidget {
  const LeaveScreen({super.key});

  @override
  ConsumerState<LeaveScreen> createState() => _LeaveScreenState();
}

class _LeaveScreenState extends ConsumerState<LeaveScreen> {
  String _status = 'submitted';

  @override
  Widget build(BuildContext context) {
    final requests = ref.watch(leaveRequestsProvider(_status));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Leave'),
        actions: [
          IconButton(
            tooltip: 'Who is away',
            onPressed: () => showWhoIsAway(context),
            icon: const Icon(Icons.beach_access_outlined),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            child: FilledButton.icon(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const _RequestLeaveDialog(),
              ),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Request leave'),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: FilterBar(
            child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'submitted', label: Text('Awaiting')),
                  ButtonSegment(value: 'approved', label: Text('Approved')),
                  ButtonSegment(value: 'rejected', label: Text('Rejected')),
                  ButtonSegment(value: 'all', label: Text('All')),
                ],
                selected: {_status},
                onSelectionChanged: (s) => setState(() => _status = s.first),
            ),
          ),
        ),
      ),
      body: AsyncView(
        value: requests,
        onRetry: () => ref.invalidate(leaveRequestsProvider),
        builder: (list) => list.isEmpty
            ? EmptyState(
                icon: Icons.event_available_outlined,
                title: _status == 'submitted'
                    ? 'Nothing awaiting a decision'
                    : 'No requests here',
                message: _status == 'submitted'
                    ? 'Requests appear here as soon as they are submitted.'
                    : null,
              )
            : ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) => _LeaveTile(request: list[i]),
              ),
      ),
    );
  }
}

class _LeaveTile extends ConsumerWidget {
  const _LeaveTile({required this.request});

  final LeaveRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canDecide = request.status == 'submitted';
    final span = request.startDate == request.endDate
        ? Fmt.date(request.startDate)
        : '${Fmt.date(request.startDate)} – ${Fmt.date(request.endDate)}';

    final editable = canEditContact(request);

    return ListTile(
      // Tapping a row is how the contact gets corrected. `0038`'s
      // update policy freezes the whole row once it leaves draft, which
      // is right for the dates and wrong for where somebody is, so
      // `0395` gives that one field a path of its own.
      onTap: editable
          ? () async {
              if (await showEditLeaveContact(context, request)) {
                ref.invalidate(leaveRequestsProvider);
              }
            }
          : null,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
      title: Row(children: [
        Flexible(
          child: Text(request.employeeName ?? request.requestNo,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: Space.sm),
        StatusChip(request.status, compact: true),
      ]),
      subtitle: Text(
        '${request.leaveTypeName ?? 'Leave'} · $span · '
        '${Fmt.days(request.totalDays)} day(s)'
        '${request.reason != null && request.reason!.isNotEmpty ? ' · ${request.reason}' : ''}'
        '${request.contactWhileAway != null ? ' · ${request.contactWhileAway}' : ''}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: canDecide
          ? Row(mainAxisSize: MainAxisSize.min, children: [
              TextButton(
                onPressed: () => _decide(context, ref, false),
                child: Text('Reject',
                    style: TextStyle(color: context.colors.danger)),
              ),
              const SizedBox(width: Space.xs),
              FilledButton(
                onPressed: () => _decide(context, ref, true),
                child: const Text('Approve'),
              ),
            ])
          : null,
    );
  }

  Future<void> _decide(BuildContext context, WidgetRef ref, bool approve) async {
    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.decideLeave(request.id, approve),
      successMessage: approve
          ? 'Approved — the days come off the balance'
          : 'Rejected — the held days are released',
    );
    ref.invalidate(leaveRequestsProvider);
    ref.invalidate(myLeaveBalancesProvider);
  }
}

/// Whether a half day may be asked for at all.
///
/// Two conditions, both of which the database also holds — `0397` for
/// the single date and the arithmetic, `0365` for the leave type. This
/// is here so the form does not offer what would be refused; the
/// refusal is still the control, and has to be, because this code runs
/// on a device somebody else owns.
///
/// `0365` wrote its rule and nothing ever set the flag it reads, so it
/// guarded a door nobody could open until `0397`. The switch is the
/// door.
bool canTakeHalfDay({
  required LeaveType? type,
  required DateTime start,
  required DateTime end,
}) {
  if (type == null || !type.allowHalfDay) return false;
  return start.year == end.year &&
      start.month == end.month &&
      start.day == end.day;
}

/// What a request is for, given the dates and whether it is a half day.
///
/// An upper bound, and the database enforces it as one: ten calendar
/// days over a public holiday may honestly be fewer days of leave, and
/// deciding which needs the work calendar that neither side consults.
double leaveDaysFor({
  required DateTime start,
  required DateTime end,
  required bool halfDay,
}) => halfDay ? 0.5 : end.difference(start).inDays + 1;

class _RequestLeaveDialog extends ConsumerStatefulWidget {
  const _RequestLeaveDialog();

  @override
  ConsumerState<_RequestLeaveDialog> createState() => _RequestLeaveDialogState();
}

class _RequestLeaveDialogState extends ConsumerState<_RequestLeaveDialog> {
  final _formKey = GlobalKey<FormState>();
  final _reason = TextEditingController();
  final _contact = TextEditingController();
  String? _typeId;
  DateTime _start = DateTime.now();
  DateTime _end = DateTime.now();
  bool _halfDay = false;
  String _period = 'morning';
  bool _saving = false;

  /// A half day is one date, so the switch is only offered when the two
  /// dates are the same, and it turns itself off when they stop being.
  /// The database says the same thing — `0397` — and this is so the
  /// person is not offered something that will be refused.
  bool get _oneDate => _start.year == _end.year &&
      _start.month == _end.month &&
      _start.day == _end.day;

  LeaveType? _typeOf(List<LeaveType> types) =>
      types.where((x) => x.id == _typeId).firstOrNull;

  bool _allowsHalfDay(List<LeaveType> types) =>
      _typeOf(types)?.allowHalfDay ?? true;

  bool _canHalfDay(List<LeaveType> types) =>
      canTakeHalfDay(type: _typeOf(types), start: _start, end: _end);

  @override
  void dispose() {
    _reason.dispose();
    _contact.dispose();
    super.dispose();
  }

  /// What the request is for.
  ///
  /// Calendar days between the two dates, or half a day when it is one.
  /// This is an upper bound and the database enforces it as one — a
  /// span of ten days over a public holiday may honestly be fewer days
  /// of leave, and deciding which needs the work calendar, which
  /// neither side consults. `0397`'s header sets out why that lower
  /// bound is left unstated rather than invented.
  double get _days =>
      leaveDaysFor(start: _start, end: _end, halfDay: _halfDay);

  @override
  Widget build(BuildContext context) {
    final types = ref.watch(leaveTypesProvider);
    final balances = ref.watch(myLeaveBalancesProvider).valueOrNull ?? const [];

    return AlertDialog(
      title: const Text('Request leave'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              types.when(
                loading: () => const LinearProgressIndicator(),
                error: (e, _) => Text('$e'),
                data: (list) => DropdownButtonFormField<String>(
                  value: _typeId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Leave type *'),
                  items: [
                    for (final t in list)
                      DropdownMenuItem(
                        value: t.id,
                        child: Text(_labelFor(t, balances)),
                      ),
                  ],
                  onChanged: (v) => setState(() {
                    _typeId = v;
                    if (!_allowsHalfDay(list)) _halfDay = false;
                  }),
                  validator: (v) => v == null ? 'Choose a leave type' : null,
                ),
              ),
              const SizedBox(height: Space.md),
              Row(children: [
                Expanded(
                  child: _DateField(
                    label: 'First day',
                    value: _start,
                    onChanged: (d) => setState(() {
                      _start = d;
                      if (_end.isBefore(d)) _end = d;
                      if (!_oneDate) _halfDay = false;
                    }),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: _DateField(
                    label: 'Last day',
                    value: _end,
                    onChanged: (d) => setState(() {
                      _end = d;
                      if (!_oneDate) _halfDay = false;
                    }),
                  ),
                ),
              ]),
              const SizedBox(height: Space.sm),
              // `0027` modelled half days, `0365` wrote the rule about
              // which leave may be taken in them, and nothing had ever
              // set the flag either was about.
              types.maybeWhen(
                data: (list) => Row(children: [
                  Switch(
                    value: _halfDay,
                    onChanged: _canHalfDay(list)
                        ? (v) => setState(() => _halfDay = v)
                        : null,
                  ),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Text(
                      !_oneDate
                          ? 'Half day — for a single date'
                          : !_allowsHalfDay(list)
                              ? 'Half day — not for this kind of leave'
                              : 'Half day',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  if (_halfDay && _canHalfDay(list))
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: 'morning', label: Text('AM')),
                        ButtonSegment(value: 'afternoon', label: Text('PM')),
                      ],
                      selected: {_period},
                      onSelectionChanged: (v) =>
                          setState(() => _period = v.first),
                    ),
                ]),
                orElse: () => const SizedBox.shrink(),
              ),
              const SizedBox(height: Space.sm),
              Text('${Fmt.days(_days)} day(s)',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: Space.md),
              TextFormField(
                controller: _reason,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'Reason'),
              ),
              const SizedBox(height: Space.md),
              // A column since `0027` that nothing could write until
              // `0395` gave the RPC a parameter for it. It can be
              // changed later — where somebody is changes — so it is
              // asked for here and not demanded.
              TextFormField(
                controller: _contact,
                decoration: const InputDecoration(
                  labelText: 'Where to reach you',
                  helperText: 'A number or address that works while you '
                      'are away. You can change this later.',
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
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Submit'),
        ),
      ],
    );
  }

  String _labelFor(LeaveType t, List<LeaveBalance> balances) {
    final b = balances.where((x) => x.leaveTypeId == t.id).firstOrNull;
    if (b == null) return t.name;
    return '${t.name} — ${Fmt.days(b.available)} left';
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.submitLeave(
            leaveTypeId: _typeId!,
            start: _start,
            end: _end,
            days: _days,
            reason: _reason.text.trim().isEmpty ? null : _reason.text.trim(),
            contactWhileAway:
                _contact.text.trim().isEmpty ? null : _contact.text.trim(),
            isHalfDay: _halfDay,
            halfDayPeriod: _halfDay ? _period : null,
          ),
      successMessage: 'Submitted for approval',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(leaveRequestsProvider);
      ref.invalidate(myLeaveBalancesProvider);
      Navigator.pop(context);
    }
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final DateTime value;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.md),
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value,
          firstDate: DateTime(DateTime.now().year - 1),
          lastDate: DateTime(DateTime.now().year + 2),
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: const Icon(Icons.calendar_today_outlined, size: 18),
        ),
        child: Text(Fmt.date(value)),
      ),
    );
  }
}
