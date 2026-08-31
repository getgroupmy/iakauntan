import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/export_log.dart';
import '../../core/format.dart';
import '../../core/layout.dart';
import '../../core/pdf_kit.dart' show LetterheadMode;
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/ocr_repository.dart';
import '../../data/repository.dart';
import '../shared/attachments_card.dart';
import '../shared/scan_intake.dart';
import 'doc_types.dart';
import 'document_dates.dart';
import 'email_dialog.dart';
import 'fx.dart';
import 'invoice_pdf.dart';
import 'line_draft.dart';
import 'line_editor.dart';
import 'settlement_dialog.dart';
import 'transfer.dart';
import 'void_document.dart';
import 'credit_dialog.dart';
import 'transfer_dialog.dart';
import 'repeat_dialog.dart';
import 'withholding_dialog.dart';
import 'share_dialog.dart';

/// One editor for every document type in both cycles. What changes
/// between them — which contacts are selectable, whether posting writes a
/// journal, whether MyInvois applies — comes from DocTypeMeta.
/// What a party has on deposit, altogether.
///
/// `deposits_held_for` returns the open notes with something left on
/// them, so the sum is what could be set against this document — not
/// what was ever taken.
double depositsHeldTotal(Iterable<Map<String, dynamic>> rows) => double.parse(
      rows
          .fold<double>(
            0,
            (a, r) => a + (double.tryParse('${r['balance'] ?? 0}') ?? 0),
          )
          .toStringAsFixed(2),
    );

/// How the held deposits read on the banner.
///
/// The count is named because two deposits and one of twice the size
/// settle differently: each note is applied on its own, and somebody
/// looking at a single figure would expect one action.
String depositsHeldLabel(List<Map<String, dynamic>> rows) {
  final total = Fmt.money(depositsHeldTotal(rows));
  return rows.length == 1
      ? '$total held on deposit'
      : '$total held on ${rows.length} deposits';
}

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
  final _rate = TextEditingController(text: '1');

  String? _contactId;
  String _docNo = '';
  DateTime _docDate = DateTime.now();
  DateTime? _dueDate;

  /// The day the price stops holding, on a quotation or a proforma, and
  /// the day delivery was promised. Columns since `0005` that nothing
  /// set until `0374`.
  DateTime? _validUntil;
  DateTime? _deliveryDate;
  String _currency = 'MYR';

  /// Null means no rate is known. Distinct from 1, which is a rate — and
  /// on a foreign document, the wrong one.
  double? _exchangeRate = 1;

  /// Whether the rate in the field was typed rather than looked up. A
  /// contract rate agreed with the customer outranks the table, so once
  /// it has been typed, changing the date must not quietly overwrite it.
  bool _rateOverridden = false;
  bool _resolvingRate = false;

  /// The table was asked and had nothing for this currency and date.
  bool _rateMissing = false;

  /// The job this whole document belongs to, stamped onto every line at
  /// save time. `gl_lines.project_code` is per line because the ledger
  /// needs the analysis there; the choice is per document because that
  /// is how the work actually arrives.
  String? _projectCode;

  /// The part of the business this document belongs to, stamped onto
  /// every line at save time exactly as the project is.
  ///
  /// `report_profit_loss_by_dimension` has been able to split the P&L by
  /// department since the dimensions work, and on this deployment it has
  /// never had anything to split: `gl_lines.department_code` is carried
  /// faithfully by both posting routines and no screen ever wrote it. A
  /// report reading a column nothing fills is a report that says every
  /// department earned nothing.
  String? _departmentCode;
  String? _salespersonId;
  String _status = 'draft';

  /// How much of this document has already gone forward. Shown because a
  /// quotation that has been turned into an order looks identical to one
  /// that has not, and transferring it twice is the mistake that follows.
  String _fulfilment = 'pending';
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

  String get _base =>
      ref.read(currentOrgProvider).valueOrNull?.baseCurrency ?? 'MYR';
  bool get _isForeign => _currency != _base;

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
    _rate.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    try {
      if (_isNew) {
        _docNo = await repo.nextDocumentNumber(widget.docType);
        _dueDate = DateTime.now().add(const Duration(days: 30));
        // A new quotation arrives with a date on it. The alternative is
        // that it arrives with none and never gets one, which is how a
        // price came to be held open indefinitely.
        if (showsValidUntil(widget.docType)) {
          _validUntil = defaultValidUntil(_docDate);
        }
        _currency = _base;
        _exchangeRate = 1;
        _rate.text = '1';
        _lines.add(LineDraft());
      } else {
        final doc = await repo.document(_kind, widget.documentId!);
        _docNo = doc.docNo;
        _contactId = doc.contactId;
        _docDate = doc.docDate;
        _dueDate = doc.dueDate;
        _validUntil = doc.validUntil;
        _deliveryDate = doc.deliveryDate;
        _currency = doc.currency;
        // The stored rate, not today's. This is the figure the ledger
        // posted at and the figure the gain on settlement is measured
        // from; re-resolving it here would rewrite history.
        _exchangeRate = doc.exchangeRate;
        _rate.text = Fmt.rate(doc.exchangeRate);
        _rateOverridden = true;
        _status = doc.status;
        _fulfilment = doc.fulfilmentStatus;
        _einvoiceStatus = doc.einvoiceStatus;
        _glEntryId = doc.glEntryId;
        _paidAmount = doc.paidAmount;
        _projectCode = doc.lines
            .map((l) => l.projectCode)
            .firstWhere((c) => c != null, orElse: () => null);
        _departmentCode = doc.lines
            .map((l) => l.departmentCode)
            .firstWhere((c) => c != null, orElse: () => null);
        _salespersonId = doc.salespersonId;
        _reference.text = doc.reference ?? '';
        _supplierDocNo.text = doc.supplierDocNo ?? '';
        _notes.text = doc.notes ?? '';
        _lines
          ..clear()
          ..addAll(doc.lines.map(LineDraft.fromLine));
        if (_lines.isEmpty) _lines.add(LineDraft());

        // Without this, opening a tracked document and saving it again
        // would quietly throw its batch numbers away: the save deletes
        // every line and reinserts it, and the allocation goes with the
        // line it hung off. Read back in the same order it will be
        // written out.
        final ids = [
          for (final l in doc.lines)
            if (l.id != null) l.id!,
        ];
        if (ids.isNotEmpty) {
          final byLine = await repo.lotsForDocument(kind: _kind, lineIds: ids);
          if (byLine.isNotEmpty) {
            for (var i = 0; i < doc.lines.length && i < _lines.length; i++) {
              final id = doc.lines[i].id;
              if (id != null && byLine[id] != null) {
                _lines[i].lots = byLine[id]!;
              }
            }
          }
        }
      }
      // A reading parked by "Scan a bill" on the list screen, taken
      // once. The draft it created is empty but for the supplier's
      // number and date; this is where the lines arrive, and where
      // somebody chooses the supplier and the tax code that nothing
      // guessed for them.
      final id = widget.documentId;
      if (id != null) {
        final scanned = ref.read(pendingScanProvider.notifier).take(id);
        if (scanned != null) _applyScan(scanned);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not load: $e')));
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

  /// Fills this bill in from the supplier's own paperwork.
  ///
  /// The supplier is deliberately not matched by name. Two contacts
  /// called "Syarikat Maju" are an ordinary thing in a contact list, and
  /// putting the bill against the wrong one is a mistake that surfaces
  /// months later in an aged payables listing. The number, the date and
  /// the lines are what this fills; who it is from stays a person's
  /// decision.
  ///
  /// Tax codes are left alone for the same reason: a rate guessed off a
  /// printed figure is a posted amount that does not match the return.
  void _applyScan(OcrExtraction read) {
    setState(() {
      if (read.documentNo != null) _supplierDocNo.text = read.documentNo!;
      if (read.documentDate != null) _docDate = read.documentDate!;

      // Only into an empty document. Somebody who has already keyed the
      // lines and is scanning to attach the paper should not lose them.
      final blank = _lines.every(
        (l) => l.description.trim().isEmpty && l.itemId == null,
      );
      if (!blank) return;

      final lines = read.lines
          .where((l) => (l.description ?? '').trim().isNotEmpty)
          .map(
            (l) => LineDraft(
              description: l.description!.trim(),
              quantity: l.quantity ?? 1,
              unitPrice:
                  l.unitPrice ??
                  (l.amount != null && (l.quantity ?? 1) != 0
                      ? l.amount! / (l.quantity ?? 1)
                      : 0),
            ),
          )
          .toList();

      // A receipt that prints one total and no breakdown still has to
      // become a line, or there is nothing to post.
      final net = read.netAmount;
      if (lines.isEmpty && net != null) {
        lines.add(
          LineDraft(
            description: read.supplierName ?? 'Per the attached document',
            unitPrice: net,
          ),
        );
      }
      if (lines.isEmpty) return;

      _lines
        ..clear()
        ..addAll(lines);
      _dirty = true;
    });
  }

  // ------------------------------------------------------------------
  // Currency and rate
  // ------------------------------------------------------------------

  /// Switches the document's currency and starts again on the rate.
  ///
  /// Any override is dropped: a rate typed for dollars is not a rate for
  /// euros, and carrying it across would be the same silent mis-statement
  /// as defaulting to 1.
  void _changeCurrency(String code) {
    setState(() {
      _currency = code;
      _rateOverridden = false;
    });
    _markDirty();
    _resolveRate();
  }

  /// Fills the rate from `exchange_rates` for the document's date.
  ///
  /// The client asks for the same rate the database would use rather
  /// than working one out, so what the form shows before saving and what
  /// posts afterwards cannot disagree.
  Future<void> _resolveRate() async {
    if (!_isForeign) {
      setState(() {
        _exchangeRate = 1;
        _rate.text = '1';
        _rateMissing = false;
      });
      return;
    }

    final repo = ref.read(repoProvider);
    if (repo == null) return;

    setState(() => _resolvingRate = true);
    try {
      final rate = await repo.exchangeRateFor(_currency, _docDate);
      if (!mounted) return;
      setState(() {
        _rateMissing = rate == null;
        if (rate != null) {
          _exchangeRate = rate;
          _rate.text = Fmt.rate(rate);
        } else {
          // Left as whatever is in the field so a rate typed a moment
          // ago is not erased by a lookup that found nothing.
          _exchangeRate = parseRate(_rate.text);
        }
      });
    } catch (e) {
      // Cleared rather than left as it was. A lookup for euros that
      // fails must not leave the rate for dollars sitting in the field
      // where it would be saved as the euro rate.
      if (mounted) {
        setState(() => _exchangeRate = null);
        _toast('Could not read the exchange rate: $e', error: true);
      }
    } finally {
      if (mounted) setState(() => _resolvingRate = false);
    }
  }

  void _onRateTyped(String text) {
    setState(() {
      _exchangeRate = parseRate(text);
      _rateOverridden = true;
    });
    _markDirty();
  }

  /// Remembers a typed rate so the next document in this currency does
  /// not have to be told again.
  Future<void> _storeRate() async {
    final rate = _exchangeRate;
    if (rate == null || !_isForeign) return;

    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .saveExchangeRate(
            from: _currency,
            to: _base,
            rate: rate,
            date: _docDate,
          ),
      successMessage:
          '${rateCaption(currency: _currency, baseCurrency: _base, rate: rate)} '
          'saved for ${Fmt.date(_docDate)}',
      pendingMessage: 'Saving rate…',
    );
    if (ok && mounted) setState(() => _rateMissing = false);
  }

  Future<String?> _save({bool silent = false}) async {
    if (_contactId == null) {
      _toast('Choose a ${_kind.contactLabel.toLowerCase()} first.');
      return null;
    }
    final validLines = _lines.where(
      (l) => l.description.trim().isNotEmpty || l.itemId != null,
    );
    if (validLines.isEmpty) {
      _toast('Add at least one line.');
      return null;
    }
    // Refused here rather than left to post at 1. A foreign document
    // saved without a rate converts at par, balances, and understates
    // the ledger by the whole currency movement without a single check
    // objecting — see migration 0078.
    if (!rateIsUsable(
      currency: _currency,
      baseCurrency: _base,
      rate: _exchangeRate,
    )) {
      _toast(
        'Enter the exchange rate for $_currency on '
        '${Fmt.date(_docDate)} before saving.',
      );
      return null;
    }

    setState(() => _saving = true);
    try {
      final repo = ref.read(repoProvider)!;
      final id = await repo.saveDocument(
        kind: _kind,
        id: widget.documentId,
        docType: widget.docType,
        header: {
          'doc_no': _docNo,
          'doc_date': Fmt.iso(_docDate),
          'due_date': _dueDate == null ? null : Fmt.iso(_dueDate!),
          if (showsValidUntil(widget.docType))
            'valid_until': _validUntil == null ? null : Fmt.iso(_validUntil!),
          if (showsDeliveryDate(widget.docType))
            'delivery_date':
                _deliveryDate == null ? null : Fmt.iso(_deliveryDate!),
          'contact_id': _contactId,
          'reference': _nullIfBlank(_reference.text),
          if (!_kind.isSales)
            'supplier_doc_no': _nullIfBlank(_supplierDocNo.text),
          'notes': _nullIfBlank(_notes.text),
          'currency': _currency,
          'exchange_rate': _exchangeRate ?? 1,
          // Sales only. The column is on `sales_documents` alone,
          // and a bill has no salesperson by definition.
          if (_kind.isSales) 'salesperson_id': _salespersonId,
        },
        lines: validLines.map((l) {
          l.projectCode = _projectCode;
          l.departmentCode = _departmentCode;
          return l.toJson();
        }).toList(),
      );

      // Only now, because until `saveDocument` returned the lines did
      // not exist under ids anything could point at. Matched by order,
      // which is the one property that survives delete-and-reinsert.
      final tracked = validLines.toList();
      if (tracked.any((l) => l.lots.isNotEmpty)) {
        final saved = await repo.documentLineIds(kind: _kind, documentId: id);
        for (var i = 0; i < tracked.length && i < saved.length; i++) {
          if (tracked[i].lots.isEmpty) continue;
          await repo.setLineLots(
            lineTable: _kind.lineTable,
            lineId: saved[i]['id'] as String,
            lots: tracked[i].lots,
          );
        }
      }

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
  /// The same renderer feeds the download button and the email
  /// attachment, so a customer who is sent the PDF and a colleague who
  /// downloads it are looking at the same document.
  Future<Uint8List> _renderPdf() async {
    final org = ref.read(currentOrgProvider).valueOrNull;
    final repo = ref.read(repoProvider);
    if (org == null || repo == null || widget.documentId == null) {
      throw StateError('Nothing to render yet');
    }
    return buildInvoicePdf(
      org: org,
      doc: await repo.document(_kind, widget.documentId!),
      documentLabel: _meta.singular,
      logo: await ref.read(orgLogoProvider.future),
      mode: org.usesPreprintedLetterhead
          ? LetterheadMode.stationery
          : LetterheadMode.printed,
    );
  }

  /// Opens the send dialog: queue it, send it now, send it somewhere
  /// else, attach the PDF or not, and read what has already been sent,
  /// shared or downloaded.
  ///
  /// The customer's address is looked up first so the field shows what
  /// it would go to rather than an empty box — "send it to somebody
  /// else" is hard to mean if you cannot see who it was going to. A
  /// failed lookup is not fatal: the dialog falls back to the same
  /// address server-side.
  Future<void> _emailDocument() async {
    final repo = ref.read(repoProvider);
    if (repo == null || widget.documentId == null) return;

    String? to;
    if (_contactId != null) {
      try {
        to = (await repo.contact(_contactId!)).email;
      } catch (_) {
        to = null;
      }
    }
    if (!mounted) return;

    await showEmailDialog(
      context,
      documentId: widget.documentId!,
      docNo: _docNo,
      defaultTo: (to != null && to.trim().isNotEmpty) ? to.trim() : null,
      buildPdf: _renderPdf,
    );
  }

  /// Puts a new date on an offer whose price has run out.
  ///
  /// A deliberate act with a date somebody chooses, rather than a
  /// transfer that quietly honours last year's price. The default is
  /// another thirty days from today, which is what somebody extending a
  /// quote almost always means.
  Future<void> _extendValidity() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: defaultValidUntil(DateTime.now()),
      // Never into the past: `extend_document_validity` refuses it, and
      // a picker that offers it is a form asking to be rejected.
      firstDate: DateTime.now(),
      lastDate: DateTime(DateTime.now().year + 3),
    );
    if (picked == null || !mounted) return;

    final ok = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.extendDocumentValidity(widget.documentId!, picked),
      successMessage: 'Good until ${Fmt.date(picked)}',
    );
    if (ok && mounted) setState(() => _validUntil = picked);
  }

  Future<void> _downloadPdf() async {
    final messenger = ScaffoldMessenger.of(context);
    final org = ref.read(currentOrgProvider).valueOrNull;
    final repo = ref.read(repoProvider);
    if (org == null || repo == null || widget.documentId == null) return;

    try {
      final bytes = await _renderPdf();
      final stem = _docNo
          .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
          .toLowerCase();
      final saved = await exportBytesFile(
        ref,
        '$stem.pdf',
        'application/pdf',
        bytes,
        what: 'Document',
        detail: _docNo,
      );

      // Recorded only when a file actually reached the user, and only
      // for sales documents — the activity trail is about what the
      // customer received, and nobody sends a supplier their own bill.
      // Best-effort: a document that downloaded fine should not report
      // an error because the audit row did not write.
      if (saved && _kind.isSales) {
        try {
          await repo.logDocumentDownload(widget.documentId!);
          ref.invalidate(documentActivityProvider(widget.documentId!));
        } catch (_) {
          // Nothing the person downloading can do about it.
        }
      }

      messenger.showSnackBar(
        SnackBar(
          content: Text(
            saved
                ? 'Downloaded'
                : 'PDF download is only available in the browser',
          ),
        ),
      );
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
      message:
          'This writes a balanced journal entry and locks the document '
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

  /// Where this document stands with the approval chain, or null on a
  /// document that has not been saved yet — there is nothing to approve
  /// until there is a row to approve.
  ///
  /// Watched rather than read, so signing it off in another tab or on a
  /// phone updates the button here without a reload.
  Map<String, dynamic>? get _approval {
    final id = widget.documentId;
    if (id == null) return null;
    return ref
        .watch(
          approvalStateProvider((
            kind: _kind.isSales ? 'sales_document' : 'purchase_document',
            id: id,
          )),
        )
        .valueOrNull;
  }

  String? get _voidBlocked => voidBlockedBecause(
        status: _status,
        paidAmount: _paidAmount,
        einvoiceStatus: _einvoiceStatus,
      );

  Future<void> _void() async {
    final id = widget.documentId;
    if (id == null) return;
    final reason = await askVoidReason(context, docNo: _docNo);
    if (reason == null || !mounted) return;

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.voidSalesDocument(id, reason),
      successMessage: 'Voided and reversed',
    );
    if (ok && mounted) {
      refreshLedgerData(ref);
      setState(() => _loading = true);
      await _load();
    }
  }

  Future<void> _discard() async {
    final id = widget.documentId;
    if (id == null) return;
    if (!await askDiscard(context, docNo: _docNo) || !mounted) return;

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.deleteDocument(_kind, id),
      successMessage: 'Discarded',
    );
    if (ok && mounted) {
      refreshLedgerData(ref);
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _submitForApproval() async {
    final id = await _save(silent: true);
    if (id == null || !mounted) return;

    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .submitForApproval(
            _kind.isSales ? 'sales_document' : 'purchase_document',
            id,
          ),
      successMessage: 'Sent for approval',
      pendingMessage: 'Sending…',
    );

    if (ok && mounted) {
      ref.invalidate(approvalStateProvider);
      // The person who has to sign it may be looking at their inbox.
      ref.invalidate(myApprovalsProvider);
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
        final result = await repo.submitEinvoice(
          salesDocumentId: widget.documentId,
        );
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: success
            ? context.colors.success
            : (error ? context.colors.danger : null),
      ),
    );
  }

  static String? _nullIfBlank(String v) => v.trim().isEmpty ? null : v.trim();

  /// Takes this document forward into the next one in the cycle.
  ///
  /// Saves first: transferring reads the lines from the database, so an
  /// edit still sitting in a text field would be silently left behind
  /// and the new document would disagree with the one on screen.
  Future<void> _transfer(String targetType) async {
    if (_dirty) {
      final id = await _save(silent: true);
      if (id == null) return;
    }
    if (!mounted || widget.documentId == null) return;

    final created = await showTransferDialog(
      context,
      ref,
      sourceId: widget.documentId!,
      sourceType: widget.docType,
      targetType: targetType,
    );
    if (created == null || !mounted) return;

    _toast('${metaFor(targetType).singular} created', success: true);
    context.go('${_kind.routePrefix}/$targetType/$created');
  }

  /// Crediting the invoice on screen. A method on the State rather than
  /// a closure in `_actions`, because `_actions` is handed a
  /// `BuildContext` of its own and the State's `mounted` says nothing
  /// about that one.
  Future<void> _credit() async {
    if (widget.documentId == null) return;
    final purchase = widget.docType == 'bill';
    final made = await showCreditDialog(
      context,
      ref,
      invoiceId: widget.documentId!,
      invoiceNo: _docNo,
      purchase: purchase,
    );
    if (made == null || !mounted) return;
    _toast('Credit note created', success: true);
    context.go('${_kind.routePrefix}/'
        '${purchase ? 'purchase_credit_note' : 'credit_note'}/$made');
  }

  Future<void> _settle() async {
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

  /// What the app bar offers, and how much of it survives a phone.
  ///
  /// AppBar actions neither wrap nor scroll: whatever does not fit runs
  /// off the right edge and cannot be reached at all. A posted invoice
  /// carries a status chip, a PDF button, "Receive payment" and "Submit
  /// e-Invoice", which is comfortably wider than a phone — so on a
  /// narrow screen only the primary action keeps its button and the rest
  /// fold into a menu.
  ///
  /// Which action is primary follows the hierarchy the wide layout
  /// already had, rather than inventing a new one: the filled button
  /// stays filled.
  List<Widget> _actions(
    BuildContext context, {
    required bool editable,
    required bool canPost,
    required bool canWrite,
  }) {
    final narrow = MediaQuery.sizeOf(context).width < 640;
    final einvoiceValid = _einvoiceStatus == 'valid';

    // Two different questions, and both have to be yes. `_meta.einvoice`
    // says this kind of document is one LHDN wants; this says the
    // company has switched submission on and has credentials behind it.
    // Offering the button to a company that has not is offering a button
    // whose only outcome is being told to go to Settings, which is a
    // worse way to say "not set up" than not being there at all.
    final einvoiceOn =
        ref.watch(currentOrgProvider).value?.einvoiceEnabled == true;

    final primary = switch (null) {
      _ when editable && canPost && _meta.posts => (
        label: 'Post',
        short: 'Post',
        icon: null,
        onTap: _saving ? null : _post,
      ),
      _ when _isPosted && _meta.einvoice && einvoiceOn => (
        label: einvoiceValid ? 'e-Invoice valid' : 'Submit e-Invoice',
        short: einvoiceValid ? 'Valid' : 'Submit',
        icon: einvoiceValid ? Icons.verified : Icons.cloud_upload_outlined,
        onTap: einvoiceValid ? null : _submitEinvoice,
      ),
      _ => null,
    };

    final secondary = <({String label, IconData icon, VoidCallback? onTap})>[
      if (editable)
        (
          label: 'Save',
          icon: Icons.save_outlined,
          onTap: _saving ? null : () => _save(),
        ),
      // Only on a document that exists and has somewhere to go. A
      // quotation with nothing left outstanding still offers this — the
      // dialog is where "everything has already been taken" is said,
      // because that is where the outstanding quantities are known.
      // `canWrite`, not `editable`. A partly transferred document is
      // read-only for editing and must still be transferable, or the
      // second half of a part delivery could never be sent.
      if (!_isNew && canWrite && !_isPosted)
        for (final target in transferTargets(widget.docType))
          (
            label: 'Transfer to ${metaFor(target).singular.toLowerCase()}',
            icon: Icons.arrow_forward,
            onTap: _saving ? null : () => _transfer(target),
          ),
      // Only when a rule actually covers this document and nothing has
      // been sent round yet. The gate is a trigger and will refuse the
      // posting whatever the screen offers, but being told after
      // pressing Post is a worse way to learn a signature is needed than
      // being given the button that gets one.
      if (!_isNew &&
          !_isPosted &&
          canWrite &&
          _approval?['is_required'] == true &&
          _approval?['is_approved'] != true &&
          _approval?['request_id'] == null)
        (
          label: 'Send for approval',
          icon: Icons.how_to_reg_outlined,
          onTap: _saving ? null : _submitForApproval,
        ),
      if (_isPosted && _meta.settles && _grandTotal - _paidAmount > 0)
        (
          label: _kind.isSales ? 'Receive payment' : 'Pay',
          icon: Icons.payments_outlined,
          onTap: canPost ? _settle : null,
        ),
      // Taking one back. Sales only, because `void_sales_document` is
      // the only void in the schema -- there is no purchase equivalent,
      // and a bill entered in error is corrected with the supplier.
      // The item is shown disabled with its reason rather than hidden,
      // so somebody looking for it learns why it is not on.
      if (!_isNew && _isPosted && _kind.isSales && canPost)
        (
          label: _voidBlocked ?? 'Void this ${_meta.singular.toLowerCase()}',
          icon: Icons.block_outlined,
          onTap: _saving || _voidBlocked != null ? null : _void,
        ),
      // A draft has never reached the ledger, so it is thrown away
      // rather than voided.
      if (!_isNew && canWrite && canDiscard(_status))
        (
          label: 'Discard',
          icon: Icons.delete_outline,
          onTap: _saving ? null : _discard,
        ),
    ];

    Widget primaryButton() {
      final p = primary!;
      final label = Text(narrow ? p.short : p.label);
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: p.icon == null
            ? FilledButton(onPressed: p.onTap, child: label)
            : FilledButton.icon(
                onPressed: p.onTap,
                icon: Icon(p.icon, size: 18),
                label: label,
              ),
      );
    }

    return [
      // The chip repeats what the posted banner already says, so it is
      // the first thing to go when space is short.
      if (!_isNew && !narrow) ...[
        StatusChip(_status),
        const SizedBox(width: 12),
      ],

      // Only once something has been taken: on a fresh quotation
      // "Pending" would be noise beside every other document in the app.
      if (!_isNew &&
          !narrow &&
          _fulfilment != 'pending' &&
          canTransfer(widget.docType)) ...[
        StatusChip(_fulfilment),
        const SizedBox(width: 12),
      ],

      // A quotation whose price has run out. `0374` refuses to transfer
      // it, and a refusal with no way through is how somebody ends up
      // voiding the quote and retyping it — so the way through is here,
      // beside the transfer that will otherwise say no.
      if (!_isNew &&
          showsValidUntil(widget.docType) &&
          quoteExpired(_validUntil))
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: TextButton.icon(
            key: const ValueKey('extend-validity'),
            icon: const Icon(Icons.event_repeat_outlined, size: 18),
            label: const Text('Extend'),
            onPressed: _saving ? null : _extendValidity,
          ),
        ),

      // Only once it exists: there is nothing to print from a form that
      // has not been saved, and a PDF of a half-typed invoice is a
      // document somebody could send.
      if (!_isNew)
        IconButton(
          tooltip: 'Download PDF',
          icon: const Icon(Icons.picture_as_pdf_outlined, size: 20),
          onPressed: _saving ? null : _downloadPdf,
        ),

      // The other end of the PDF. Sales only: `share_document` reads
      // `sales_documents`, and handing a supplier a link to their own
      // bill is not a thing anybody wants. A draft is excluded too —
      // the database refuses to share one, so the button would only
      // ever produce an error.
      if (!_isNew && _kind.isSales && _status != 'draft' && _status != 'void')
        IconButton(
          tooltip: 'Share a link',
          icon: const Icon(Icons.link, size: 20),
          onPressed: _saving
              ? null
              : () => showShareDialog(context, widget.documentId!, _docNo),
        ),

      // Queue it, send it now, or send it to a different address — and
      // read what has already gone out. Even "send now" writes the row
      // first and drains it after, so the outbox stays the record of
      // everything and the database still never waits on a provider.
      if (!_isNew && _kind.isSales && _status != 'draft' && _status != 'void')
        IconButton(
          tooltip: 'Email to the customer',
          icon: const Icon(Icons.mail_outline, size: 20),
          onPressed: _saving ? null : _emailDocument,
        ),

      // Broader than the mail button on purpose. A voided invoice cannot
      // be emailed and is exactly when somebody needs to know what went
      // out before it was voided, and a draft can still have been
      // downloaded as a PDF.
      if (!_isNew && _kind.isSales)
        IconButton(
          tooltip: 'What was sent, shared and downloaded',
          icon: const Icon(Icons.history, size: 20),
          onPressed: _saving
              ? null
              : () => showActivityDialog(context, widget.documentId!, _docNo),
        ),

      // Withholding comes off a posted bill: the certificate debits the
      // payable that posting created, so there is nothing to deduct from
      // before then. Purchases only — tax withheld from money coming in
      // is a credit against the company's own assessment, which is a
      // different thing and is not built.
      if (!_isNew && widget.docType == 'bill' && _isPosted && _status != 'void')
        IconButton(
          tooltip: 'Withhold tax',
          icon: const Icon(Icons.account_balance_outlined, size: 20),
          onPressed: _saving
              ? null
              : () async {
                  final done = await showWithholdingDialog(
                    context,
                    widget.documentId!,
                    _grandTotal,
                  );
                  if (done == true && mounted) _load();
                },
        ),

      // Crediting a posted invoice, or a posted bill. Offered here
      // rather than as a new blank credit note, because a credit note
      // that names its document can be capped at what was actually sold
      // or bought — and, for a counter sale, can tell the recipe which
      // ingredients came back. A hand-written one can do neither. See
      // 0269 for the sales side and 0376 for the purchase side.
      if (!_isNew &&
          const {'invoice', 'bill'}.contains(widget.docType) &&
          const {'posted', 'partial', 'completed'}.contains(_status))
        IconButton(
          tooltip: widget.docType == 'bill'
              ? 'Credit this bill'
              : 'Credit this invoice',
          icon: const Icon(Icons.assignment_return_outlined, size: 20),
          onPressed: _saving || !canPost ? null : _credit,
        ),

      // Only an invoice or a bill repeats, and only one that exists:
      // `create_recurring_document` refuses anything else, so offering
      // it on a quotation would be a button that only ever errors.
      if (!_isNew &&
          (widget.docType == 'invoice' || widget.docType == 'bill') &&
          _status != 'void')
        IconButton(
          tooltip: 'Repeat this document',
          icon: const Icon(Icons.event_repeat_outlined, size: 20),
          onPressed: _saving
              ? null
              : () => showRepeatDialog(context, widget.documentId!, _docNo),
        ),

      if (!narrow)
        for (final a in secondary)
          TextButton.icon(
            onPressed: a.onTap,
            icon: Icon(a.icon, size: 18),
            label: Text(a.label),
          ),

      if (primary != null) primaryButton(),

      if (narrow && secondary.isNotEmpty)
        PopupMenuButton<int>(
          tooltip: 'More',
          onSelected: (i) => secondary[i].onTap?.call(),
          itemBuilder: (_) => [
            for (var i = 0; i < secondary.length; i++)
              PopupMenuItem(
                value: i,
                enabled: secondary[i].onTap != null,
                child: Row(
                  children: [
                    Icon(secondary[i].icon, size: 18),
                    const SizedBox(width: 12),
                    Text(secondary[i].label),
                  ],
                ),
              ),
          ],
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final canPost = ref.watch(canPostProvider);
    final canWrite = ref.watch(canWriteProvider);

    // A document that has been transferred is frozen as well as posted
    // ones. Saving deletes and re-inserts the lines, which would re-key
    // them and detach the chain — migration 0082 refuses that outright,
    // so the form must not offer it. Amend the document downstream, or
    // void it, which releases the quantity.
    final transferred = _fulfilment != 'pending' && canTransfer(widget.docType);
    final editable = !_isPosted && canWrite && !transferred;

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
          actions: _actions(
            context,
            editable: editable,
            canPost: canPost,
            canWrite: canWrite,
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                child: PageBody(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Only on the sales side, only once a customer is
                      // chosen, and only when a limit was actually set.
                      if (_kind.isSales && _contactId != null && !_isPosted)
                        _CreditBanner(contactId: _contactId!),
                      // What this party already has on deposit.
                      // `deposits_held_for` calls itself "the number
                      // somebody needs before raising the invoice the
                      // deposit was taken for", and nothing read it —
                      // so the invoice went out for the full amount
                      // and somebody remembered the deposit later, or
                      // did not.
                      if (_contactId != null && !_isPosted)
                        _DepositBanner(contactId: _contactId!),
                      if (transferred && !_isPosted)
                        _TransferredBanner(status: _fulfilment),
                      // Only where a rule covers it. On a deployment
                      // where nobody has written one this never appears,
                      // which is the whole design of `0167`.
                      if (!_isPosted && _approval?['is_required'] == true)
                        _ApprovalBanner(state: _approval!),
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
                        docType: widget.docType,
                        validUntil: _validUntil,
                        deliveryDate: _deliveryDate,
                        reference: _reference,
                        supplierDocNo: _supplierDocNo,
                        editable: editable,
                        // Warning somebody that a customer has no TIN is
                        // only useful where the document is actually
                        // going to LHDN. With submission off it is a
                        // complaint about a rejection that will never
                        // happen.
                        requiresEinvoice:
                            _meta.einvoice &&
                            ref
                                    .watch(currentOrgProvider)
                                    .value
                                    ?.einvoiceEnabled ==
                                true,
                        currency: _currency,
                        baseCurrency: _base,
                        rate: _rate,
                        rateMissing: _rateMissing,
                        resolvingRate: _resolvingRate,
                        exchangeRate: _exchangeRate,
                        salespersonId: _salespersonId,
                        onSalespersonChanged: (id) {
                          setState(() => _salespersonId = id);
                          _markDirty();
                        },
                        projectCode: _projectCode,
                        departmentCode: _departmentCode,
                        onDepartmentChanged: (code) {
                          setState(() => _departmentCode = code);
                          _markDirty();
                        },
                        onProjectChanged: (code) {
                          setState(() => _projectCode = code);
                          _markDirty();
                        },
                        onCurrencyChanged: _changeCurrency,
                        onRateChanged: _onRateTyped,
                        onStoreRate: _storeRate,
                        onContactChanged: (contact) {
                          setState(() => _contactId = contact.id);
                          _markDirty();
                          // A new document takes the customer's currency;
                          // an existing one keeps what it was raised in.
                          if (_isNew && contact.currency != _currency) {
                            _changeCurrency(contact.currency);
                          }
                        },
                        onDocDate: (d) {
                          setState(() => _docDate = d);
                          _markDirty();
                          // Rates are quoted per day, so moving the date
                          // moves the rate — unless one was typed, which
                          // is a decision the date does not overrule.
                          if (!_rateOverridden) _resolveRate();
                        },
                        onDueDate: (d) {
                          setState(() => _dueDate = d);
                          _markDirty();
                        },
                        onValidUntil: (d) {
                          setState(() => _validUntil = d);
                          _markDirty();
                        },
                        onDeliveryDate: (d) {
                          setState(() => _deliveryDate = d);
                          _markDirty();
                        },
                        onTextChanged: _markDirty,
                      ),
                      const SizedBox(height: 16),
                      LineEditorCard(
                        lines: _lines,
                        editable: editable,
                        currency: _currency,
                        receiving: !_kind.isSales,
                        // Sales, and not a credit note. A bill is not
                        // revenue, so 0309 has nothing to defer on the
                        // purchase side; a credit note posts with sign
                        // -1, which 0310 makes cancel a schedule rather
                        // than start one. Everything else on the sales
                        // side qualifies — a debit note posts with sign
                        // 1 and defers like an invoice, and quotations
                        // and orders carry the period 0311 takes
                        // forward to the document that will defer it.
                        defers: _kind.isSales &&
                            widget.docType != 'credit_note',
                        // Sales only: a price level is what we charge a
                        // customer, not what a supplier charges us.
                        priceFor: _kind.isSales && _contactId != null
                            ? (itemId, quantity) => ref
                                  .read(repoProvider)!
                                  .itemPrice(
                                    itemId: itemId,
                                    contactId: _contactId,
                                    quantity: quantity,
                                  )
                            : null,
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
                        baseCurrency: _base,
                        exchangeRate: _exchangeRate,
                        notes: _notes,
                        editable: editable,
                        onNotesChanged: _markDirty,
                      ),

                      // The supplier's own paperwork, filed against the
                      // document it justifies. Purchases only: a bill is
                      // evidence somebody else produced and an auditor
                      // will ask for, where an invoice is evidence this
                      // company produced and already holds.
                      //
                      // Only once saved, because an attachment hangs off
                      // a record id and a new document has none yet.
                      if (!_isNew && !_kind.isSales) ...[
                        const SizedBox(height: 16),
                        AttachmentsCard(
                          table: 'purchase_documents',
                          recordId: widget.documentId!,
                          title: 'Supplier paperwork',
                          subtitle:
                              'The bill, delivery order or quotation '
                              'this was raised from.',
                          // Reading it fills the number, the date and the
                          // lines — which is the whole reason the paper
                          // is here rather than in a filing cabinet.
                          onExtracted: _applyScan,
                        ),
                      ],
                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

/// Where the customer stands against their credit limit.
///
/// `contacts.credit_limit` was collected and never read for the whole
/// life of this app. The point of showing it here is that the moment to
/// know somebody is at their limit is while the invoice is being typed,
/// not after it has been posted and sent.
///
/// Silent when no limit is set, when the organization has credit control
/// off, and when there is room left — a line saying "RM 8,000 available"
/// on every invoice is a line nobody reads.
/// What this party already has sitting with the company.
///
/// Shown while the document can still be changed, because the point is
/// to raise it knowing about the deposit rather than to be told
/// afterwards. Silent when there is none, which is most documents.
class _DepositBanner extends ConsumerWidget {
  const _DepositBanner({required this.contactId});

  final String contactId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final held = ref.watch(depositsHeldForProvider(contactId)).valueOrNull;
    if (held == null || held.isEmpty) return const SizedBox.shrink();

    final total = depositsHeldTotal(held);
    if (total <= 0) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Row(
            children: [
              Icon(
                Icons.savings_outlined,
                size: 20,
                color: context.colors.info,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      depositsHeldLabel(held),
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: context.colors.info,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Apply it from the Deposits screen once this is '
                      'posted — it settles against the invoice rather '
                      'than coming off the lines.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreditBanner extends ConsumerWidget {
  const _CreditBanner({required this.contactId});

  final String contactId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(customerCreditProvider(contactId)).valueOrNull;
    if (status == null) return const SizedBox.shrink();

    final control = status['control']?.toString() ?? 'warn';
    final limit = Fmt.toDouble(status['credit_limit']);
    if (control == 'off' || limit <= 0) return const SizedBox.shrink();

    final over = status['over_limit'] == true;
    final available = Fmt.toDouble(status['available']);
    // Quiet until it is close, because a warning shown every time is a
    // warning nobody sees when it matters.
    if (!over && available > limit * 0.1) return const SizedBox.shrink();

    final colour = over ? context.colors.danger : context.colors.warning;
    const blockedNote = '. Posting past it is blocked.';

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Row(
            children: [
              Icon(
                over ? Icons.credit_card_off : Icons.credit_card,
                size: 20,
                color: colour,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      over
                          ? 'Over their credit limit by '
                                '${Fmt.money(-available)}'
                          : '${Fmt.money(available)} of credit left',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: colour,
                      ),
                    ),
                    Text(
                      'Owes ${Fmt.money(Fmt.toDouble(status['outstanding']))} '
                      'against a limit of ${Fmt.money(limit)}'
                      '${control == 'block' ? blockedNote : ''}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Why the form has gone read-only on a document that was never posted.
class _TransferredBanner extends StatelessWidget {
  const _TransferredBanner({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Row(
            children: [
              Icon(Icons.arrow_forward, size: 20, color: context.colors.info),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status == 'fulfilled'
                          ? 'Taken forward in full'
                          : 'Partly taken forward',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      'Editing is closed because later documents were '
                      'built from these lines. Amend those, or void them '
                      'to release the quantity back here.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              StatusChip(status),
            ],
          ),
        ),
      ),
    );
  }
}

/// Where a document stands with the people who have to sign it.
///
/// Four states, and they are four different things to do next: nobody
/// has sent it, somebody else is holding it, *you* are holding it, or it
/// is cleared and waiting to be posted. Rendering the middle two the
/// same is how a document sits for a week on the desk of the one person
/// who could have released it in a second.
class _ApprovalBanner extends StatelessWidget {
  const _ApprovalBanner({required this.state});

  final Map<String, dynamic> state;

  @override
  Widget build(BuildContext context) {
    final approved = state['is_approved'] == true;
    final pending = state['request_id'] != null;
    final mine = state['awaiting_me'] == true;
    final who = state['awaiting_who']?.toString();

    final (title, body, colour, icon) = switch (null) {
      _ when approved => (
        'Approved',
        'The chain is complete. This can be posted.',
        context.colors.success,
        Icons.verified_outlined,
      ),
      _ when mine => (
        'Waiting for you',
        'You hold the next signature on this. Approve it from the '
            'Approvals screen.',
        context.colors.warning,
        Icons.pending_actions_outlined,
      ),
      _ when pending => (
        'Waiting for approval',
        who == null
            ? 'Sent for approval. It cannot be posted until it is signed.'
            : 'With $who. It cannot be posted until it is signed.',
        context.colors.info,
        Icons.hourglass_empty,
      ),
      _ => (
        'Needs approving',
        'A rule covers this document, so posting it will be refused '
            'until it has been signed. Send it for approval.',
        context.colors.warning,
        Icons.how_to_reg_outlined,
      ),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Row(
            children: [
              Icon(icon, size: 20, color: colour),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(body, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ],
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
                    const Text(
                      'Posted to the ledger',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
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
    required this.kind,
    required this.contactId,
    required this.docDate,
    required this.dueDate,
    required this.docType,
    required this.validUntil,
    required this.deliveryDate,
    required this.reference,
    required this.supplierDocNo,
    required this.editable,
    required this.requiresEinvoice,
    required this.currency,
    required this.baseCurrency,
    required this.rate,
    required this.rateMissing,
    required this.resolvingRate,
    required this.exchangeRate,
    required this.projectCode,
    required this.departmentCode,
    required this.salespersonId,
    required this.onSalespersonChanged,
    required this.onProjectChanged,
    required this.onDepartmentChanged,
    required this.onCurrencyChanged,
    required this.onRateChanged,
    required this.onStoreRate,
    required this.onContactChanged,
    required this.onDocDate,
    required this.onDueDate,
    required this.onValidUntil,
    required this.onDeliveryDate,
    required this.onTextChanged,
  });

  final String docNo;
  final DocKind kind;
  final String? contactId;
  final DateTime docDate;
  final DateTime? dueDate;
  final String docType;

  /// The day the price stops holding, and the day delivery was promised.
  /// Shown only on the document types that carry them — see
  /// `document_dates.dart`.
  final DateTime? validUntil;
  final DateTime? deliveryDate;
  final TextEditingController reference;
  final TextEditingController supplierDocNo;
  final bool editable;
  final bool requiresEinvoice;
  final String currency;
  final String baseCurrency;
  final TextEditingController rate;
  final bool rateMissing;
  final bool resolvingRate;
  final double? exchangeRate;
  final String? projectCode;
  final String? departmentCode;
  final String? salespersonId;
  final ValueChanged<String?> onSalespersonChanged;
  final ValueChanged<String?> onProjectChanged;
  final ValueChanged<String?> onDepartmentChanged;
  final ValueChanged<String> onCurrencyChanged;
  final ValueChanged<String> onRateChanged;
  final VoidCallback onStoreRate;
  final ValueChanged<Contact> onContactChanged;
  final ValueChanged<DateTime> onDocDate;
  final ValueChanged<DateTime> onDueDate;
  final ValueChanged<DateTime> onValidUntil;
  final ValueChanged<DateTime> onDeliveryDate;
  final VoidCallback onTextChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contacts = ref.watch(
      contactsProvider((type: kind.contactType, search: '')),
    );
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
                child: Text(
                  '${c.name} (${c.code})',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: editable
              ? (v) {
                  final picked = list.where((c) => c.id == v).firstOrNull;
                  if (picked != null) onContactChanged(picked);
                }
              : null,
        );
      },
      loading: () => const LinearProgressIndicator(),
      error: (e, _) => Text('Could not load contacts: $e'),
    );

    final isForeign = currency != baseCurrency;

    final fields = <({Widget child, int flex})>[
      (child: contactField, flex: 2),
      (
        child: _DateField(
          label: 'Document date',
          value: docDate,
          enabled: editable,
          onChanged: onDocDate,
        ),
        flex: 1,
      ),
      (
        child: _DateField(
          label: 'Due date',
          value: dueDate,
          enabled: editable,
          onChanged: onDueDate,
        ),
        flex: 1,
      ),
      // The day the price stops holding. A quotation without one is an
      // offer with no end, and `0374` will let it become an invoice at
      // last year's price for as long as anybody likes.
      if (showsValidUntil(docType))
        (
          child: _DateField(
            label: 'Valid until',
            value: validUntil,
            enabled: editable,
            onChanged: onValidUntil,
            note: validityNote(docType, validUntil),
          ),
          flex: 1,
        ),
      // What the customer was told, carried forward by the transfer onto
      // the order and the delivery order raised from it.
      if (showsDeliveryDate(docType))
        (
          child: _DateField(
            label: 'Delivery promised',
            value: deliveryDate,
            enabled: editable,
            onChanged: onDeliveryDate,
          ),
          flex: 1,
        ),
      (
        child: _CurrencyField(
          value: currency,
          baseCurrency: baseCurrency,
          enabled: editable,
          onChanged: onCurrencyChanged,
        ),
        flex: 1,
      ),
      if (isForeign)
        (
          child: _RateField(
            controller: rate,
            currency: currency,
            baseCurrency: baseCurrency,
            date: docDate,
            rate: exchangeRate,
            missing: rateMissing,
            resolving: resolvingRate,
            enabled: editable,
            onChanged: onRateChanged,
            onStore: onStoreRate,
          ),
          flex: 1,
        ),
      // Same rule as the project dropdown below: shown only once there
      // is somebody to pick. A business that does not attribute sales
      // should not be asked to on every invoice.
      if (kind.isSales &&
          (ref.watch(salespeopleProvider).valueOrNull?.isNotEmpty ?? false))
        (
          child: DropdownButtonFormField<String?>(
            value: salespersonId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Salesperson'),
            items: [
              const DropdownMenuItem(value: null, child: Text('None')),
              for (final s in ref.watch(salespeopleProvider).value ?? const [])
                DropdownMenuItem(
                  value: s['id'] as String,
                  child: Text(
                    s['name']?.toString() ?? '',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: editable ? onSalespersonChanged : null,
          ),
          flex: 1,
        ),
      // Only once projects exist. A dropdown with nothing in it on every
      // invoice is a control that teaches people to ignore controls.
      if (ref.watch(projectsProvider).valueOrNull?.isNotEmpty ?? false)
        (
          child: DropdownButtonFormField<String?>(
            value: projectCode,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Project'),
            items: [
              const DropdownMenuItem(value: null, child: Text('None')),
              for (final p in ref.watch(projectsProvider).value ?? const [])
                DropdownMenuItem(
                  value: p['code'] as String,
                  child: Text(
                    '${p['code']} · ${p['name']}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: editable ? onProjectChanged : null,
          ),
          flex: 1,
        ),
      // Same rule as the project above, and for a stronger reason: the
      // by-department P&L reads `gl_lines.department_code`, and until
      // something writes it the report is a page of zeroes. Hidden until
      // a company has defined departments, because a picker with nothing
      // in it is how people learn to skip pickers.
      if (ref.watch(departmentsProvider).valueOrNull?.isNotEmpty ?? false)
        (
          child: DropdownButtonFormField<String?>(
            value: departmentCode,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Department'),
            items: [
              const DropdownMenuItem(value: null, child: Text('None')),
              for (final d in ref.watch(departmentsProvider).value ?? const [])
                DropdownMenuItem(
                  value: d['code'] as String,
                  child: Text(
                    '${d['code']} · ${d['name']}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: editable ? onDepartmentChanged : null,
          ),
          flex: 1,
        ),
      (
        child: TextFormField(
          controller: reference,
          enabled: editable,
          onChanged: (_) => onTextChanged(),
          decoration: InputDecoration(
            labelText: kind.isSales
                ? 'Customer reference / PO no.'
                : 'Internal reference',
          ),
        ),
        flex: 2,
      ),
      if (!kind.isSales)
        (
          child: TextFormField(
            controller: supplierDocNo,
            enabled: editable,
            onChanged: (_) => onTextChanged(),
            decoration: const InputDecoration(
              labelText: 'Supplier invoice no.',
              helperText: 'Their document number, needed for SST records',
            ),
          ),
          flex: 1,
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
                      child: f.child,
                    ),
                ],
              )
            else
              for (final row in packRows([for (final f in fields) f.flex]))
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final i in row) ...[
                        if (i != row.first) const SizedBox(width: 14),
                        Expanded(flex: fields[i].flex, child: fields[i].child),
                      ],
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

/// The currency the document is quoted in.
///
/// Every organization's own currency sorts first: it is the answer
/// almost every time, and scrolling past AED and AUD to reach MYR on a
/// Malaysian invoice would be a small insult repeated all day.
class _CurrencyField extends ConsumerWidget {
  const _CurrencyField({
    required this.value,
    required this.baseCurrency,
    required this.enabled,
    required this.onChanged,
  });

  final String value;
  final String baseCurrency;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final available = ref.watch(currenciesProvider).valueOrNull ?? const [];

    final codes = [
      baseCurrency,
      for (final c in available)
        if (c.code != baseCurrency) c.code,
    ];
    // A document already in a currency that has since been deactivated
    // still has to be able to display itself.
    if (!codes.contains(value)) codes.insert(1, value);

    final names = {for (final c in available) c.code: c.name};

    return DropdownButtonFormField<String>(
      value: value,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Currency'),
      items: [
        for (final code in codes)
          DropdownMenuItem(
            value: code,
            child: Text(
              names[code] == null ? code : '$code — ${names[code]}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: enabled ? (v) => v == null ? null : onChanged(v) : null,
    );
  }
}

/// Units of base currency per unit of the document's currency.
///
/// Shown only on foreign documents, because on a ringgit invoice in a
/// ringgit company the answer is 1 and a field that can only be wrong is
/// worse than no field.
class _RateField extends StatelessWidget {
  const _RateField({
    required this.controller,
    required this.currency,
    required this.baseCurrency,
    required this.date,
    required this.rate,
    required this.missing,
    required this.resolving,
    required this.enabled,
    required this.onChanged,
    required this.onStore,
  });

  final TextEditingController controller;
  final String currency;
  final String baseCurrency;
  final DateTime date;
  final double? rate;
  final bool missing;
  final bool resolving;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final VoidCallback onStore;

  @override
  Widget build(BuildContext context) {
    final helper = switch (null) {
      _ when resolving => 'Looking up the rate…',
      _ when rate == null =>
        'No rate on file for ${Fmt.date(date)} — enter one',
      _ => rateCaption(
        currency: currency,
        baseCurrency: baseCurrency,
        rate: rate!,
      ),
    };

    return TextFormField(
      controller: controller,
      enabled: enabled,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: 'Exchange rate',
        helperText: helper,
        helperMaxLines: 2,
        helperStyle: rate == null && !resolving
            ? TextStyle(color: context.colors.warning)
            : null,
        // Offered whenever there is a rate to keep, so a rate typed for
        // one invoice does not have to be typed again for the next.
        suffixIcon: !enabled || rate == null || resolving
            ? null
            : IconButton(
                tooltip: 'Save as the rate for ${Fmt.date(date)}',
                icon: Icon(
                  missing ? Icons.bookmark_add_outlined : Icons.save_outlined,
                  size: 18,
                ),
                onPressed: onStore,
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
    this.note,
  });

  final String label;
  final DateTime? value;
  final bool enabled;
  final ValueChanged<DateTime> onChanged;

  /// What the date means, where it means something worth saying. Null on
  /// the ordinary case so a healthy document carries no chatter.
  final String? note;

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
          helperText: note,
          helperMaxLines: 3,
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
    required this.baseCurrency,
    required this.exchangeRate,
    required this.notes,
    required this.editable,
    required this.onNotesChanged,
  });

  final double subtotal;
  final double tax;
  final double total;
  final double rounding;
  final String currency;
  final String baseCurrency;
  final double? exchangeRate;
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
            // What the ledger will actually carry. Shown because the
            // whole document is quoted in the customer's currency and
            // the books are not, and the difference between the two is
            // the only figure an accountant can reconcile against.
            if (currency != baseCurrency && exchangeRate != null) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  '${Fmt.money(total * exchangeRate!, currency: baseCurrency)} '
                  'at ${Fmt.rate(exchangeRate)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ],
        ),
      ),
    );

    if (narrow) {
      return Column(
        children: [totalsCard, const SizedBox(height: 16), notesCard],
      );
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
