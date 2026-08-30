import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import 'provider_roster.dart';

/// Who does the work at one outlet, and the week each of them keeps.
Future<void> showProviderRoster(BuildContext context, String outletId) =>
    showDialog<void>(
      context: context,
      builder: (_) => _RosterDialog(outletId: outletId),
    );

class _RosterDialog extends ConsumerWidget {
  const _RosterDialog({required this.outletId});

  final String outletId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final people = ref.watch(posServiceProvidersProvider(outletId));

    return AlertDialog(
      title: const Text('Who does the work'),
      content: SizedBox(
        width: 520,
        height: 440,
        child: AsyncView<List<Map<String, dynamic>>>(
          value: people,
          onRetry: () => ref.invalidate(posServiceProvidersProvider(outletId)),
          builder: (rows) {
            if (rows.isEmpty) {
              return const EmptyState(
                icon: Icons.person_outline,
                title: 'Nobody yet',
                message: 'A booking is an hour of somebody’s time. Add the '
                    'people whose hours are being sold, and say when they '
                    'work — a provider whose week is empty is open at no '
                    'time, and every booking made for them is refused.',
              );
            }
            return ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) => _PersonTile(
                outletId: outletId,
                person: rows[i],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          key: const ValueKey('roster-add'),
          onPressed: () async {
            final saved = await showDialog<bool>(
              context: context,
              builder: (_) => _PersonSheet(outletId: outletId),
            );
            if (saved == true) {
              ref.invalidate(posServiceProvidersProvider(outletId));
            }
          },
          icon: const Icon(Icons.person_add_alt),
          label: const Text('Somebody'),
        ),
      ],
    );
  }
}

class _PersonTile extends ConsumerWidget {
  const _PersonTile({required this.outletId, required this.person});

  final String outletId;
  final Map<String, dynamic> person;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = person['id'] as String;
    final hours = ref.watch(posProviderHoursProvider(id));
    final rows = hours.valueOrNull ?? const <Map<String, dynamic>>[];
    final bookable = providerCanBeBooked(rows);
    final small = Theme.of(context).textTheme.bodySmall;

    return ListTile(
      title: Text('${person['name']}'),
      subtitle: Text(
        hours.isLoading ? '…' : rosterSummary(rows),
        style: bookable
            ? small
            : small?.copyWith(color: context.colors.warning),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.schedule_outlined),
            tooltip: 'The week they work',
            onPressed: () async {
              final saved = await showDialog<bool>(
                context: context,
                builder: (_) => _WeekSheet(providerId: id, rows: rows),
              );
              if (saved == true) {
                ref.invalidate(posProviderHoursProvider(id));
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.event_busy_outlined),
            tooltip: 'When they are away',
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => _TimeOffSheet(providerId: id),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              final saved = await showDialog<bool>(
                context: context,
                builder: (_) =>
                    _PersonSheet(outletId: outletId, person: person),
              );
              if (saved == true) {
                ref.invalidate(posServiceProvidersProvider(outletId));
              }
            },
          ),
        ],
      ),
    );
  }
}

class _PersonSheet extends ConsumerStatefulWidget {
  const _PersonSheet({required this.outletId, this.person});

  final String outletId;
  final Map<String, dynamic>? person;

  @override
  ConsumerState<_PersonSheet> createState() => _PersonSheetState();
}

class _PersonSheetState extends ConsumerState<_PersonSheet> {
  late final _code = TextEditingController(
    text: '${widget.person?['code'] ?? ''}',
  );
  late final _name = TextEditingController(
    text: '${widget.person?['name'] ?? ''}',
  );
  late String? _employeeId = widget.person?['employee_id'] as String?;
  late bool _active = widget.person?['is_active'] != false;
  bool _saving = false;

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Saved',
      action: () => ref.read(repoProvider)!.savePosServiceProvider(
        id: widget.person?['id'] as String?,
        outletId: widget.outletId,
        code: _code.text.trim(),
        name: _name.text.trim(),
        employeeId: _employeeId,
        isActive: _active,
      ),
    );
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final staff = ref.watch(employeesProvider('active')).valueOrNull ?? const [];

    return AlertDialog(
      title: Text(widget.person == null ? 'Somebody new' : 'Their details'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('provider-name'),
                controller: _name,
                enabled: !_saving,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              TextField(
                controller: _code,
                enabled: !_saving,
                decoration: const InputDecoration(
                  labelText: 'Code',
                  helperText: 'Short, and unique in this shop.',
                ),
              ),
              const SizedBox(height: Space.md),
              DropdownButtonFormField<String?>(
                value: _employeeId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'On the payroll as',
                  helperText: 'Optional. A chair may be rented by somebody '
                      'who is not an employee at all.',
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Nobody in particular'),
                  ),
                  for (final e in staff)
                    DropdownMenuItem<String?>(
                      value: e.id,
                      child: Text(e.fullName, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged:
                    _saving ? null : (v) => setState(() => _employeeId = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _active,
                title: const Text('Taking bookings'),
                subtitle: const Text(
                  'Switched off, the diary refuses new bookings by name and '
                  'the ones already written stay where they are.',
                ),
                onChanged:
                    _saving ? null : (v) => setState(() => _active = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('provider-save'),
          onPressed: _saving ||
                  _name.text.trim().isEmpty ||
                  _code.text.trim().isEmpty
              ? null
              : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// The week, edited whole.
class _WeekSheet extends ConsumerStatefulWidget {
  const _WeekSheet({required this.providerId, required this.rows});

  final String providerId;
  final List<Map<String, dynamic>> rows;

  @override
  ConsumerState<_WeekSheet> createState() => _WeekSheetState();
}

class _WeekSheetState extends ConsumerState<_WeekSheet> {
  late final Map<int, ({TimeOfDay? start, TimeOfDay? end})> _week =
      Map.of(weekFromRows(widget.rows));
  bool _saving = false;

  Future<void> _pick(int day, {required bool start}) async {
    final block = _week[day];
    final picked = await showTimePicker(
      context: context,
      initialTime: (start ? block?.start : block?.end) ??
          TimeOfDay(hour: start ? 9 : 18, minute: 0),
    );
    if (picked == null) return;
    setState(() {
      _week[day] = start
          ? (start: picked, end: block?.end)
          : (start: block?.start, end: picked);
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Saved',
      doing: "Change a provider's working hours",
      action: () => ref
          .read(repoProvider)!
          .setPosProviderHours(widget.providerId, weekRows(_week)),
    );
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final blocked = weekBlockedBecause(_week);
    final rows = weekRows(_week);
    final small = Theme.of(context).textTheme.bodySmall;

    return AlertDialog(
      title: const Text('The week they work'),
      content: SizedBox(
        width: 460,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'A day left blank is a day not worked. A week left empty is '
              'somebody who cannot be booked at all — the diary refuses '
              'every hour of it.',
              style: small,
            ),
            const SizedBox(height: Space.sm),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                children: [
                  for (final day in kIsoWeek)
                    ListTile(
                      dense: true,
                      title: Text(weekdayName(day)),
                      subtitle: Text(
                        switch (_week[day]) {
                          null => 'Not worked',
                          final b when b.start != null && b.end != null =>
                            hoursLine(b.start!, b.end!),
                          _ => 'Half filled in',
                        },
                        style: small,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: _saving
                                ? null
                                : () => _pick(day, start: true),
                            child: Text(
                              _week[day]?.start == null
                                  ? 'From'
                                  : wireTime(_week[day]!.start!)
                                      .substring(0, 5),
                            ),
                          ),
                          TextButton(
                            onPressed: _saving
                                ? null
                                : () => _pick(day, start: false),
                            child: Text(
                              _week[day]?.end == null
                                  ? 'To'
                                  : wireTime(_week[day]!.end!).substring(0, 5),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            tooltip: 'Not worked',
                            onPressed: _saving
                                ? null
                                : () => setState(() => _week.remove(day)),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (blocked != null)
              Text(
                blocked,
                style: small?.copyWith(color: context.colors.danger),
              )
            else if (rows.isEmpty)
              Text(
                'Nobody can be booked with them until a day is filled in.',
                style: small?.copyWith(color: context.colors.warning),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('week-save'),
          onPressed: _saving || blocked != null ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _TimeOffSheet extends ConsumerStatefulWidget {
  const _TimeOffSheet({required this.providerId});

  final String providerId;

  @override
  ConsumerState<_TimeOffSheet> createState() => _TimeOffSheetState();
}

class _TimeOffSheetState extends ConsumerState<_TimeOffSheet> {
  DateTime? _from;
  DateTime? _to;
  final _reason = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _pick({required bool from}) async {
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: (from ? _from : _to) ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
    );
    if (day == null || !mounted) return;
    final at = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: from ? 0 : 23, minute: from ? 0 : 59),
    );
    if (at == null) return;
    final v = DateTime(day.year, day.month, day.day, at.hour, at.minute);
    setState(() => from ? _from = v : _to = v);
  }

  Future<void> _add() async {
    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Recorded',
      action: () => ref.read(repoProvider)!.addPosProviderTimeOff(
        providerId: widget.providerId,
        startsAt: _from!,
        endsAt: _to!,
        reason: _reason.text.trim().isEmpty ? null : _reason.text.trim(),
      ),
    );
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(posProviderTimeOffProvider(widget.providerId));
      setState(() {
        _from = null;
        _to = null;
        _reason.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final spells = ref.watch(posProviderTimeOffProvider(widget.providerId));
    final blocked = timeOffBlockedBecause(_from, _to);
    final small = Theme.of(context).textTheme.bodySmall;
    final now = DateTime.now();

    return AlertDialog(
      title: const Text('When they are away'),
      content: SizedBox(
        width: 480,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed: _saving ? null : () => _pick(from: true),
                    icon: const Icon(Icons.event_outlined, size: 18),
                    label: Text(
                      _from == null ? 'From' : Fmt.dateTime(_from),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                Expanded(
                  child: TextButton.icon(
                    onPressed: _saving ? null : () => _pick(from: false),
                    icon: const Icon(Icons.event_outlined, size: 18),
                    label: Text(
                      _to == null ? 'Until' : Fmt.dateTime(_to),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
            TextField(
              controller: _reason,
              enabled: !_saving,
              decoration: const InputDecoration(labelText: 'Why'),
            ),
            const SizedBox(height: Space.sm),
            Row(
              children: [
                Expanded(
                  child: blocked == null
                      ? const SizedBox.shrink()
                      : Text(
                          blocked,
                          style:
                              small?.copyWith(color: context.colors.danger),
                        ),
                ),
                FilledButton(
                  key: const ValueKey('time-off-add'),
                  onPressed: _saving || blocked != null ? null : _add,
                  child: const Text('Away then'),
                ),
              ],
            ),
            const Divider(height: Space.lg),
            Expanded(
              child: AsyncView<List<Map<String, dynamic>>>(
                value: spells,
                onRetry: () => ref.invalidate(
                  posProviderTimeOffProvider(widget.providerId),
                ),
                builder: (rows) {
                  if (rows.isEmpty) {
                    return Text('Never away.', style: small);
                  }
                  return ListView(
                    children: [
                      for (final r in rows)
                        ListTile(
                          dense: true,
                          title: Text(
                            '${Fmt.dateTime(Fmt.parseDate(r['starts_at']))} '
                            '— ${Fmt.dateTime(Fmt.parseDate(r['ends_at']))}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          subtitle: Text('${r['reason'] ?? ''}'),
                          // Past spells are kept: a booking refused in
                          // March was refused for a reason, and this
                          // row is the reason.
                          leading: Icon(
                            timeOffIsPast(
                              Fmt.parseDate(r['ends_at']) ?? now,
                              now,
                            )
                                ? Icons.history
                                : Icons.event_busy_outlined,
                            size: 18,
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18),
                            onPressed: () async {
                              final done = await runWithFeedback(
                                context,
                                successMessage: 'Removed',
                                action: () => ref
                                    .read(repoProvider)!
                                    .deletePosProviderTimeOff(
                                      r['id'] as String,
                                    ),
                              );
                              if (done) {
                                ref.invalidate(
                                  posProviderTimeOffProvider(
                                    widget.providerId,
                                  ),
                                );
                              }
                            },
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
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
