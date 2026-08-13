import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../shared/attachments_card.dart';

/// Money already spent, captured and posted in one step — there is no
/// useful draft state for an expense that has already left the bank.
class ExpensesScreen extends ConsumerWidget {
  const ExpensesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expenses = ref.watch(expensesProvider);
    final canPost = ref.watch(canPostProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Expenses'),
        actions: [
          if (canPost)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.icon(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const _ExpenseDialog(),
                ),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Record expense'),
              ),
            ),
        ],
      ),
      body: AsyncView(
        value: expenses,
        onRetry: () => ref.invalidate(expensesProvider),
        builder: (list) {
          if (list.isEmpty) {
            return EmptyState(
              icon: Icons.receipt_outlined,
              title: 'No expenses recorded',
              message: 'Capture rent, utilities and other running costs here.',
              action: canPost
                  ? FilledButton.icon(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => const _ExpenseDialog(),
                      ),
                      icon: const Icon(Icons.add),
                      label: const Text('Record expense'),
                    )
                  : null,
            );
          }

          final total = list.fold<double>(
              0, (sum, e) => sum + Fmt.toDouble(e['total_amount']));

          return Column(
            children: [
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
                color: Theme.of(context)
                    .colorScheme
                    .primaryContainer
                    .withValues(alpha: 0.35),
                child: Text(
                  '${list.length} expenses · ${Fmt.money(total)}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final e = list[i];
                    final account = e['accounts'] as Map?;
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 4),
                      title: Row(children: [
                        Flexible(
                          child: Text(
                            e['description']?.toString() ??
                                e['expense_no']?.toString() ??
                                '—',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                        ),
                        const SizedBox(width: 10),
                        StatusChip(e['status']?.toString() ?? 'draft',
                            compact: true),
                      ]),
                      subtitle: Text(
                        [
                          e['expense_no'],
                          if (account != null)
                            '${account['code']} ${account['name']}',
                          Fmt.date(Fmt.parseDate(e['expense_date'])),
                        ].where((v) => v != null).join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing:
                          Money(Fmt.toDouble(e['total_amount']), bold: true),
                      // Until now an expense could be created and never
                      // opened again, which is why its receipt had
                      // nowhere to live. An expense without the receipt
                      // behind it is the line an auditor asks about and
                      // nobody can answer.
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (_) => _ExpenseDetail(expense: e),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ExpenseDialog extends ConsumerStatefulWidget {
  const _ExpenseDialog();

  @override
  ConsumerState<_ExpenseDialog> createState() => _ExpenseDialogState();
}

class _ExpenseDialogState extends ConsumerState<_ExpenseDialog> {
  final _formKey = GlobalKey<FormState>();
  final _description = TextEditingController();
  final _amount = TextEditingController();
  final _reference = TextEditingController();

  String? _accountId;
  String? _bankAccountId;
  String? _taxCodeId;
  String _paymentMode = '03';
  DateTime _date = DateTime.now();
  bool _saving = false;

  @override
  void dispose() {
    _description.dispose();
    _amount.dispose();
    _reference.dispose();
    super.dispose();
  }

  double get _net => double.tryParse(_amount.text) ?? 0;

  double get _tax {
    final codes = ref.read(taxCodesProvider).value ?? const <TaxCode>[];
    final rate =
        codes.where((t) => t.id == _taxCodeId).firstOrNull?.rate ?? 0;
    return ((_net * rate / 100) * 100).roundToDouble() / 100;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_accountId == null) return;

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.recordExpense(
            accountId: _accountId!,
            amount: _net,
            date: _date,
            description: _description.text.trim().isEmpty
                ? null
                : _description.text.trim(),
            bankAccountId: _bankAccountId,
            paymentModeCode: _paymentMode,
            taxCodeId: _taxCodeId,
            taxAmount: _tax,
            reference: _reference.text.trim().isEmpty
                ? null
                : _reference.text.trim(),
          ),
      successMessage: 'Expense recorded and posted',
      pendingMessage: 'Posting…',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      refreshLedgerData(ref);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Only expense accounts are sensible here.
    final accounts = (ref.watch(accountsProvider).value ?? const <Account>[])
        .where((a) => a.accountType == 'expense' && !a.isGroup)
        .toList();
    final banks = ref.watch(bankAccountsProvider).value ?? const [];
    final taxCodes = ref.watch(taxCodesProvider).value ?? const <TaxCode>[];
    final modes = ref.watch(paymentModesProvider).value ?? const [];

    return AlertDialog(
      title: const Text('Record expense'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  value: _accountId,
                  isExpanded: true,
                  decoration:
                      const InputDecoration(labelText: 'Expense account *'),
                  items: [
                    for (final a in accounts)
                      DropdownMenuItem(
                        value: a.id,
                        child: Text('${a.code} — ${a.name}',
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => _accountId = v),
                  validator: (v) => v == null ? 'Choose an account' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _description,
                  decoration: const InputDecoration(labelText: 'Description'),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      controller: _amount,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                          labelText: 'Amount *', prefixText: 'RM '),
                      validator: (v) => (double.tryParse(v ?? '') ?? 0) <= 0
                          ? 'Enter an amount'
                          : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _taxCodeId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Tax'),
                      items: [
                        for (final t in taxCodes)
                          DropdownMenuItem(
                            value: t.id,
                            child: Text(
                              t.rate == 0
                                  ? t.code
                                  : '${t.code} (${Fmt.percent(t.rate)})',
                            ),
                          ),
                      ],
                      onChanged: (v) => setState(() => _taxCodeId = v),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: InkWell(
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _date,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) setState(() => _date = picked);
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Date',
                          suffixIcon: Icon(Icons.calendar_today, size: 18),
                        ),
                        child: Text(Fmt.date(_date)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _paymentMode,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Paid by'),
                      items: [
                        for (final m in modes)
                          DropdownMenuItem(
                            value: m['code'] as String,
                            child: Text(m['description'] as String,
                                overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: (v) =>
                          setState(() => _paymentMode = v ?? '03'),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _bankAccountId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Paid from',
                    helperText: 'Leave blank to use the default bank account',
                  ),
                  items: [
                    for (final b in banks)
                      DropdownMenuItem(
                        value: b['id'] as String,
                        child: Text(b['name'] as String,
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => _bankAccountId = v),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _reference,
                  decoration: const InputDecoration(labelText: 'Reference'),
                ),
                if (_tax > 0) ...[
                  const SizedBox(height: 16),
                  Row(children: [
                    const Expanded(child: Text('Total including tax')),
                    Money(_net + _tax, bold: true),
                  ]),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Record and post'),
        ),
      ],
    );
  }
}

/// An expense after it has been recorded, and the receipt behind it.
///
/// Read-only on purpose. A posted expense has a journal entry against
/// it, and letting the amount be edited here would put the two out of
/// step silently — correcting one means reversing it, which is a
/// different verb and a different screen. What was missing was not
/// editing but *evidence*: the paper the expense came from, which an
/// auditor asks for and which had nowhere to be filed.
class _ExpenseDetail extends ConsumerWidget {
  const _ExpenseDetail({required this.expense});

  final Map<String, dynamic> expense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = expense['accounts'] as Map?;
    final no = expense['expense_no']?.toString() ?? 'Expense';

    Widget line(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 110,
              child: Text(label,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
            Expanded(child: Text(value)),
          ]),
        );

    return AlertDialog(
      title: Row(children: [
        Expanded(child: Text(no)),
        StatusChip(expense['status']?.toString() ?? 'draft', compact: true),
      ]),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              line('Description', expense['description']?.toString() ?? '—'),
              line('Date', Fmt.date(Fmt.parseDate(expense['expense_date']))),
              if (account != null)
                line('Account', '${account['code']} ${account['name']}'),
              if (expense['reference'] != null &&
                  '${expense['reference']}'.trim().isNotEmpty)
                line('Reference', '${expense['reference']}'),
              line('Amount', Fmt.money(Fmt.toDouble(expense['total_amount']))),
              const SizedBox(height: Space.md),
              AttachmentsCard(
                table: 'expenses',
                recordId: '${expense['id']}',
                title: 'Receipt',
                subtitle: 'The paper this expense came from.',
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
