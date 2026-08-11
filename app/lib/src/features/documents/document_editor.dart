import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/download.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import 'doc_types.dart';
import 'invoice_pdf.dart';
import 'line_draft.dart';
import 'line_editor.dart';
import 'settlement_dialog.dart';

/// One editor for every document type in both cycles. What changes
/// between them — which contacts are selectable, whether posting writes a
/// journal, whether MyInvois applies — comes from DocTypeMeta.
class DocumentEditor extends ConsumerStatefulWidget {
  const DocumentEditor({super.key, required this.docType, this.documentId});

  final String docType;
  final String? documentId;

  @override
  ConsumerState<DocumentEditor> createState() => _DocumentEditorState();
}

class _DocumentEditorState extends ConsumerState<DocumentEditor> {
  final _reference = TextEditingController();
  final _supplierDocNo = TextEditingController();
  final _notes = TextEditingController();

  String? _contactId;
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

  DocTypeMeta get _meta => metaFor(widget.docType);
  DocKind get _kind => _meta.kind;
  bool get _isNew => widget.documentId == null;
  bool get _isPosted => _glEntryId != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reference.dispose();
    _supplierDocNo.dispose();
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
        final doc = await repo.document(_kind, widget.documentId!);
        _docNo = doc.docNo;
        _contactId = doc.contactId;
        _docDate = doc.docDate;
        _dueDate = doc.dueDate;
        _currency = doc.currency;
        _status = doc.status;
        _einvoiceStatus = doc.einvoiceStatus;
        _glEntryId = doc.glEntryId;
        _paidAmount = doc.paidAmount;
        _reference.text = doc.reference ?? '';
        _supplierDocNo.text = doc.supplierDocNo ?? '';
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
  double get _subtotal => _lines.fold(0, (sum, l) => sum + l.totals.net);
  double get _taxTotal => _lines.fold(0, (sum, l) => sum + l.totals.tax);
  double get _grandTotal {
    final raw = _subtotal + _taxTotal;
    return switch (ref.read(currentOrgProvider).value?.roundingMethod) {
      'nearest_5cent' => (raw * 20).round() / 20,
      'nearest_10cent' => (raw * 10).round() / 10,
      _ => (raw * 100).round() / 100,
    };
  }

  void _markDirty() => setState(() => _dirty = true);

  Future<String?> _save({bool silent = false}) async {
    if (_contactId == null) {
      _toast('Choose a ${_kind.contactLabel.toLowerCase()} first.');
      return null;
    }
    final validLines =
        _lines.where((l) => l.description.trim().isNotEmpty || l.itemId != null);
    if (validLines.isEmpty) {
      _toast('Add at least one line.');
      return null;
    }

    setState(() => _saving = true);
    try {
      final id = await ref.read(repoProvider)!.saveDocument(
            kind: _kind,
            id: widget.documentId,
            docType: widget.docType,
            header: {
              'doc_no': _docNo,
              'doc_date': Fmt.iso(_docDate),
              'due_date': _dueDate == null ? null : Fmt.iso(_dueDate!),
              'contact_id': _contactId,
              'reference': _nullIfBlank(_reference.text),
              if (!_kind.isSales)
                'supplier_doc_no': _nullIfBlank(_supplierDocNo.text),
              'notes': _nullIfBlank(_notes.text),
              'currency': _currency,
            },
            lines: validLines.map((l) => l.toJson()).toList(),
          );

      ref.invalidate(documentsProvider);
      if (mounted) setState(() => _dirty = false);
      if (!silent) _toast('Saved', success: true);
      return id;
    } catch (e) {
      _toast('$e', error: true);
      return null;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// The saved document as the customer's copy.
  ///
  /// Reloaded from the database rather than assembled from the form, so
  /// what prints is what was stored — an unsaved edit in a text field is
  /// not part of the invoice yet, and printing it would say otherwise.
  Future<void> _downloadPdf() async {
    final messenger = ScaffoldMessenger.of(context);
    final org = ref.read(currentOrgProvider).valueOrNull;
    final repo = ref.read(repoProvider);
    if (org == null || repo == null || widget.documentId == null) return;

    try {
      final doc = await repo.document(_kind, widget.documentId!);
      final bytes = await buildInvoicePdf(
        org: org,
        doc: doc,
        documentLabel: _meta.singular,
      );
      final stem =
          doc.docNo.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-').toLowerCase();
      final saved =
          await saveBytesFile('$stem.pdf', 'application/pdf', bytes);
      messenger.showSnackBar(SnackBar(
        content: Text(saved
            ? 'Downloaded'
            : 'PDF download is only available in the browser'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _post() async {
    final id = await _save(silent: true);
    if (id == null || !mounted) return;

    final ok = await confirm(
      context,
      title: 'Post to ledger?',
      message: 'This writes a balanced journal entry and locks the document '
          'for editing. Stock will move for inventory items.',
      confirmLabel: 'Post',
    );
    if (!ok || !mounted) return;

    final posted = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.postDocument(_kind, id),
      successMessage: 'Posted to the general ledger',
      pendingMessage: 'Posting…',
    );

    if (posted && mounted) {
      refreshLedgerData(ref);
      setState(() => _loading = true);
      await _load();
    }
  }

  Future<void> _submitEinvoice() async {
    if (widget.documentId == null) return;
    final org = ref.read(currentOrgProvider).value;

    if (org?.einvoiceEnabled != true) {
      _toast('Enable e-Invoice in Settings first.');
      return;
    }

    final ok = await confirm(
      context,
      title: 'Submit to MyInvois?',
      message: org?.einvoiceEnvironment == 'production'
          ? 'This sends the document to LHDN production. Once validated it '
              'can only be cancelled within 72 hours.'
          : 'This sends the document to the LHDN sandbox for testing.',
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

  void _toast(String message, {bool success = false, bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor:
          success ? context.colors.success : (error ? context.colors.danger : null),
    ));
  }

  static String? _nullIfBlank(String v) => v.trim().isEmpty ? null : v.trim();

  @override
  Widget build(BuildContext context) {
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
          title: Text(_isNew ? 'New ${_meta.singular}' : _docNo),
          actions: [
            if (!_isNew) ...[StatusChip(_status), const SizedBox(width: 12)],
            // Only once it exists: there is nothing to print from a form
            // that has not been saved, and a PDF of a half-typed invoice
            // is a document somebody could send.
            if (!_isNew)
              IconButton(
                tooltip: 'Download PDF',
                icon: const Icon(Icons.picture_as_pdf_outlined, size: 20),
                onPressed: _saving ? null : _downloadPdf,
              ),
            if (editable)
              TextButton(
                onPressed: _saving ? null : () => _save(),
                child: const Text('Save'),
              ),
            if (editable && canPost && _meta.posts)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: FilledButton(
                  onPressed: _saving ? null : _post,
                  child: const Text('Post'),
                ),
              ),
            if (_isPosted && _meta.settles && _grandTotal - _paidAmount > 0)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: TextButton.icon(
                  onPressed: canPost
                      ? () async {
                          await showSettlementDialog(
                            context,
                            ref,
                            kind: _kind,
                            contactId: _contactId,
                            documentId: widget.documentId,
                          );
                          if (!mounted) return;
                          setState(() => _loading = true);
                          await _load();
                        }
                      : null,
                  icon: const Icon(Icons.payments_outlined, size: 18),
                  label: Text(_kind.isSales ? 'Receive payment' : 'Pay'),
                ),
              ),
            if (_isPosted && _meta.einvoice)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: FilledButton.icon(
                  onPressed:
                      _einvoiceStatus == 'valid' ? null : _submitEinvoice,
                  icon: Icon(
                    _einvoiceStatus == 'valid'
                        ? Icons.verified
                        : Icons.cloud_upload_outlined,
                    size: 18,
                  ),
                  label: Text(_einvoiceStatus == 'valid'
                      ? 'e-Invoice valid'
                      : 'Submit e-Invoice'),
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
                          kind: _kind,
                          settles: _meta.settles,
                        ),
                      _HeaderCard(
                        docNo: _docNo,
                        kind: _kind,
                        contactId: _contactId,
                        docDate: _docDate,
                        dueDate: _dueDate,
                        reference: _reference,
                        supplierDocNo: _supplierDocNo,
                        editable: editable,
                        requiresEinvoice: _meta.einvoice,
                        onContactChanged: (id) {
                          setState(() => _contactId = id);
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
                        onTextChanged: _markDirty,
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
    required this.kind,
    required this.settles,
  });

  final String einvoiceStatus;
  final double paidAmount;
  final double total;
  final DocKind kind;
  final bool settles;

  @override
  Widget build(BuildContext context) {
    final outstanding = total - paidAmount;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Row(
            children: [
              Icon(Icons.lock_outline, size: 20, color: context.colors.success),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Posted to the ledger',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    Text(
                      !settles
                          ? 'Journal written'
                          : outstanding > 0
                              ? '${Fmt.money(outstanding)} '
                                  '${kind.isSales ? 'outstanding' : 'still to pay'}'
                              : 'Fully settled',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (einvoiceStatus != 'not_applicable') StatusChip(einvoiceStatus),
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
    required this.kind,
    required this.contactId,
    required this.docDate,
    required this.dueDate,
    required this.reference,
    required this.supplierDocNo,
    required this.editable,
    required this.requiresEinvoice,
    required this.onContactChanged,
    required this.onDocDate,
    required this.onDueDate,
    required this.onTextChanged,
  });

  final String docNo;
  final DocKind kind;
  final String? contactId;
  final DateTime docDate;
  final DateTime? dueDate;
  final TextEditingController reference;
  final TextEditingController supplierDocNo;
  final bool editable;
  final bool requiresEinvoice;
  final ValueChanged<String> onContactChanged;
  final ValueChanged<DateTime> onDocDate;
  final ValueChanged<DateTime> onDueDate;
  final VoidCallback onTextChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contacts =
        ref.watch(contactsProvider((type: kind.contactType, search: '')));
    final narrow = MediaQuery.sizeOf(context).width < 700;

    final contactField = contacts.when(
      data: (list) {
        final selected = list.where((c) => c.id == contactId).firstOrNull;
        final warnMissingTin =
            requiresEinvoice && selected != null && !selected.readyForEinvoice;
        return DropdownButtonFormField<String>(
          value: selected?.id,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: '${kind.contactLabel} *',
            helperText: warnMissingTin
                ? 'No TIN on file — e-Invoice will be rejected'
                : null,
            helperStyle: TextStyle(color: context.colors.warning),
          ),
          items: [
            for (final c in list)
              DropdownMenuItem(
                value: c.id,
                child: Text('${c.name} (${c.code})',
                    overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: editable ? (v) => v == null ? null : onContactChanged(v) : null,
        );
      },
      loading: () => const LinearProgressIndicator(),
      error: (e, _) => Text('Could not load contacts: $e'),
    );

    final fields = <Widget>[
      contactField,
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
        onChanged: (_) => onTextChanged(),
        decoration: InputDecoration(
          labelText: kind.isSales
              ? 'Customer reference / PO no.'
              : 'Internal reference',
        ),
      ),
      if (!kind.isSales)
        TextFormField(
          controller: supplierDocNo,
          enabled: editable,
          onChanged: (_) => onTextChanged(),
          decoration: const InputDecoration(
            labelText: 'Supplier invoice no.',
            helperText: 'Their document number, needed for SST records',
          ),
        ),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
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
                  if (fields.length > 4) ...[
                    const SizedBox(height: 14),
                    Row(children: [Expanded(child: fields[4])]),
                  ],
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
        padding: const EdgeInsets.all(Space.lg),
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
                hintText: 'Visible on the printed document',
              ),
            ),
          ],
        ),
      ),
    );

    final totalsCard = Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
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
      return Column(
          children: [totalsCard, const SizedBox(height: 16), notesCard]);
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
