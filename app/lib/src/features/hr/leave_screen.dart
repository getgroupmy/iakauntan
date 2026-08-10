import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

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
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.md),
            child: Align(
              alignment: Alignment.centerLeft,
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

    return ListTile(
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
        '${request.reason != null && request.reason!.isNotEmpty ? ' · ${request.reason}' : ''}',
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

class _RequestLeaveDialog extends ConsumerStatefulWidget {
  const _RequestLeaveDialog();

  @override
  ConsumerState<_RequestLeaveDialog> createState() => _RequestLeaveDialogState();
}

class _RequestLeaveDialogState extends ConsumerState<_RequestLeaveDialog> {
  final _formKey = GlobalKey<FormState>();
  final _reason = TextEditingController();
  String? _typeId;
  DateTime _start = DateTime.now();
  DateTime _end = DateTime.now();
  bool _saving = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  /// Calendar days between the two dates. Working-day and half-day
  /// handling belongs with the leave policy, which lives in the database.
  double get _days => _end.difference(_start).inDays + 1;

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
                  onChanged: (v) => setState(() => _typeId = v),
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
                    }),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: _DateField(
                    label: 'Last day',
                    value: _end,
                    onChanged: (d) => setState(() => _end = d),
                  ),
                ),
              ]),
              const SizedBox(height: Space.sm),
              Text('${Fmt.days(_days)} day(s)',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: Space.md),
              TextFormField(
                controller: _reason,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'Reason'),
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
