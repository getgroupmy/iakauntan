import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import '../contacts/new_contact_dialog.dart';
import 'stall_items_dialog.dart';

/// What a stall's row says under its name.
///
/// Pure and exported so the list and the tests agree. The item count is
/// the thing a court manager is actually checking — a stall with no
/// dishes on it will settle at zero and nobody will know why.
String stallSummary(Map<String, dynamic> row) {
  final n = row['item_count'] as int? ?? 0;
  final pct = num.tryParse('${row['commission_percent'] ?? 0}') ?? 0;
  return '${row['operator']} · ${trimPercent(pct)}% commission · '
      '${n == 0 ? 'nothing on the menu yet' : '$n dish${n == 1 ? '' : 'es'}'}';
}

/// A percentage without the trailing zeros a numeric column carries.
String trimPercent(num value) {
  final s = value.toStringAsFixed(4);
  if (!s.contains('.')) return s;
  return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

/// What the settlement line reads as before anybody presses anything.
///
/// Split out so the confirmation and the test say the same number: this
/// is the sentence somebody reads before money moves.
String settlementLine(Map<String, dynamic> row) {
  final gross = num.tryParse('${row['gross'] ?? 0}') ?? 0;
  final commission = num.tryParse('${row['commission'] ?? 0}') ?? 0;
  final net = num.tryParse('${row['net'] ?? 0}') ?? 0;
  return '${Fmt.money(gross)} sold · ${Fmt.money(commission)} kept · '
      '${Fmt.money(net)} owed';
}

/// Whether a settlement run can be attempted at all.
///
/// The server refuses a period that is not over and one whose days have
/// been paid for; this is only so the button is not live when the
/// answer is already known.
bool canSettle(List<Map<String, dynamic>> takings, DateTime to, DateTime now) {
  if (!to.isBefore(DateTime(now.year, now.month, now.day))) return false;
  final selling = takings.where(
    (t) => (num.tryParse('${t['gross'] ?? 0}') ?? 0) > 0,
  );
  if (selling.isEmpty) return false;
  return !selling.any((t) => t['settled'] == true);
}

/// The stalls in a food court, what they sold, and paying them.
class StallsScreen extends ConsumerStatefulWidget {
  const StallsScreen({super.key});

  @override
  ConsumerState<StallsScreen> createState() => _StallsScreenState();
}

class _StallsScreenState extends ConsumerState<StallsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  String? _outlet;

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final outlets = ref.watch(posOutletsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Stalls'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [Tab(text: 'The stalls'), Tab(text: 'Settling')],
        ),
      ),
      body: AsyncView(
        value: outlets,
        builder: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.storefront_outlined,
              title: 'No outlet yet',
              message: 'A food court is an outlet with stalls inside it.',
            );
          }
          final outlet = _outlet ?? list.first['id'] as String;
          return Column(
            children: [
              if (list.length > 1)
                Padding(
                  padding: const EdgeInsets.all(Space.md),
                  child: DropdownButtonFormField<String>(
                    value: outlet,
                    decoration: const InputDecoration(labelText: 'Court'),
                    items: [
                      for (final o in list)
                        DropdownMenuItem(
                          value: o['id'] as String,
                          child: Text('${o['name']}'),
                        ),
                    ],
                    onChanged: (v) => setState(() => _outlet = v),
                  ),
                ),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    _StallList(outletId: outlet),
                    _SettleTab(outletId: outlet),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StallList extends ConsumerStatefulWidget {
  const _StallList({required this.outletId});

  final String outletId;

  @override
  ConsumerState<_StallList> createState() => _StallListState();
}

class _StallListState extends ConsumerState<_StallList> {
  void _reload() => ref.invalidate(posStallsProvider(widget.outletId));

  Future<void> _edit(Map<String, dynamic>? existing) async {
    // Suppliers: a stall operator is somebody the court owes money to,
    // and the settlement raises a bill against them.
    final contacts = await ref.read(
      contactsProvider((type: 'supplier', search: '')).future,
    );
    if (!mounted) return;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _StallSheet(
        outletId: widget.outletId,
        stall: existing,
        contacts: contacts,
      ),
    );
    if (saved == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final stalls = ref.watch(posStallsProvider(widget.outletId));
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
        icon: const Icon(Icons.storefront_outlined),
        label: const Text('Stall'),
      ),
      body: AsyncView(
        value: stalls,
        onRetry: _reload,
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.storefront_outlined,
              title: 'One room, one counter, one business',
              message:
                  'Add a stall for each operator and the till can take one '
                  'payment for food from all of them, then hand each one '
                  'its takings less the court’s cut.',
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final row = rows[i];
              return ListTile(
                leading: CircleAvatar(child: Text('${row['code']}')),
                title: Text('${row['name']}'),
                subtitle: Text(stallSummary(row)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (row['is_active'] != true)
                      const Chip(
                        label: Text('Closed'),
                        visualDensity: VisualDensity.compact,
                      ),
                    // Which dishes are this stall's. Nothing could say
                    // so until now, and a stall that owns no dish
                    // settles for nothing however much the court takes.
                    TextButton(
                      key: ValueKey('stall-items-${row['id']}'),
                      onPressed: () async {
                        if (await showStallItems(
                          context,
                          stall: row,
                          stalls: rows,
                        )) {
                          _reload();
                        }
                      },
                      child: const Text('Dishes'),
                    ),
                  ],
                ),
                onTap: () => _edit(row),
              );
            },
          );
        },
      ),
    );
  }
}

class _StallSheet extends ConsumerStatefulWidget {
  const _StallSheet({
    required this.outletId,
    required this.stall,
    required this.contacts,
  });

  final String outletId;
  final Map<String, dynamic>? stall;
  final List<Contact> contacts;

  @override
  ConsumerState<_StallSheet> createState() => _StallSheetState();
}

class _StallSheetState extends ConsumerState<_StallSheet> {
  late final _code = TextEditingController(
    text: '${widget.stall?['code'] ?? ''}',
  );
  late final _name = TextEditingController(
    text: '${widget.stall?['name'] ?? ''}',
  );
  late final _commission = TextEditingController(
    text: '${widget.stall?['commission_percent'] ?? 0}',
  );
  late String? _operator = widget.stall?['operator_contact_id'] as String?;
  late bool _active = widget.stall?['is_active'] != false;

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _commission.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final op = _operator;
    if (op == null) return;
    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .savePosStall(
            id: widget.stall?['id'] as String?,
            outletId: widget.outletId,
            code: _code.text.trim(),
            name: _name.text.trim(),
            operatorContactId: op,
            commission: num.tryParse(_commission.text.trim()) ?? 0,
            active: _active,
          ),
      successMessage: 'Saved.',
    );
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(Space.lg),
          children: [
            Text(
              widget.stall == null ? 'A stall' : '${widget.stall!['name']}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _code,
              decoration: const InputDecoration(
                labelText: 'Number',
                helperText: 'What is painted above it. A1, B2.',
              ),
            ),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Called'),
            ),
            const SizedBox(height: Space.md),
            SearchablePicker<String>(
              options: contactPickerOptions(widget.contacts),
              value: _operator,
              label: 'Whose business it is',
              helperText:
                  'The contact the settlement bill is raised against.',
              hint: 'Type a name or a code',
              createLabel: 'Add operator',
              onCreate: (typed) => createContactFromPicker(
                context,
                contactType: 'supplier',
                typed: typed,
              ),
              onChanged: (v) => setState(() => _operator = v),
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _commission,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Commission %',
                helperText: 'What the court keeps out of this stall’s takings.',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _active,
              title: const Text('Open'),
              onChanged: (v) => setState(() => _active = v),
            ),
            const SizedBox(height: Space.lg),
            FilledButton(
              onPressed:
                  _operator == null ||
                      _code.text.trim().isEmpty ||
                      _name.text.trim().isEmpty
                  ? null
                  : _save,
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettleTab extends ConsumerStatefulWidget {
  const _SettleTab({required this.outletId});

  final String outletId;

  @override
  ConsumerState<_SettleTab> createState() => _SettleTabState();
}

class _SettleTabState extends ConsumerState<_SettleTab> {
  late DateTime _to = DateTime.now().subtract(const Duration(days: 1));
  late DateTime _from = DateTime.now().subtract(const Duration(days: 7));
  List<Map<String, dynamic>>? _takings;
  bool _loading = false;

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rows = await ref
          .read(repoProvider)!
          .posStallTakings(widget.outletId, _from, _to);
      if (mounted) setState(() => _takings = rows);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _settle() async {
    final rows = _takings ?? const [];
    final owed = rows.where(
      (r) => (num.tryParse('${r['net'] ?? 0}') ?? 0) > 0,
    );
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pay the stalls?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'One bill per stall, posted against its operator. These days '
              'cannot be settled again afterwards.',
            ),
            const SizedBox(height: Space.md),
            for (final r in owed)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('${r['stall_name']} — ${settlementLine(r)}'),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Pay them'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final ok = await runWithFeedback(
      context,
      action: () async {
        await ref
            .read(repoProvider)!
            .settlePosStalls(widget.outletId, _from, _to);
      },
      successMessage: 'Settled. The bills are posted and waiting to be paid.',
    );
    if (ok) {
      ref.invalidate(posStallSettlementsProvider(widget.outletId));
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _takings;
    final settled = ref.watch(posStallSettlementsProvider(widget.outletId));

    return ListView(
      padding: const EdgeInsets.all(Space.md),
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _from,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) setState(() => _from = picked);
                },
                child: Text('From ${Fmt.date(_from)}'),
              ),
            ),
            const SizedBox(width: Space.sm),
            Expanded(
              child: OutlinedButton(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _to,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) setState(() => _to = picked);
                },
                child: Text('To ${Fmt.date(_to)}'),
              ),
            ),
            const SizedBox(width: Space.sm),
            FilledButton.tonal(
              onPressed: _loading ? null : _load,
              child: const Text('Look'),
            ),
          ],
        ),
        const SizedBox(height: Space.md),
        if (rows != null) ...[
          for (final r in rows)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('${r['stall_name']}'),
              subtitle: Text(settlementLine(r)),
              trailing: r['settled'] == true
                  ? Chip(
                      label: const Text('Paid'),
                      visualDensity: VisualDensity.compact,
                      backgroundColor: context.colors.success.withValues(
                        alpha: 0.15,
                      ),
                    )
                  : null,
            ),
          const SizedBox(height: Space.md),
          FilledButton(
            onPressed: canSettle(rows, _to, DateTime.now()) ? _settle : null,
            child: const Text('Pay the stalls'),
          ),
          const SizedBox(height: Space.lg),
        ],
        Text('Already paid', style: Theme.of(context).textTheme.titleSmall),
        AsyncView(
          value: settled,
          builder: (list) => Column(
            children: [
              if (list.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(Space.md),
                  child: Text('Nothing has been settled yet.'),
                ),
              for (final s in list)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('${s['stall_name']} · ${s['bill_no'] ?? ''}'),
                  subtitle: Text(
                    '${Fmt.date(DateTime.parse('${s['period_from']}'))} to '
                    '${Fmt.date(DateTime.parse('${s['period_to']}'))} · '
                    '${settlementLine(s)}',
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
