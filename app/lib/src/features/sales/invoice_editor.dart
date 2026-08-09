import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import 'line_editor.dart';
import 'sales_list_screen.dart';

/// Mutable working copy of a document line while it is being edited.
class LineDraft {
  LineDraft({
    this.itemId,
    this.description = '',
    this.quantity = 1,
    this.unitPrice = 0,
    this.discountPercent = 0,
    this.taxCodeId,
    this.taxRate = 0,
    this.uomCode,
    this.classificationCode,
    this.isTaxInclusive = false,
  });

  String? itemId;
  String description;
  double quantity;
  double unitPrice;
  double discountPercent;
  String? taxCodeId;
  double taxRate;
  String? uomCode;
  String? classificationCode;
  bool isTaxInclusive;

  ({double net, double tax, double total}) get totals => SalesLine.compute(
        quantity: quantity,
        unitPrice: unitPrice,
        discountPercent: discountPercent,
        discountAmount: 0,
        taxRate: taxRate,
        taxInclusive: isTaxInclusive,
      );

  Map<String, dynamic> toJson() => {
        'line_type': 'item',
        'item_id': itemId,
        'description': description,
        'quantity': quantity,
        'unit_price': unitPrice,
        'discount_percent': discountPercent,
        'tax_code_id': taxCodeId,
        'tax_rate': taxRate,
        'is_tax_inclusive': isTaxInclusive,
        'uom_code': uomCode,
        'classification_code': classificationCode,
      };

  factory LineDraft.fromLine(SalesLine l) => LineDraft(
        itemId: l.itemId,
        description: l.description,
        quantity: l.quantity,
        unitPrice: l.unitPrice,
        discountPercent: l.discountPercent,
        taxCodeId: l.taxCodeId,
        taxRate: l.taxRate,
        uomCode: l.uomCode,
        classificationCode: l.classificationCode,
        isTaxInclusive: l.isTaxInclusive,
      );
}

class InvoiceEditor extends ConsumerStatefulWidget {
  const InvoiceEditor({super.key, required this.docType, this.documentId});

  final String docType;
  final String? documentId;

  @override
  ConsumerState<InvoiceEditor> createState() => _InvoiceEditorState();
}

class _InvoiceEditorState extends ConsumerState<InvoiceEditor> {
  final _reference = TextEditingController();
  final _notes = TextEditingController();

  String? _contactId;
  String? _contactName;
  String _docNo = '';
  DateTime _docDate = DateTime.now();
  DateTime? _dueDate;
  String _currency = 'MYR';
  String _status = 'draft';
  String _einvoiceStatus = 'not_applicable';
  String? _glEntryId;
  double _paidAmount = 0;

  final List<LineDraft> _lines = [];
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;

  bool get _isNew => widget.documentId == null;
  bool get _isPosted => _glEntryId != null;
  bool get _isEinvoiceDoc =>
      const ['invoice', 'credit_note', 'debit_note'].contains(widget.docType);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reference.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    try {
      if (_isNew) {
        _docNo = await repo.nextDocumentNumber(widget.docType);
        _dueDate = DateTime.now().add(const Duration(days: 30));
        _lines.add(LineDraft());
      } else {
        final doc = await repo.salesDocument(widget.documentId!);
        _docNo = doc.docNo;
        _contactId = doc.contactId;
        _contactName = doc.contactName;
        _docDate = doc.docDate;
        _dueDate = doc.dueDate;
        _currency = doc.currency;
        _status = doc.status;
        _einvoiceStatus = doc.einvoiceStatus;
        _glEntryId = doc.glEntryId;
        _paidAmount = doc.paidAmount;
        _reference.text = doc.reference ?? '';
        _notes.text = doc.notes ?? '';
        _lines
          ..clear()
          ..addAll(doc.lines.map(LineDraft.fromLine));
        if (_lines.isEmpty) _lines.add(LineDraft());
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not load: $e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // Totals are recomputed locally for instant feedback; the database
  // recalculates authoritatively on save.
  double get _subtotal =>
      _lines.fold(0, (sum, l) => sum + l.totals.net);
  double get _taxTotal =>
      _lines.fold(0, (sum, l) => sum + l.totals.tax);
  double get _grandTotal {
    final raw = _subtotal + _taxTotal;
    final org = ref.read(currentOrgProvider).value;
    return switch (org?.roundingMethod) {
      'nearest_5cent' => (raw * 20).round() / 20,
      'nearest_10cent' => (raw * 10).round() / 10,
      _ => (raw * 100).round() / 100,
    };
  }

  void _markDirty() => setState(() => _dirty = true);

  Future<String?> _save({bool silent = false}) async {
    if (_contactId == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Choose a customer first.'),
      ));
      return null;
    }
    final validLines =
        _lines.where((l) => l.description.trim().isNotEmpty || l.itemId != null);
    if (validLines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Add at least one line.'),
      ));
      return null;
    }

    setState(() => _saving = true);
    try {
      final id = await ref.read(repoProvider)!.saveSalesDocument(
            id: widget.documentId,
            docType: widget.docType,
            header: {
              'doc_no': _docNo,
              'doc_date': Fmt.iso(_docDate),
              'due_date': _dueDate == null ? null : Fmt.iso(_dueDate!),
              'contact_id': _contactId,
              'reference': _reference.text.trim().isEmpty
                  ? null
                  : _reference.text.trim(),
              'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
              'currency': _currency,
            },
            lines: validLines.map((l) => l.toJson()).toList(),
          );

      ref.invalidate(salesDocumentsProvider);
      if (mounted) setState(() => _dirty = false);

      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Saved'),
          backgroundColor: AppTheme.success,
        ));
      }
      return id;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$e'),
          backgroundColor: AppTheme.danger,
        ));
      }
      return null;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _post() async {
    final id = await _save(silent: true);
    if (id == null || !mounted) return;

    final ok = await confirm(
      context,
      title: 'Post to ledger?',
      message:
          'This writes a balanced journal entry and locks the document for '
          'editing. Stock will move for inventory items.',
      confirmLabel: 'Post',
    );
    if (!ok || !mounted) return;

    final posted = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.postSalesDocument(id),
      successMessage: 'Posted to the general ledger',
      pendingMessage: 'Posting…',
    );

    if (posted && mounted) {
      refreshLedgerData(ref);
      // Reload so the screen reflects its posted, read-only state.
      setState(() => _loading = true);
      await _load();
    }
  }

  Future<void> _submitEinvoice() async {
    if (widget.documentId == null) return;
    final org = ref.read(currentOrgProvider).value;

    if (org?.einvoiceEnabled != true) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Enable e-Invoice in Settings first.'),
      ));
      return;
    }

    final ok = await confirm(
      context,
      title: 'Submit to MyInvois?',
      message: org?.einvoiceEnvironment == 'production'
          ? 'This sends the invoice to LHDN production. Once validated it can '
              'only be cancelled within 72 hours.'
          : 'This sends the invoice to the LHDN sandbox for testing.',
      confirmLabel: 'Submit',
    );
    if (!ok || !mounted) return;

    await runWithFeedback(
      context,
      action: () async {
        final repo = ref.read(repoProvider)!;
        final result =
            await repo.submitEinvoice(salesDocumentId: widget.documentId);
        if ((result['rejected'] as int? ?? 0) > 0) {
          throw Exception('LHDN rejected the document: ${result['errors']}');
        }
        // Validation is asynchronous; poll once so the UI updates quickly.
        await Future<void>.delayed(const Duration(seconds: 2));
        await repo.refreshEinvoiceStatus();
      },
      successMessage: 'Submitted to MyInvois',
      pendingMessage: 'Submitting to LHDN…',
    );

    if (mounted) {
      refreshLedgerData(ref);
      setState(() => _loading = true);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final meta = salesDocTypes[widget.docType] ?? salesDocTypes['invoice']!;
    final canPost = ref.watch(canPostProvider);
    final canWrite = ref.watch(canWriteProvider);
    final editable = !_isPosted && canWrite;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !mounted) return;
        final leave = await confirm(
          context,
          title: 'Discard changes?',
          message: 'You have unsaved changes on this document.',
          confirmLabel: 'Discard',
          destructive: true,
        );
        if (leave && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isNew ? 'New ${meta.singular}' : _docNo),
          actions: [
            if (!_isNew) ...[
              StatusChip(_status),
              const SizedBox(width: 12),
            ],
            if (editable)
              TextButton(
                onPressed: _saving ? null : () => _save(),
                child: const Text('Save'),
              ),
            if (editable && canPost)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: FilledButton(
                  onPressed: _saving ? null : _post,
                  child: const Text('Post'),
                ),
              ),
            if (_isPosted && _isEinvoiceDoc)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: FilledButton.icon(
                  onPressed: _einvoiceStatus == 'valid' ? null : _submitEinvoice,
                  icon: Icon(
                    _einvoiceStatus == 'valid'
                        ? Icons.verified
                        : Icons.cloud_upload_outlined,
                    size: 18,
                  ),
                  label: Text(
                    _einvoiceStatus == 'valid'
                        ? 'e-Invoice valid'
                        : 'Submit e-Invoice',
                  ),
                ),
              ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                child: PageBody(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_isPosted)
                        _PostedBanner(
                          einvoiceStatus: _einvoiceStatus,
                          paidAmount: _paidAmount,
                          total: _grandTotal,
                        ),
                      _HeaderCard(
                        docNo: _docNo,
                        contactId: _contactId,
                        contactName: _contactName,
                        docDate: _docDate,
                        dueDate: _dueDate,
                        reference: _reference,
                        editable: editable,
                        onContactChanged: (id, name) {
                          setState(() {
                            _contactId = id;
                            _contactName = name;
                          });
                          _markDirty();
                        },
                        onDocDate: (d) {
                          setState(() => _docDate = d);
                          _markDirty();
                        },
                        onDueDate: (d) {
                          setState(() => _dueDate = d);
                          _markDirty();
                        },
                        onReferenceChanged: _markDirty,
                      ),
                      const SizedBox(height: 16),
                      LineEditorCard(
                        lines: _lines,
                        editable: editable,
                        currency: _currency,
                        onChanged: _markDirty,
                        onAdd: () {
                          setState(() => _lines.add(LineDraft()));
                          _markDirty();
                        },
                        onRemove: (i) {
                          setState(() => _lines.removeAt(i));
                          _markDirty();
                        },
                      ),
                      const SizedBox(height: 16),
                      _TotalsAndNotes(
                        subtotal: _subtotal,
                        tax: _taxTotal,
                        total: _grandTotal,
                        rounding: _grandTotal - (_subtotal + _taxTotal),
                        currency: _currency,
                        notes: _notes,
                        editable: editable,
                        onNotesChanged: _markDirty,
                      ),
                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

class _PostedBanner extends StatelessWidget {
  const _PostedBanner({
    required this.einvoiceStatus,
    required this.paidAmount,
    required this.total,
  });

  final String einvoiceStatus;
  final double paidAmount;
  final double total;

  @override
  Widget build(BuildContext context) {
    final outstanding = total - paidAmount;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.lock_outline, size: 20, color: AppTheme.success),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Posted to the ledger',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      outstanding > 0
                          ? '${Fmt.money(outstanding)} outstanding'
                          : 'Fully settled',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (einvoiceStatus != 'not_applicable')
                StatusChip(einvoiceStatus),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderCard extends ConsumerWidget {
  const _HeaderCard({
    required this.docNo,
    required this.contactId,
    required this.contactName,
    required this.docDate,
    required this.dueDate,
    required this.reference,
    required this.editable,
    required this.onContactChanged,
    required this.onDocDate,
    required this.onDueDate,
    required this.onReferenceChanged,
  });

  final String docNo;
  final String? contactId;
  final String? contactName;
  final DateTime docDate;
  final DateTime? dueDate;
  final TextEditingController reference;
  final bool editable;
  final void Function(String id, String name) onContactChanged;
  final ValueChanged<DateTime> onDocDate;
  final ValueChanged<DateTime> onDueDate;
  final VoidCallback onReferenceChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final customers =
        ref.watch(contactsProvider((type: 'customer', search: '')));
    final narrow = MediaQuery.sizeOf(context).width < 700;

    final customerField = customers.when(
      data: (list) => DropdownButtonFormField<String>(
        value: list.any((c) => c.id == contactId) ? contactId : null,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: 'Customer *',
          helperText: contactId != null &&
                  list.any((c) => c.id == contactId && !c.readyForEinvoice)
              ? 'This customer has no TIN — e-Invoice will be rejected'
              : null,
          helperStyle: const TextStyle(color: AppTheme.amber),
        ),
        items: [
          for (final c in list)
            DropdownMenuItem(
              value: c.id,
              child: Text('${c.name} (${c.code})',
                  overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: editable
            ? (v) {
                if (v == null) return;
                final c = list.firstWhere((e) => e.id == v);
                onContactChanged(c.id, c.name);
              }
            : null,
      ),
      loading: () => const LinearProgressIndicator(),
      error: (e, _) => Text('Could not load customers: $e'),
    );

    final fields = <Widget>[
      customerField,
      _DateField(
        label: 'Document date',
        value: docDate,
        enabled: editable,
        onChanged: onDocDate,
      ),
      _DateField(
        label: 'Due date',
        value: dueDate,
        enabled: editable,
        onChanged: onDueDate,
      ),
      TextFormField(
        controller: reference,
        enabled: editable,
        onChanged: (_) => onReferenceChanged(),
        decoration: const InputDecoration(
          labelText: 'Customer reference / PO no.',
        ),
      ),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader('Document $docNo'),
            if (narrow)
              Column(
                children: [
                  for (final f in fields)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: f,
                    ),
                ],
              )
            else
              Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 2, child: fields[0]),
                      const SizedBox(width: 14),
                      Expanded(child: fields[1]),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 2, child: fields[3]),
                      const SizedBox(width: 14),
                      Expanded(child: fields[2]),
                    ],
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final DateTime? value;
  final bool enabled;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled
          ? () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: value ?? DateTime.now(),
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
              );
              if (picked != null) onChanged(picked);
            }
          : null,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: const Icon(Icons.calendar_today, size: 18),
          enabled: enabled,
        ),
        child: Text(Fmt.date(value)),
      ),
    );
  }
}

class _TotalsAndNotes extends StatelessWidget {
  const _TotalsAndNotes({
    required this.subtotal,
    required this.tax,
    required this.total,
    required this.rounding,
    required this.currency,
    required this.notes,
    required this.editable,
    required this.onNotesChanged,
  });

  final double subtotal;
  final double tax;
  final double total;
  final double rounding;
  final String currency;
  final TextEditingController notes;
  final bool editable;
  final VoidCallback onNotesChanged;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 700;

    final notesCard = Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader('Notes'),
            TextFormField(
              controller: notes,
              enabled: editable,
              maxLines: 4,
              onChanged: (_) => onNotesChanged(),
              decoration: const InputDecoration(
                hintText: 'Visible to the customer on the printed document',
              ),
            ),
          ],
        ),
      ),
    );

    final totalsCard = Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            _TotalRow(label: 'Subtotal', value: subtotal, currency: currency),
            const SizedBox(height: 8),
            _TotalRow(label: 'SST', value: tax, currency: currency),
            if (rounding.abs() >= 0.005) ...[
              const SizedBox(height: 8),
              _TotalRow(
                label: 'Rounding',
                value: rounding,
                currency: currency,
                caption: 'Nearest 5 sen',
              ),
            ],
            const Divider(height: 24),
            _TotalRow(
              label: 'Total',
              value: total,
              currency: currency,
              emphasise: true,
            ),
          ],
        ),
      ),
    );

    if (narrow) {
      return Column(children: [totalsCard, const SizedBox(height: 16), notesCard]);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 3, child: notesCard),
        const SizedBox(width: 16),
        Expanded(flex: 2, child: totalsCard),
      ],
    );
  }
}

class _TotalRow extends StatelessWidget {
  const _TotalRow({
    required this.label,
    required this.value,
    required this.currency,
    this.emphasise = false,
    this.caption,
  });

  final String label;
  final double value;
  final String currency;
  final bool emphasise;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontWeight: emphasise ? FontWeight.w700 : FontWeight.w500,
                  fontSize: emphasise ? 16 : 14,
                ),
              ),
              if (caption != null)
                Text(caption!, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        Money(
          value,
          currency: currency,
          bold: emphasise,
          style: emphasise
              ? Theme.of(context).textTheme.titleLarge
              : Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }
}
