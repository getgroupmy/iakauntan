import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Who sells, and what they sold.
///
/// The two halves are on one screen deliberately. A list of names on its
/// own is a maintenance chore nobody does, and a commission report whose
/// names are stale is worse than none — the useful thing is to see the
/// figures next to the people and fix the list when it is obviously
/// wrong.
///
/// The commission column is a working paper. Nothing here is posted, no
/// liability is raised and nothing reaches payroll: whether commission
/// falls due on invoice, on payment or on margin is a policy decision,
/// and a figure accrued on a guess is worse than no figure at all.
class SalespeopleScreen extends ConsumerStatefulWidget {
  const SalespeopleScreen({super.key});

  @override
  ConsumerState<SalespeopleScreen> createState() => _SalespeopleScreenState();
}

class _SalespeopleScreenState extends ConsumerState<SalespeopleScreen> {
  late DateTime _from = DateTime(DateTime.now().year, 1, 1);
  late DateTime _to = DateTime.now();
  Future<List<Map<String, dynamic>>>? _report;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    ref.invalidate(salespeopleProvider);
    setState(() {
      _report = repo.salesByPerson(from: _from, to: _to);
    });
  }

  Future<void> _pick({required bool start}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: start ? _from : _to,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    if (start) {
      _from = picked;
    } else {
      _to = picked;
    }
    _reload();
  }

  Future<void> _edit([Map<String, dynamic>? existing]) async {
    final saved = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _PersonDialog(existing: existing),
    );
    if (saved == null || !mounted) return;

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.saveSalesperson(saved),
      successMessage: 'Saved',
      pendingMessage: 'Saving…',
    );
    if (ok) _reload();
  }

  Future<void> _remove(Map<String, dynamic> person) async {
    final go = await confirm(
      context,
      title: 'Remove ${person['name']}?',
      message: 'Documents they sold keep their figures and move to the '
          'unattributed line on the report. Nothing is deleted from the '
          'ledger.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!go || !mounted) return;

    final ok = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.deleteSalesperson(person['id'] as String),
      successMessage: 'Removed',
      pendingMessage: 'Removing…',
    );
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final canWrite = ref.watch(canWriteProvider);
    final base = ref.watch(currentOrgProvider).valueOrNull?.baseCurrency ?? 'MYR';
    final people = ref.watch(salespeopleProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Salespeople'),
        actions: [
          TextButton.icon(
            onPressed: () => _pick(start: true),
            icon: const Icon(Icons.event_outlined, size: 18),
            label: Text(Fmt.date(_from)),
          ),
          const Text('→'),
          TextButton(
            onPressed: () => _pick(start: false),
            child: Text(Fmt.date(_to)),
          ),
          const SizedBox(width: Space.sm),
        ],
      ),
      floatingActionButton: canWrite
          ? FloatingActionButton.extended(
              onPressed: () => _edit(),
              icon: const Icon(Icons.person_add_outlined),
              label: const Text('Add'),
            )
          : null,
      body: SingleChildScrollView(
        child: PageBody(
          maxWidth: 1000,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FutureBuilder<List<Map<String, dynamic>>>(
                future: _report,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(Space.xxl),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (snap.hasError) return Text('${snap.error}');
                  return _Report(rows: snap.data ?? const [], base: base);
                },
              ),
              const SizedBox(height: Space.lg),
              people.when(
                loading: () => const SizedBox.shrink(),
                error: (e, _) => Text('$e'),
                data: (rows) => Card(
                  child: Padding(
                    padding: const EdgeInsets.all(Space.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SectionHeader(
                          'The people',
                          subtitle: rows.isEmpty
                              ? 'Nobody yet. Until somebody is here the '
                                  'salesperson field stays off the invoice.'
                              : 'A salesperson does not need a login. Link '
                                  'one to an employee only if commission '
                                  'will eventually run through payroll.',
                        ),
                        for (final p in rows)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(p['name']?.toString() ?? ''),
                            subtitle: Text([
                              p['code'],
                              if (p['commission_rate'] != null)
                                '${Fmt.rate(Fmt.toDouble(p['commission_rate']))}%',
                              if (p['email'] != null) p['email'],
                            ].where((e) => e != null).join('  ·  ')),
                            trailing: !canWrite
                                ? null
                                : Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: const Icon(Icons.edit_outlined,
                                            size: 18),
                                        onPressed: () => _edit(p),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.delete_outline,
                                            size: 18),
                                        onPressed: () => _remove(p),
                                      ),
                                    ],
                                  ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: Space.xxl),
            ],
          ),
        ),
      ),
    );
  }
}

class _Report extends StatelessWidget {
  const _Report({required this.rows, required this.base});

  final List<Map<String, dynamic>> rows;
  final String base;

  @override
  Widget build(BuildContext context) {
    final net = rows.fold<double>(0, (a, r) => a + Fmt.toDouble(r['net_sales']));
    final unattributed = rows
        .where((r) => r['salesperson_id'] == null)
        .fold<double>(0, (a, r) => a + Fmt.toDouble(r['net_sales']));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              'Net sales',
              subtitle: unattributed > 0 && net > 0
                  ? '${Fmt.money(unattributed, currency: base)} of '
                      '${Fmt.money(net, currency: base)} was not attributed '
                      'to anybody.'
                  : 'Invoices less credit notes, posted documents only.',
            ),
            const SizedBox(height: Space.sm),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columnSpacing: 28,
                columns: const [
                  DataColumn(label: Text('Salesperson')),
                  DataColumn(label: Text('Invoiced'), numeric: true),
                  DataColumn(label: Text('Credited'), numeric: true),
                  DataColumn(label: Text('Net'), numeric: true),
                  DataColumn(label: Text('Docs'), numeric: true),
                  DataColumn(label: Text('Rate'), numeric: true),
                  DataColumn(label: Text('Commission'), numeric: true),
                ],
                rows: [
                  for (final r in rows)
                    DataRow(cells: [
                      DataCell(Text(
                        r['name']?.toString() ?? '',
                        style: TextStyle(
                          fontStyle: r['salesperson_id'] == null
                              ? FontStyle.italic
                              : FontStyle.normal,
                          color: r['is_active'] == false
                              ? Theme.of(context).disabledColor
                              : null,
                        ),
                      )),
                      DataCell(Text(Fmt.money(Fmt.toDouble(r['invoiced']),
                          currency: base))),
                      DataCell(Text(Fmt.money(Fmt.toDouble(r['credited']),
                          currency: base))),
                      DataCell(Text(
                        Fmt.money(Fmt.toDouble(r['net_sales']), currency: base),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      )),
                      DataCell(Text('${r['documents'] ?? 0}')),
                      DataCell(Text(r['commission_rate'] == null
                          ? '—'
                          : '${Fmt.rate(Fmt.toDouble(r['commission_rate']))}%')),
                      DataCell(Text(r['commission'] == null
                          ? '—'
                          : Fmt.money(Fmt.toDouble(r['commission']),
                              currency: base))),
                    ]),
                ],
              ),
            ),
            const SizedBox(height: Space.sm),
            Text(
              'Commission is worked out from the rate on file and is not '
              'posted anywhere. No journal is raised and nothing reaches '
              'payroll — when it falls due is a policy this does not decide.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _PersonDialog extends StatefulWidget {
  const _PersonDialog({this.existing});

  final Map<String, dynamic>? existing;

  @override
  State<_PersonDialog> createState() => _PersonDialogState();
}

class _PersonDialogState extends State<_PersonDialog> {
  late final _code = TextEditingController(
      text: widget.existing?['code']?.toString() ?? '');
  late final _name = TextEditingController(
      text: widget.existing?['name']?.toString() ?? '');
  late final _rate = TextEditingController(
      text: widget.existing?['commission_rate'] == null
          ? ''
          : Fmt.rate(Fmt.toDouble(widget.existing!['commission_rate'])));
  late final _email = TextEditingController(
      text: widget.existing?['email']?.toString() ?? '');
  late bool _active = widget.existing?['is_active'] as bool? ?? true;

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _rate.dispose();
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rate = _rate.text.trim().isEmpty
        ? null
        : double.tryParse(_rate.text.trim());
    final rateBad = _rate.text.trim().isNotEmpty &&
        (rate == null || rate < 0 || rate > 100);

    return AlertDialog(
      title: Text(widget.existing == null ? 'New salesperson' : 'Salesperson'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _code,
              decoration: const InputDecoration(
                  labelText: 'Code', border: OutlineInputBorder()),
            ),
            const SizedBox(height: Space.sm),
            TextField(
              controller: _name,
              autofocus: widget.existing == null,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                  labelText: 'Name', border: OutlineInputBorder()),
            ),
            const SizedBox(height: Space.sm),
            TextField(
              controller: _email,
              decoration: const InputDecoration(
                  labelText: 'Email', border: OutlineInputBorder()),
            ),
            const SizedBox(height: Space.sm),
            TextField(
              controller: _rate,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Commission rate',
                suffixText: '%',
                border: const OutlineInputBorder(),
                helperText: 'Optional. Nothing is posted from it.',
                errorText: rateBad ? 'Between 0 and 100' : null,
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _active,
              onChanged: (v) => setState(() => _active = v),
              title: const Text('Still selling'),
              subtitle: const Text(
                  'Off keeps their history and takes them off the invoice.'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _name.text.trim().isEmpty ||
                  _code.text.trim().isEmpty ||
                  rateBad
              ? null
              : () => Navigator.pop(context, {
                    if (widget.existing?['id'] != null)
                      'id': widget.existing!['id'],
                    'code': _code.text.trim(),
                    'name': _name.text.trim(),
                    'email': _email.text.trim().isEmpty
                        ? null
                        : _email.text.trim(),
                    'commission_rate': rate,
                    'is_active': _active,
                  }),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
