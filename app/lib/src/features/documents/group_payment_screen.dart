import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// One payment covering documents in more than one company.
///
/// Everything else in this app is about the company that is open. This
/// screen deliberately is not: a person who owns three companies and is
/// paid once had to open each of them in turn, split the figure by hand,
/// and hope the three receipts added back up to the money that arrived.
///
/// What comes out is still three ordinary receipts — each numbered by
/// its own company, in its own ledger, against its own bank — tied
/// together by a batch that holds no money. `0462` has the reasoning.
class GroupPaymentScreen extends ConsumerStatefulWidget {
  const GroupPaymentScreen({super.key});

  @override
  ConsumerState<GroupPaymentScreen> createState() => _GroupPaymentState();
}

class _GroupPaymentState extends ConsumerState<GroupPaymentScreen> {
  bool _isSales = true;
  DateTime _paidOn = DateTime.now();
  final _reference = TextEditingController();
  final _note = TextEditingController();

  /// Document id -> what is being put against it. A controller per row
  /// so an amount the operator has edited survives a rebuild.
  final _amounts = <String, TextEditingController>{};
  final _selected = <String>{};
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _reference.dispose();
    _note.dispose();
    for (final c in _amounts.values) {
      c.dispose();
    }
    super.dispose();
  }

  String get _kind => _isSales ? 'invoice' : 'bill';

  double get _total {
    var sum = 0.0;
    for (final id in _selected) {
      sum += double.tryParse(_amounts[id]?.text ?? '') ?? 0;
    }
    return sum;
  }

  /// The companies with something selected. Shown because it is the
  /// answer to the question the operator actually has: how many sets of
  /// books is this one payment about to touch?
  int _companiesTouched(List<Map<String, dynamic>> rows) {
    return rows
        .where((r) => _selected.contains('${r['doc_id']}'))
        .map((r) => '${r['org_id']}')
        .toSet()
        .length;
  }

  Future<void> _record(List<Map<String, dynamic>> rows) async {
    final repo = ref.read(repoProvider);
    if (repo == null || _selected.isEmpty) return;

    final lines =
        <
          ({
            String documentId,
            bool isSales,
            double amount,
            double discount,
            String? bankAccountId,
            String? paymentModeCode,
          })
        >[];
    for (final r in rows) {
      final id = '${r['doc_id']}';
      if (!_selected.contains(id)) continue;
      final amount = double.tryParse(_amounts[id]?.text ?? '') ?? 0;
      if (amount <= 0) continue;
      lines.add((
        documentId: id,
        isSales: _isSales,
        amount: amount,
        discount: 0,
        bankAccountId: null,
        paymentModeCode: null,
      ));
    }
    if (lines.isEmpty) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await repo.recordGroupPayment(
        paidOn: _paidOn,
        reference: _reference.text.trim().isEmpty
            ? null
            : _reference.text.trim(),
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
        lines: lines,
      );
      if (!mounted) return;
      setState(() {
        _selected.clear();
        _reference.clear();
        _note.clear();
      });
      ref.invalidate(openAcrossCompaniesProvider(_kind));
      ref.invalidate(settlementsProvider(_isSales));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${lines.length} document${lines.length == 1 ? '' : 's'} settled '
            'across ${_companiesTouched(rows)} '
            'compan${_companiesTouched(rows) == 1 ? 'y' : 'ies'}.',
          ),
        ),
      );
    } catch (e) {
      // The server refuses the whole payment or none of it, and its
      // refusals name the company and the document. Showing the message
      // rather than "could not save" is the difference between fixing
      // one line and starting again.
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final open = ref.watch(openAcrossCompaniesProvider(_kind));

    return Scaffold(
      appBar: AppBar(title: const Text('One payment, several companies')),
      body: AsyncView(
        value: open,
        onRetry: () => ref.invalidate(openAcrossCompaniesProvider(_kind)),
        skeleton: const ListSkeleton(rows: 6, leading: false),
        builder: (rows) {
          // Grouped by company, in the order the server sent them,
          // which is by company name.
          final byOrg = <String, List<Map<String, dynamic>>>{};
          for (final r in rows) {
            byOrg.putIfAbsent('${r['org_name']}', () => []).add(r);
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(Space.lg),
                child: _Header(
                  isSales: _isSales,
                  onKindChanged: (v) => setState(() {
                    _isSales = v;
                    _selected.clear();
                  }),
                  paidOn: _paidOn,
                  onDate: (d) => setState(() => _paidOn = d),
                  reference: _reference,
                  note: _note,
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Space.lg,
                    0,
                    Space.lg,
                    Space.md,
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(Space.md),
                    decoration: BoxDecoration(
                      color: context.colors.danger.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _error!,
                      style: TextStyle(color: context.colors.danger),
                    ),
                  ),
                ),
              Expanded(
                child: rows.isEmpty
                    ? _NothingOpen(isSales: _isSales)
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(
                          Space.lg,
                          0,
                          Space.lg,
                          Space.lg,
                        ),
                        children: [
                          for (final entry in byOrg.entries)
                            _CompanyCard(
                              name: entry.key,
                              rows: entry.value,
                              selected: _selected,
                              amounts: _amounts,
                              onChanged: () => setState(() {}),
                            ),
                          const SizedBox(height: Space.md),
                          const _AddCompanyRow(),
                        ],
                      ),
              ),
              _Footer(
                total: _total,
                companies: _companiesTouched(rows),
                busy: _busy,
                onRecord: _selected.isEmpty || _busy
                    ? null
                    : () => _record(rows),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.isSales,
    required this.onKindChanged,
    required this.paidOn,
    required this.onDate,
    required this.reference,
    required this.note,
  });

  final bool isSales;
  final ValueChanged<bool> onKindChanged;
  final DateTime paidOn;
  final ValueChanged<DateTime> onDate;
  final TextEditingController reference;
  final TextEditingController note;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
              value: true,
              label: Text('Money in'),
              icon: Icon(Icons.south_west, size: 16),
            ),
            ButtonSegment(
              value: false,
              label: Text('Money out'),
              icon: Icon(Icons.north_east, size: 16),
            ),
          ],
          selected: {isSales},
          onSelectionChanged: (s) => onKindChanged(s.first),
        ),
        const SizedBox(height: Space.md),
        Wrap(
          spacing: Space.md,
          runSpacing: Space.md,
          children: [
            SizedBox(
              width: 180,
              child: InkWell(
                onTap: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: paidOn,
                    firstDate: DateTime(paidOn.year - 3),
                    lastDate: DateTime(paidOn.year + 1),
                  );
                  if (d != null) onDate(d);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Paid on',
                    border: OutlineInputBorder(),
                  ),
                  child: Text(Fmt.date(paidOn)),
                ),
              ),
            ),
            SizedBox(
              width: 220,
              child: TextField(
                controller: reference,
                decoration: const InputDecoration(
                  labelText: 'Bank reference',
                  hintText: 'TT-8891, cheque no',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            SizedBox(
              width: 260,
              child: TextField(
                controller: note,
                decoration: const InputDecoration(
                  labelText: 'Note',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _CompanyCard extends StatelessWidget {
  const _CompanyCard({
    required this.name,
    required this.rows,
    required this.selected,
    required this.amounts,
    required this.onChanged,
  });

  final String name;
  final List<Map<String, dynamic>> rows;
  final Set<String> selected;
  final Map<String, TextEditingController> amounts;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: Space.md),
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(name, style: t.textTheme.titleMedium),
            const SizedBox(height: Space.sm),
            for (final r in rows)
              _DocumentRow(
                row: r,
                selected: selected,
                amounts: amounts,
                onChanged: onChanged,
              ),
          ],
        ),
      ),
    );
  }
}

class _DocumentRow extends StatelessWidget {
  const _DocumentRow({
    required this.row,
    required this.selected,
    required this.amounts,
    required this.onChanged,
  });

  final Map<String, dynamic> row;
  final Set<String> selected;
  final Map<String, TextEditingController> amounts;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final id = '${row['doc_id']}';
    final balance = (row['balance_amount'] as num?)?.toDouble() ?? 0;
    final isOn = selected.contains(id);
    final controller = amounts.putIfAbsent(
      id,
      // Defaulted to the whole balance, because settling in full is
      // what most of these are. A part payment is a figure typed over
      // it rather than one typed from nothing.
      () => TextEditingController(text: balance.toStringAsFixed(2)),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Checkbox(
            value: isOn,
            onChanged: (v) {
              if (v ?? false) {
                selected.add(id);
              } else {
                selected.remove(id);
              }
              onChanged();
            },
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${row['doc_no']}  ·  ${row['contact_name'] ?? ''}'),
                Text(
                  'Owing ${Fmt.money(balance, currency: '${row['currency'] ?? 'MYR'}')}'
                  '${row['due_date'] == null ? '' : '  ·  due '
                        '${Fmt.date(DateTime.parse('${row['due_date']}'))}'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          SizedBox(
            width: 120,
            child: TextField(
              controller: controller,
              enabled: isOn,
              textAlign: TextAlign.right,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => onChanged(),
            ),
          ),
        ],
      ),
    );
  }
}

/// The company that is not on the list.
///
/// Every company here is one this person may post in. A company they
/// have never set up is not missing from a filter — it does not exist
/// yet, and the honest answer is the form that creates one.
class _AddCompanyRow extends ConsumerWidget {
  const _AddCompanyRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'Company not listed?',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(width: Space.sm),
        // Offered only when it would work. Adding a company is the
        // Multi-Company module (0486), and a button that refuses is
        // worse than no button.
        if (ref.watch(canAddCompanyProvider).valueOrNull ?? false)
          TextButton.icon(
            onPressed: () => context.go('/companies/new'),
            icon: const Icon(Icons.add_business_outlined, size: 18),
            label: const Text('Add a company'),
          ),
      ],
    );
  }
}

class _NothingOpen extends StatelessWidget {
  const _NothingOpen({required this.isSales});

  final bool isSales;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        EmptyState(
          icon: Icons.done_all,
          title: isSales ? 'Nothing outstanding' : 'Nothing to pay',
          message: isSales
              ? 'No company you can post in has an unpaid invoice. Only '
                    'companies you may settle in are listed — reading an '
                    'invoice and being able to pay it are not the same '
                    'permission.'
              : 'No company you can post in has an unpaid bill.',
        ),
        const _AddCompanyRow(),
      ],
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.total,
    required this.companies,
    required this.busy,
    required this.onRecord,
  });

  final double total;
  final int companies;
  final bool busy;
  final VoidCallback? onRecord;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(Fmt.money(total), style: t.textTheme.titleLarge),
                Text(
                  companies == 0
                      ? 'Nothing selected'
                      : 'across $companies compan${companies == 1 ? 'y' : 'ies'}',
                  style: t.textTheme.bodySmall,
                ),
              ],
            ),
            const Spacer(),
            FilledButton.icon(
              key: const ValueKey('group-payment-record'),
              onPressed: onRecord,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.payments_outlined, size: 18),
              label: const Text('Record payment'),
            ),
          ],
        ),
      ),
    );
  }
}
