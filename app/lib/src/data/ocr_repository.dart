import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/format.dart';
import 'attachments_repository.dart' show RepoAttachments;
import 'repository.dart';

/// One reader on offer, as the platform has it configured.
class OcrProvider {
  const OcrProvider({
    required this.code,
    required this.name,
    required this.price,
    required this.takesKey,
    required this.runsOnDevice,
    required this.ready,
    this.isActive = true,
    this.blurb,
  });

  final String code;
  final String name;
  final double price;

  /// False for the on-device reader, which has no key for anybody to
  /// bring — so the "my own key" choice is not offered for it.
  final bool takesKey;
  final bool runsOnDevice;

  /// Whether the platform has finished setting it up. A reader whose
  /// model has not been chosen is listed and refused rather than hidden,
  /// so an administrator can see it exists and ask for it.
  final bool ready;

  /// Whether the platform still offers it. `ocr_status` lists the active
  /// readers PLUS the one this company is on, so a false here means
  /// exactly one thing: your company is on a reader that has been
  /// retired since you chose it, and nothing will scan until you pick
  /// another. 0678.
  final bool isActive;
  final String? blurb;

  factory OcrProvider.fromJson(Map<String, dynamic> j) => OcrProvider(
        code: j['code'].toString(),
        name: j['name']?.toString() ?? j['code'].toString(),
        price: OcrSettings._num(j['price']),
        takesKey: j['takes_key'] != false,
        runsOnDevice: j['runs_on_device'] == true,
        ready: j['ready'] != false,
        isActive: j['is_active'] != false,
        blurb: (j['blurb']?.toString().trim().isEmpty ?? true)
            ? null
            : j['blurb'].toString().trim(),
      );
}

/// The platform's default reader, and what it is doing.
///
/// One row, two jobs. It is what a company that has chosen nothing is
/// handed — and, WHEN IT IS FREE, it is also what a failed scan is
/// retried on. The second is conditional on the first, which is why
/// this is a small object rather than a code: a console showing only
/// the name cannot say that setting a chargeable default has silently
/// left the platform with no fallback at all. 0679.
class OcrDefaultState {
  const OcrDefaultState({
    required this.provider,
    required this.name,
    required this.price,
    required this.isFree,
    required this.isFallback,
    required this.runsOnDevice,
  });

  final String provider;
  final String name;
  final double price;
  final bool isFree;

  /// Whether a scan that failed on the company's own reader is retried
  /// on this one. Free, active, and able to run on a server.
  final bool isFallback;
  final bool runsOnDevice;

  static const none = OcrDefaultState(
    provider: '',
    name: '',
    price: 0,
    isFree: false,
    isFallback: false,
    runsOnDevice: false,
  );

  factory OcrDefaultState.fromJson(Map<String, dynamic> j) => OcrDefaultState(
    provider: j['provider']?.toString() ?? '',
    name: j['name']?.toString() ?? j['provider']?.toString() ?? '',
    price: OcrSettings._num(j['price']),
    isFree: j['is_free'] == true,
    isFallback: j['is_fallback'] == true,
    runsOnDevice: j['runs_on_device'] == true,
  );
}

/// What an organization has chosen about reading its own paperwork.
///
/// Off is the default and there is no row until somebody turns it on, so
/// every field here has a sensible answer for an organization that has
/// never opened the setting.
class OcrSettings {
  const OcrSettings({
    required this.enabled,
    required this.provider,
    required this.keySource,
    required this.hasOwnKey,
    required this.keys,
    required this.balance,
    required this.price,
    this.providers = const [],
    this.defaultProvider,
    this.chosen = false,
    this.fallback,
    this.fallbackName,
    this.hasModule = true,
  });

  final bool enabled;

  /// A code off the `ocr_providers` catalog. Not an enum on purpose:
  /// the platform adds readers without an app release, so the app has
  /// to be able to show one it has never heard of.
  final String provider;

  /// `platform` — drawn from purchased credit — `own`, or `device`,
  /// which means no key and no charge.
  final String keySource;

  /// Whether a key is on file for the currently chosen provider.
  final bool hasOwnKey;

  /// Which providers hold a key, so switching one does not silently
  /// strand the organization on a provider it has nothing to call.
  final Set<String> keys;

  /// Ringgit remaining. Only spent when [keySource] is `platform`.
  final double balance;

  /// Ringgit per scan at the current provider, as set by the platform.
  final double price;

  /// Every reader on offer. Comes off a table rather than a constant, so
  /// the platform can add one without an app release.
  final List<OcrProvider> providers;

  /// The reader the platform hands to a company that has never chosen
  /// one. Null only from an older database that does not send it.
  final String? defaultProvider;

  /// The free reader a failed scan is retried on, and its name.
  ///
  /// Null when there is none — the platform's default is this
  /// company's own reader, or is chargeable, or runs on the device.
  /// The database applies the same test `ocr_fallback` does, so a
  /// sentence drawn from this cannot promise a retry that would not
  /// happen. 0679.
  final String? fallback;
  final String? fallbackName;

  /// Whether the `smartscan` module is switched on for this company.
  ///
  /// `0682` made scanning a module of its own. Until then it was a
  /// SETTING any administrator could turn on, and it is the most
  /// expensive thing in this product per use — every scan is a call to
  /// somebody else's model.
  ///
  /// Defaults to true so an older database, which does not send it,
  /// draws the card as it always did rather than telling everybody
  /// their module is off.
  final bool hasModule;

  /// Whether THIS company ever picked a reader, as opposed to being
  /// shown the platform's default.
  ///
  /// The distinction is the whole of `0678`. Until then the default was
  /// the literal `'claude'` inside `ocr_status`, so a company that had
  /// never opened this screen was indistinguishable from one that had
  /// deliberately chosen Claude — and when Claude was retired in the
  /// console, both were handed a reader the save would refuse.
  final bool chosen;

  OcrProvider? get current =>
      providers.where((p) => p.code == provider).firstOrNull;

  static const off = OcrSettings(
    enabled: false,
    provider: 'claude',
    keySource: 'platform',
    hasOwnKey: false,
    keys: {},
    balance: 0,
    price: 0,
  );

  /// True when a scan would be refused for want of money. An
  /// organization on its own key, or on the device, never runs out.
  bool get outOfCredit =>
      enabled && keySource == 'platform' && price > 0 && balance < price;

  /// Whether the chosen reader runs in the app rather than on a server.
  bool get onDevice => current?.runsOnDevice ?? (provider == 'mlkit');

  /// The company is on a reader the platform no longer offers.
  ///
  /// Nothing will scan and the save will be refused, so the screen has
  /// to show the reader list whether or not scanning is switched on —
  /// until `0678` that list was drawn only when it was ON, and turning
  /// it on was the call that failed. A company could not reach the
  /// control that fixes it from any screen it had.
  bool get retired => current != null && !current!.isActive;

  /// Whether the reader list must be drawn although scanning is OFF.
  ///
  /// The one case, and the fix for the reported bug. Every scanning
  /// control lived inside `if (ocr.enabled)`; a company whose reader
  /// had been retired could not switch scanning on, because the save
  /// refuses a retired reader, so the only way to change the reader
  /// was through the door the reader had locked.
  bool get mustChooseAnother => !enabled && retired;

  /// Roughly how many more scans the balance buys.
  int get scansLeft =>
      price <= 0 ? 0 : (balance / price).floor();

  factory OcrSettings.fromJson(Map<String, dynamic> j) => OcrSettings(
        enabled: j['enabled'] == true,
        provider: j['provider']?.toString() ?? 'claude',
        keySource: j['key_source']?.toString() ?? 'platform',
        hasOwnKey: j['has_own_key'] == true,
        keys: ((j['keys'] as Map?) ?? const {})
            .entries
            .where((e) => e.value == true)
            .map((e) => e.key.toString())
            .toSet(),
        balance: _num(j['balance']),
        price: _num(j['price']),
        providers: ((j['providers'] as List?) ?? const [])
            .whereType<Map>()
            .map((p) => OcrProvider.fromJson(Map<String, dynamic>.from(p)))
            .toList(),
        defaultProvider: j['default_provider']?.toString(),
        chosen: j['chosen'] == true,
        fallback: j['fallback']?.toString(),
        fallbackName: j['fallback_name']?.toString(),
        hasModule: j['has_module'] != false,
      );

  static double _num(Object? v) =>
      v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
}

/// One line off a scanned document.
class OcrLine {
  const OcrLine({this.description, this.quantity, this.unitPrice, this.amount});

  final String? description;
  final double? quantity;
  final double? unitPrice;
  final double? amount;

  factory OcrLine.fromJson(Map<String, dynamic> j) => OcrLine(
        description: j['description']?.toString(),
        quantity: OcrExtraction._num(j['quantity']),
        unitPrice: OcrExtraction._num(j['unit_price']),
        amount: OcrExtraction._num(j['amount']),
      );
}

/// What was read off a receipt or a bill.
///
/// Every field is nullable, and that is the point: "the tax number is not
/// printed on this receipt" is a useful answer and a zero is not.
/// Folds a reader's continuation rows back into the item above them.
///
/// A charge often takes more than one printed line — the item on the
/// first, a part number or a period covered on the second — and a reader
/// asked for "one entry per printed line" hands back two rows, the
/// second carrying a description and no money at all.
///
/// Left alone, that second row becomes a line on somebody's bill at
/// quantity one and price zero: a phantom charge with the real charge's
/// detail in it. Dropping it instead loses what they are being charged
/// for. Neither is right, so it is folded into the description above it,
/// which is where the paper put it.
///
/// A row with no money and **nothing above it** is kept as a line of its
/// own: it may be a genuine item whose price the reader could not make
/// out, and inventing a rule that swallows the first line of a document
/// would be worse than the problem.
///
/// This runs whatever the reader was. The prompt asks for the right
/// shape; this is what makes the wrong shape harmless, and a reader
/// swapped for another next year does not get to reintroduce the bug.
List<OcrLine> foldOcrContinuations(List<OcrLine> lines) {
  final out = <OcrLine>[];
  for (final line in lines) {
    final text = (line.description ?? '').trim();
    final hasMoney =
        (line.unitPrice != null && line.unitPrice != 0) ||
        (line.amount != null && line.amount != 0) ||
        (line.quantity != null && line.quantity != 0);

    if (text.isEmpty) {
      // Nothing printed and nothing charged. Not a line and not a
      // continuation of one.
      if (hasMoney) out.add(line);
      continue;
    }

    if (!hasMoney && out.isNotEmpty) {
      final above = out.removeLast();
      out.add(
        OcrLine(
          description: '${(above.description ?? '').trim()}\n$text',
          quantity: above.quantity,
          unitPrice: above.unitPrice,
          amount: above.amount,
        ),
      );
      continue;
    }

    out.add(line);
  }
  return out;
}

class OcrExtraction {
  const OcrExtraction({
    this.supplierName,
    this.supplierTaxId,
    this.supplierRegistrationNo,
    this.supplierEmail,
    this.supplierPhone,
    this.supplierAddress,
    this.documentNo,
    this.documentDate,
    this.currency,
    this.subtotal,
    this.taxAmount,
    this.totalAmount,
    this.lines = const [],
    this.note,
    this.rawText,
    this.documentKind,
    this.target,
    this.fields = const {},
    this.rows = const [],
  });

  final String? supplierName;

  /// The TIN — LHDN's number, the one an e-Invoice is validated against.
  final String? supplierTaxId;

  /// The SSM number, which is not the same thing and is printed far more
  /// often. Malaysian companies carry two: the twelve-digit one issued
  /// since 2019 and the older `571389-H` form, and a letterhead usually
  /// shows both. Whichever is printed is worth keeping — it is what
  /// identifies the company at the registry.
  final String? supplierRegistrationNo;

  final String? supplierEmail;
  final String? supplierPhone;

  /// The whole address as printed, newlines and all. Not split into
  /// street, city and postcode here: a Malaysian address on a receipt
  /// runs to four lines in no fixed order, and guessing which line is
  /// the city would put wrong data in a field that looks authoritative.
  final String? supplierAddress;

  final String? documentNo;
  final DateTime? documentDate;
  final String? currency;
  final double? subtotal;
  final double? taxAmount;
  final double? totalAmount;
  final List<OcrLine> lines;

  /// Whatever a bookkeeper should check by hand — an unreadable figure,
  /// a total that does not foot.
  final String? note;

  /// Everything the reader saw, in the order it was printed.
  ///
  /// The fields above are what the reading *made of* the document; this
  /// is the document. It is what "All data" shows, so a figure the
  /// parser passed over can still be put in the right box by the person
  /// holding the paper.
  ///
  /// Null where the reader answers with fields and not with text — the
  /// two LLM readers do, and being honest about that beats showing an
  /// empty page that looks like a failure.
  final String? rawText;

  /// What KIND of paper this is, as a `scan_document_kinds.code`.
  ///
  /// `0614`. Guessed by `document_classifier.dart` from [rawText] and
  /// confirmable by the person holding the paper — the fields above are
  /// what the reading made of the document, and this is what the
  /// document is. Null where nobody was asked, which is every reading
  /// taken before 0614 and every one where the list had not loaded.
  final String? documentKind;

  /// Where the reader decided this document goes, as `module.action`.
  ///
  /// Not the same question as [documentKind], and a stronger answer.
  /// `documentKind` is what the app's own classifier made of the text
  /// afterwards — string matching against letterheads, in Dart. This is
  /// the reader's own judgement, made while it had the page in front of
  /// it and a list of the destinations this platform has configured.
  ///
  /// Null where the platform has configured none, which is every
  /// reading before `0681`, and null where the reader could not place
  /// the document — which it is told to say rather than guess, because
  /// a document filed wrongly becomes a record somebody has to find and
  /// undo.
  final String? target;

  /// What it read for that destination's fields, keyed by column name.
  ///
  /// Strings, all of them, and deliberately. The schema asks for what is
  /// PRINTED, and `03/09/2026` on a Malaysian receipt is not a date
  /// until somebody who knows the column decides which way round it is.
  /// Coercion belongs where the column is known.
  final Map<String, String> fields;

  /// One entry per printed line, where the destination takes rows.
  ///
  /// A bank statement is forty records, not one: a date, a description,
  /// an amount and a balance, the same four on every line. `0681`
  /// deliberately left statements out for exactly this reason and
  /// `0682` is the answer — a target marked `repeats` asks the reader
  /// for an array instead of an object.
  ///
  /// Empty for every other document, which is almost all of them.
  final List<Map<String, String>> rows;

  /// The same reading with some of it changed.
  ///
  /// Only ever sets; it cannot put a field back to null, which is what
  /// the assignment screen needs and all it needs. Clearing a field is
  /// done in the form, where the box can simply be emptied.
  OcrExtraction copyWith({
    String? supplierName,
    String? supplierTaxId,
    String? supplierRegistrationNo,
    String? supplierEmail,
    String? supplierPhone,
    String? supplierAddress,
    String? documentNo,
    DateTime? documentDate,
    String? currency,
    double? subtotal,
    double? taxAmount,
    double? totalAmount,
    List<OcrLine>? lines,
    String? note,
    String? rawText,
    String? documentKind,
    String? target,
    Map<String, String>? fields,
    List<Map<String, String>>? rows,
  }) =>
      OcrExtraction(
        supplierName: supplierName ?? this.supplierName,
        supplierTaxId: supplierTaxId ?? this.supplierTaxId,
        supplierRegistrationNo:
            supplierRegistrationNo ?? this.supplierRegistrationNo,
        supplierEmail: supplierEmail ?? this.supplierEmail,
        supplierPhone: supplierPhone ?? this.supplierPhone,
        supplierAddress: supplierAddress ?? this.supplierAddress,
        documentNo: documentNo ?? this.documentNo,
        documentDate: documentDate ?? this.documentDate,
        currency: currency ?? this.currency,
        subtotal: subtotal ?? this.subtotal,
        taxAmount: taxAmount ?? this.taxAmount,
        totalAmount: totalAmount ?? this.totalAmount,
        lines: lines ?? this.lines,
        note: note ?? this.note,
        rawText: rawText ?? this.rawText,
        documentKind: documentKind ?? this.documentKind,
        target: target ?? this.target,
        fields: fields ?? this.fields,
        rows: rows ?? this.rows,
      );

  /// The amount to put in an expense's Amount field.
  ///
  /// The net, because the tax goes in its own box and the form adds the
  /// two back together. Where the document shows only one figure, that
  /// figure is the amount and there is no tax to separate.
  double? get netAmount => subtotal ?? totalAmount;

  factory OcrExtraction.fromJson(Map<String, dynamic> j) => OcrExtraction(
        supplierName: _text(j['supplier_name']),
        supplierTaxId: _text(j['supplier_tax_id']),
        supplierRegistrationNo: _text(j['supplier_registration_no']),
        supplierEmail: _text(j['supplier_email']),
        supplierPhone: _text(j['supplier_phone']),
        supplierAddress: _text(j['supplier_address']),
        documentNo: _text(j['document_no']),
        documentDate: DateTime.tryParse(_text(j['document_date']) ?? ''),
        // Upper-cased here as well as on the way out of the reader: a
        // currency is compared against ISO codes elsewhere, and `myr`
        // matching nothing is a silent wrong answer rather than an error.
        currency: _text(j['currency'])?.toUpperCase(),
        subtotal: _num(j['subtotal']),
        taxAmount: _num(j['tax_amount']),
        totalAmount: _num(j['total_amount']),
        lines: ((j['lines'] as List?) ?? const [])
            .whereType<Map>()
            .map((r) => OcrLine.fromJson(Map<String, dynamic>.from(r)))
            .toList(),
        note: _text(j['note']),
        rawText: _text(j['raw_text']),
        documentKind: _text(j['document_kind']),
        target: _text(j['target']),
        fields: {
          for (final e in ((j['fields'] as Map?) ?? const {}).entries)
            if (_text(e.value) != null) '${e.key}': _text(e.value)!,
        },
        rows: [
          for (final r in ((j['rows'] as List?) ?? const []))
            if (r is Map)
              {
                for (final e in r.entries)
                  if (_text(e.value) != null) '${e.key}': _text(e.value)!,
              },
        ]..removeWhere((r) => r.isEmpty),
      );

  /// The same shape the server-side readers return, so a scan logged
  /// from the phone and one logged from Claude read alike afterwards.
  Map<String, dynamic> toJson() => {
        'supplier_name': supplierName,
        'supplier_tax_id': supplierTaxId,
        'supplier_registration_no': supplierRegistrationNo,
        'supplier_email': supplierEmail,
        'supplier_phone': supplierPhone,
        'supplier_address': supplierAddress,
        'document_no': documentNo,
        'document_date': documentDate == null
            ? null
            : '${documentDate!.year.toString().padLeft(4, '0')}-'
                '${documentDate!.month.toString().padLeft(2, '0')}-'
                '${documentDate!.day.toString().padLeft(2, '0')}',
        'currency': currency,
        'subtotal': subtotal,
        'tax_amount': taxAmount,
        'total_amount': totalAmount,
        'lines': [
          for (final l in lines)
            {
              'description': l.description,
              'quantity': l.quantity,
              'unit_price': l.unitPrice,
              'amount': l.amount,
            },
        ],
        'note': note,
        'raw_text': rawText,
        'document_kind': documentKind,
        'target': target,
        // Omitted when empty rather than written as `{}`: a scan taken
        // on a phone, or on a platform with no targets configured, has
        // no answer here, and a stored `{}` reads as "the reader was
        // asked and found nothing" when it was never asked.
        if (fields.isNotEmpty) 'fields': fields,
        if (rows.isNotEmpty) 'rows': rows,
      };

  static String? _text(Object? v) {
    final s = v?.toString().trim() ?? '';
    return s.isEmpty ? null : s;
  }

  static double? _num(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }
}

/// Reading paperwork, and paying for having read it.
///
/// Nothing here decides whether a scan may happen — `ocr_begin` in the
/// database does, under the caller's own token, and the edge function
/// cannot talk it round. What the app gets is the answer and a readable
/// refusal.
extension RepoOcr on Repo {
  Future<OcrSettings> ocrStatus() async {
    final data = await client.rpc('ocr_status', params: {'p_org_id': orgId});
    if (data is! Map) return OcrSettings.off;
    return OcrSettings.fromJson(Map<String, dynamic>.from(data));
  }

  /// Moves the switch, and optionally the reader or whose key it uses.
  ///
  /// Both are nullable and null means "leave it alone", which is what
  /// lets the switch be moved without naming a reader. `0678`: naming
  /// one was the bug. The screen echoed back the provider `ocr_status`
  /// had handed it, that provider was the literal `'claude'` for any
  /// company that had never chosen, and once Claude was retired in the
  /// console the echo came back as `Claude is not available` — the
  /// screen asking for something it had never been asked to want.
  Future<void> setOcrSettings({
    required bool enabled,
    String? provider,
    String? keySource,
  }) =>
      client.rpc('set_ocr_settings', params: {
        'p_org_id': orgId,
        'p_enabled': enabled,
        'p_provider': provider,
        'p_key_source': keySource,
      });

  /// Leave a field null to keep what is stored, which is what makes
  /// correcting a processor id safe without re-pasting the key.
  Future<void> setOcrCredentials({
    required String provider,
    String? apiKey,
    String? projectId,
    String? location,
    String? processorId,
  }) =>
      client.rpc('set_ocr_credentials', params: {
        'p_org_id': orgId,
        'p_provider': provider,
        'p_api_key': apiKey,
        'p_project_id': projectId,
        'p_location': location,
        'p_processor_id': processorId,
      });

  Future<void> clearOcrCredentials(String provider) =>
      client.rpc('clear_ocr_credentials', params: {
        'p_org_id': orgId,
        'p_provider': provider,
      });

  /// Reads an attachment that has already been filed.
  ///
  /// The charge is taken by the database before the provider is called
  /// and given back if the call fails, so a thrown exception here means
  /// nothing was spent.
  Future<OcrExtraction> scanAttachment(String attachmentId) async {
    final res = await client.functions.invoke('ocr', body: {
      'org_id': orgId,
      'attachment_id': attachmentId,
    });
    final data = res.data;
    if (data is Map && data['error'] != null) {
      throw OcrException(data['error'].toString());
    }
    final body = Map<String, dynamic>.from(data as Map);
    return OcrExtraction.fromJson(
        Map<String, dynamic>.from(body['extraction'] as Map));
  }

  /// Records a reading that happened on the phone.
  ///
  /// The on-device reader never touches the edge function, so there is
  /// no `ocr_begin`/`ocr_finish` pair around it — and no charge, which
  /// is why this one is safe for an ordinary user to call where
  /// `ocr_finish` deliberately is not. The row is written settled.
  Future<void> recordLocalScan({
    required String attachmentId,
    OcrExtraction? read,
    String? error,
  }) =>
      client.rpc('ocr_record_local', params: {
        'p_org_id': orgId,
        'p_attachment_id': attachmentId,
        'p_extracted': read?.toJson(),
        'p_error': error,
      });

  /// Files the most recent scan of an attachment as a kind of document.
  ///
  /// `0614`. Separate from the reading because the kind is settled
  /// AFTER it: by the time somebody has looked at the dialog the scan
  /// row exists, written by `ocr_finish` or by `ocr_record_local`.
  ///
  /// Answers null where there was no scan to write on — a capture
  /// nobody read still reaches this with whatever the form said — which
  /// is why it is not an error.
  Future<String?> setScanDocumentKind({
    required String attachmentId,
    String? kind,
  }) async {
    final out = await client.rpc('set_scan_document_kind', params: {
      'p_org_id': orgId,
      'p_attachment_id': attachmentId,
      'p_document_kind': kind,
    });
    return out?.toString();
  }

  /// Records that somebody accepted a reading, and what they changed.
  ///
  /// `0684`. Returns the names of the fields that differed — empty
  /// where the reader was right, null where there was no scan to write
  /// on (an on-device capture that was never read still reaches here).
  ///
  /// The corrected reading is the only ground truth this system
  /// produces. It arrives free, from somebody holding the paper, and
  /// before this it was handed to the form and dropped.
  Future<List<String>?> noteScanCorrection({
    required String attachmentId,
    required OcrExtraction accepted,
  }) async {
    // `callRpc` rather than `client.rpc`: it notes a 42501 the way the
    // rest of Repo does, and — the reason this matters here — it is on
    // the CLASS, so a test double can intercept it. This method is on
    // `extension RepoOcr`, and an extension method binds to the static
    // type, so a fake that declared it would never be called and the
    // real body would run against the fake's client.
    // See docs/widget-tests.md.
    final out = await callRpc('ocr_note_correction', params: {
      'p_org_id': orgId,
      'p_attachment_id': attachmentId,
      'p_accepted': accepted.toJson(),
    });
    if (out == null) return null;
    return [for (final f in out as List) f.toString()];
  }

  /// Per reader: how many readings a person checked, how many they had
  /// to change, and the field each gets wrong most. `0684`.
  Future<List<Map<String, dynamic>>> platformScanAccuracy({
    int days = 90,
  }) async =>
      Repo.rows(
          await callRpc('platform_scan_accuracy', params: {'p_days': days}));

  /// Every movement of the scanning balance, newest first.
  Future<List<Map<String, dynamic>>> creditLedger() async => Repo.rows(
      await client
          .from('credit_ledger')
          .select()
          .eq('org_id', orgId)
          .order('created_at', ascending: false)
          .limit(200));

  /// The invoices the platform has raised for credit sold to us.
  Future<List<Map<String, dynamic>>> creditInvoices() async => Repo.rows(
      await client
          .from('platform_invoices')
          .select()
          .eq('org_id', orgId)
          .order('issue_date', ascending: false));

  /// Where to send somebody to pay one of them.
  ///
  /// The function raises a bill with Billplz and records it; what comes
  /// back is Billplz's own page, which is where the card details are
  /// typed. None of that touches this app — the whole point of a hosted
  /// checkout is that a card number never reaches our origin.
  ///
  /// Nothing here decides whether the invoice is payable, or for how
  /// much. `billplz-checkout` reads the invoice through the caller's own
  /// token so RLS decides whether it is theirs, and 0297 decides the
  /// rest. A button that checked first would only be a second opinion.
  Future<String> startInvoiceCheckout(String invoiceId) async {
    final res = await client.functions.invoke(
      'billplz-checkout',
      body: {'invoice_id': invoiceId},
    );
    final data = res.data;
    if (data is Map && data['error'] != null) {
      throw Exception(data['error'].toString());
    }
    final url = (data as Map)['url'];
    if (url is! String || url.isEmpty) {
      throw Exception('The gateway did not say where to send you.');
    }
    return url;
  }

  /// What has been tried against those invoices, and how it went.
  ///
  /// A company can read its own payments — 0297's policy — so a bill
  /// somebody started and abandoned shows as pending rather than as
  /// nothing at all.
  Future<List<Map<String, dynamic>>> invoicePayments() async => Repo.rows(
      await client
          .from('platform_payments')
          .select('invoice_id, state, amount, paid_amount, checkout_url, created_at')
          .eq('org_id', orgId)
          .order('created_at', ascending: false));

  /// Files a scanned capture against the record it turned out to be for.
  ///
  /// A receipt is photographed before the expense exists — that is the
  /// whole point of scanning it — so the capture is filed against a
  /// placeholder and moved once the expense has an id. The object moves
  /// as well as the row: the storage policies read the organization, the
  /// table and the record straight out of the object name, and a trigger
  /// refuses a row whose path does not match its own columns, so a row
  /// repointed on its own would simply be rejected.
  Future<void> refileAttachment({
    required String attachmentId,
    required String table,
    required String recordId,
  }) async {
    final row = await client
        .from('attachments')
        .select('storage_path')
        .eq('id', attachmentId)
        .single();
    final from = row['storage_path'].toString();
    final to = '$orgId/$table/$recordId/${from.split('/').last}';
    if (from == to) return;

    await client.storage.from(RepoAttachments.bucket).move(from, to);
    await client.from('attachments').update({
      'entity_table': table,
      'entity_id': recordId,
      'storage_path': to,
    }).eq('id', attachmentId);
  }
}

/// A scan that did not happen, with the reason the database or the
/// provider gave. Nothing was charged.
class OcrException implements Exception {
  OcrException(this.message);

  final String message;

  @override
  String toString() => message;
}


/// Editing the reader catalog.
///
/// 0113 wrote `platform_set_ocr_provider` because the console already
/// edits `platform_settings` as loose JSON and a reader has a shape
/// worth naming. Nothing ever called it, so adding a reader, correcting
/// a price or retiring one has meant hand-written SQL against
/// production.
///
/// The catalog itself was never invisible — `ocr_status` carries it to
/// the tenant settings screen, which is why a company can pick a reader
/// the app has never heard of. It is only the editing that had no way
/// in.
/// Hangs off the platform and not off a company, for the same reason
/// the AI catalogue does: a reader is the platform's, neither call
/// takes an org id, and written `on Repo` this screen refused the
/// operator it exists for with "Your company has not finished loading".
extension PlatformOcrCatalog on PlatformRepo {
  /// Every reader, active or not. The platform view rather than the
  /// tenant one: a retired reader still matters to whoever retired it.
  Future<List<Map<String, dynamic>>> ocrProviderCatalog() async => Repo.rows(
    await client
        .from('ocr_providers')
        .select(
          'code, name, kind, endpoint, model, price, takes_key, '
          'runs_on_device, blurb, is_active',
        )
        .order('code', ascending: true),
  );

  /// Adds a reader or edits one.
  ///
  /// Null leaves what is stored alone, which is the whole reason this
  /// is an RPC and not an update: correcting a price must not blank the
  /// endpoint. So only the fields actually edited are sent, and the
  /// ones left untouched are omitted rather than sent as null-meaning-
  /// empty.
  Future<void> setOcrProvider(
    String code, {
    String? name,
    String? kind,
    String? endpoint,
    String? model,
    double? price,
    bool? isActive,
    String? blurb,
  }) async => await client.rpc(
    'platform_set_ocr_provider',
    params: {
      'p_code': code,
      if (name != null) 'p_name': name,
      if (kind != null) 'p_kind': kind,
      if (endpoint != null) 'p_endpoint': endpoint,
      if (model != null) 'p_model': model,
      if (price != null) 'p_price': price,
      if (isActive != null) 'p_is_active': isActive,
      if (blurb != null) 'p_blurb': blurb,
    },
  );

  /// Which reader a company that has never chosen one is offered, and
  /// whether it is also the one a failed scan retries on.
  ///
  /// Resolved rather than raw: if the reader named in the setting has
  /// since been retired, this describes the one companies are ACTUALLY
  /// being given, which is the question an operator looking at the
  /// dropdown is asking.
  Future<OcrDefaultState> ocrDefaultState() async {
    final data = await client.rpc('ocr_default_state');
    return OcrDefaultState.fromJson(
      data is Map ? Map<String, dynamic>.from(data) : const {},
    );
  }

  /// Chooses it. Refused if the reader is switched off or has no model,
  /// so the default can never name something the tenant's own save
  /// would then refuse — which is the failure `0678` was written for.
  Future<void> setDefaultOcrProvider(String code) async =>
      await client.rpc(
        'platform_set_default_ocr_provider',
        params: {'p_code': code},
      );

  /// Every scan, newest first, with the reason the failed ones failed.
  ///
  /// The reason is deliberately absent from what the person scanning
  /// is shown — a vendor's message quotes the project and the
  /// processor — so this is the only place in the product it can be
  /// read. Until `0680` there was no such place: `ocr_scans` had no
  /// reader in the app at all, and "quote this reference if you get in
  /// touch" resolved to hand-written SQL against production.
  Future<List<ScanLogEntry>> scanLog({
    int limit = 50,
    String? status,
    String? search,
  }) async => Repo.rows(
    await client.rpc(
      'platform_scan_log',
      params: {
        'p_limit': limit,
        'p_status': status,
        'p_search': search,
      },
    ),
  ).map(ScanLogEntry.fromJson).toList();

  /// Read today, failed today, and the ones that never settled.
  Future<ScanHealth> scanHealth() async {
    final data = await client.rpc('platform_scan_health');
    return ScanHealth.fromJson(
      data is Map ? Map<String, dynamic>.from(data) : const {},
    );
  }

  /// Per reader and distinct fault, worst first. `0685`.
  Future<List<ReaderFault>> readerFailures({int days = 30}) async =>
      Repo.rows(await client
              .rpc('platform_reader_failures', params: {'p_days': days}))
          .map(ReaderFault.fromJson)
          .toList();
}

/// One reader, one thing it keeps saying.
///
/// `0685`. [read] and [failed] are the READER's totals over the window
/// and repeat down every one of its rows, which is the whole point:
/// `read == 0` beside a `failed` of forty-seven is a reader somebody
/// switched on, has been paying for, and which has never once worked.
/// Without those two numbers on the row it reads as forty-seven
/// individually unremarkable failures.
class ReaderFault {
  const ReaderFault({
    required this.provider,
    required this.providerName,
    required this.read,
    required this.failed,
    required this.fault,
    required this.n,
    this.firstSeen,
    this.lastSeen,
    this.exampleRef,
  });

  final String provider;
  final String providerName;
  final int read;
  final int failed;

  /// The vendor's message with the parts that differ per request taken
  /// out — ids, hex blobs, long numbers, long quoted payload
  /// fragments. A short quoted name is KEPT: `Unknown name "strict"`
  /// is the fault, not noise.
  final String fault;
  final int n;
  final DateTime? firstSeen;
  final DateTime? lastSeen;

  /// One reference, so the whole row can be found in the log below.
  final String? exampleRef;

  /// Switched on, paid for, and has never returned a reading.
  bool get neverWorked => read == 0 && failed > 0;

  static int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

  factory ReaderFault.fromJson(Map<String, dynamic> j) => ReaderFault(
        provider: '${j['provider'] ?? ''}',
        providerName: '${j['provider_name'] ?? j['provider'] ?? ''}',
        read: _int(j['read']),
        failed: _int(j['failed']),
        fault: '${j['fault'] ?? ''}',
        n: _int(j['n']),
        firstSeen: DateTime.tryParse('${j['first_seen']}'),
        lastSeen: DateTime.tryParse('${j['last_seen']}'),
        exampleRef: j['example_ref'] as String?,
      );
}

/// One scan, as the console is allowed to see it.
class ScanLogEntry {
  const ScanLogEntry({
    required this.id,
    required this.createdAt,
    required this.orgName,
    required this.providerName,
    required this.keySource,
    required this.status,
    required this.charged,
    required this.refunded,
    this.logRef,
    this.finishedAt,
    this.fellBackTo,
    this.fileName,
    this.error,
  });

  final String id;

  /// The reference quoted on the failure the person scanning saw.
  /// Null for a scan that succeeded, and for any failure from before
  /// `0680` — it was minted after the settle and never stored.
  final String? logRef;

  final DateTime createdAt;
  final DateTime? finishedAt;
  final String orgName;
  final String providerName;

  /// `platform`, `own` or `device`. It decides who the failure is a
  /// problem for: the platform's key is ours to fix, and a company's
  /// own is a conversation with them.
  final String keySource;

  /// `ok`, `failed`, or `pending`.
  final String status;
  final double charged;
  final bool refunded;

  /// The reader that read it when the chosen one would not. 0679.
  final String? fellBackTo;
  final String? fileName;

  /// The vendor's own sentence. The whole reason this screen exists.
  final String? error;

  /// A scan still pending an hour after it started.
  ///
  /// The function died between `ocr_begin` and `ocr_finish`, so the
  /// charge was taken and the refund never ran. Worth its own name
  /// because it does not look like a failure — the status says
  /// `pending`, which reads as "still going" for ever.
  bool get unsettled =>
      status == 'pending' &&
      DateTime.now().difference(createdAt) > const Duration(hours: 1);

  /// Money that was taken and not given back.
  bool get owed => charged > 0 && !refunded && (status == 'failed' || unsettled);

  static DateTime? _date(Object? v) =>
      v == null ? null : DateTime.tryParse('$v')?.toLocal();

  factory ScanLogEntry.fromJson(Map<String, dynamic> j) => ScanLogEntry(
    id: '${j['id']}',
    logRef: j['log_ref']?.toString(),
    createdAt: _date(j['created_at']) ?? DateTime.now(),
    finishedAt: _date(j['finished_at']),
    orgName: j['org_name']?.toString() ?? 'a company since deleted',
    providerName: j['provider_name']?.toString() ?? '${j['provider']}',
    keySource: j['key_source']?.toString() ?? 'platform',
    status: j['status']?.toString() ?? 'pending',
    charged: OcrSettings._num(j['amount_charged']),
    refunded: j['refunded'] == true,
    fellBackTo: j['fell_back_to']?.toString(),
    fileName: (j['file_name']?.toString().trim().isEmpty ?? true)
        ? null
        : j['file_name'].toString().trim(),
    error: (j['error']?.toString().trim().isEmpty ?? true)
        ? null
        : j['error'].toString().trim(),
  );
}

/// How scanning is going, in the three numbers worth a glance.
class ScanHealth {
  const ScanHealth({
    required this.ok24h,
    required this.failed24h,
    required this.unsettled,
    required this.unsettledCharged,
  });

  final int ok24h;
  final int failed24h;

  /// Scans still pending an hour on. Each one is a charge that was
  /// taken and never refunded, which is the one combination nobody
  /// finds on their own.
  final int unsettled;
  final double unsettledCharged;

  static const none =
      ScanHealth(ok24h: 0, failed24h: 0, unsettled: 0, unsettledCharged: 0);

  static int _int(Object? v) =>
      v is num ? v.toInt() : int.tryParse('$v') ?? 0;

  factory ScanHealth.fromJson(Map<String, dynamic> j) => ScanHealth(
    ok24h: _int(j['ok_24h']),
    failed24h: _int(j['failed_24h']),
    unsettled: _int(j['unsettled']),
    unsettledCharged: OcrSettings._num(j['unsettled_charged']),
  );
}

/// One key out of a reader's pool, as the console is allowed to see it.
///
/// Everything about it except the key. `keyTail` is the last four
/// characters, which is what lets two keys off the same Google account
/// be told apart against the provider's own console, and is short
/// enough to be no use to anybody who obtains it. There is no field
/// that could carry the key and no function that would return one to
/// this app: `ocr_keys_for` is the only reader, and the key column is
/// not in its result.
///
/// [inWindow] and [hasHeadroom] are the two gates, kept apart because
/// they come back at different times and for different reasons — out
/// of hours returns at six, spent returns when the window rolls.
class OcrPoolKey {
  const OcrPoolKey({
    required this.id,
    required this.label,
    required this.keyTail,
    required this.isActive,
    required this.inWindow,
    required this.hasHeadroom,
    required this.spentMinute,
    required this.spentDay,
    required this.spentMonth,
    this.perMinute,
    this.perDay,
    this.perMonth,
    this.hours = const [],
    this.weekdays = const [],
    this.months = const [],
    this.lastUsedAt,
    this.lastError,
    this.lastErrorAt,
  });

  final String id;
  final String label;
  final String keyTail;
  final bool isActive;

  /// Whether its clock allows it at this moment.
  final bool inWindow;

  /// Whether it is under all three of its caps at this moment.
  final bool hasHeadroom;

  final int spentMinute;
  final int spentDay;
  final int spentMonth;

  /// Null is no cap, which is the right answer for a paid key.
  final int? perMinute;
  final int? perDay;
  final int? perMonth;

  /// Empty is always, which is what almost every key wants.
  final List<int> hours;
  final List<int> weekdays;
  final List<int> months;

  final DateTime? lastUsedAt;
  final String? lastError;
  final DateTime? lastErrorAt;

  /// Whether a scan would be given this key right now.
  ///
  /// All three, because a key fails this for three different reasons
  /// and the screen says which — `standDownReason`.
  bool get isUsableNow => isActive && inWindow && hasHeadroom;

  /// Why it would not be, in the words the console shows, or null when
  /// it would be.
  ///
  /// Order matters and is the order somebody can act in: switched off
  /// is a decision to reverse, out of hours is a wait with a known end,
  /// and spent is a wait that needs nobody.
  String? get standDownReason {
    if (!isActive) return 'Switched off';
    if (!inWindow) return 'Outside its hours';
    if (!hasHeadroom) return 'Spent for now';
    return null;
  }

  static List<int> _ints(Object? raw) => switch (raw) {
    final List<dynamic> list => [
        for (final v in list)
          if (int.tryParse('$v') case final int n) n,
      ],
    _ => const [],
  };

  static int? _intOrNull(Object? raw) =>
      raw == null ? null : int.tryParse('$raw');

  factory OcrPoolKey.fromJson(Map<String, dynamic> j) => OcrPoolKey(
        id: '${j['id']}',
        label: '${j['label'] ?? ''}',
        keyTail: '${j['key_tail'] ?? ''}',
        isActive: j['is_active'] == true,
        inWindow: j['in_window'] == true,
        hasHeadroom: j['has_headroom'] == true,
        spentMinute: _intOrNull(j['spent_minute']) ?? 0,
        spentDay: _intOrNull(j['spent_day']) ?? 0,
        spentMonth: _intOrNull(j['spent_month']) ?? 0,
        perMinute: _intOrNull(j['per_minute']),
        perDay: _intOrNull(j['per_day']),
        perMonth: _intOrNull(j['per_month']),
        hours: _ints(j['hours']),
        weekdays: _ints(j['weekdays']),
        months: _ints(j['months']),
        lastUsedAt: DateTime.tryParse('${j['last_used_at']}'),
        lastError: (j['last_error']?.toString().trim().isEmpty ?? true)
            ? null
            : j['last_error'].toString().trim(),
        lastErrorAt: DateTime.tryParse('${j['last_error_at']}'),
      );
}

/// A reader's pool of keys: the platform's, or one company's own.
///
/// Built on the CLIENT and not on a repository, and that is the whole
/// point rather than a shortcut.
///
/// `Repo` is a tenant's, and it does not exist until an organization
/// has been resolved. A platform operator belongs to no company, so on
/// the console screen `repoProvider` is null and `requireRepo` refuses
/// the only people that screen exists for — "Your company has not
/// finished loading", for ever.
/// `platform_console_wiring_test.dart` is a whole file about that bug
/// coming back twice, and it caught this on the way in: the first
/// version of this pool was an `extension on Repo`.
///
/// `PlatformRepo` would work and would be a lie: a tenant administrator
/// keeping their own company's keys is not the platform.
///
/// So it is neither. The three functions take an org id — null for the
/// platform's pool, a uuid for a company's — and the DATABASE decides
/// who may ask, by looking at the id it was handed:
/// `app.is_platform_admin()` for null and `app.can_admin(org_id)` for
/// the rest. One implementation, one argument list, and the guard in
/// the one place it can actually be enforced.
class OcrKeyPool {
  const OcrKeyPool(this.client);

  final SupabaseClient client;

  Future<List<OcrPoolKey>> keys(String provider, {String? orgId}) async =>
      Repo.rows(await client.rpc('ocr_keys_for', params: {
        'p_provider': provider,
        'p_org_id': orgId,
      })).map(OcrPoolKey.fromJson).toList();

  /// Adds a key or changes one.
  ///
  /// A null [apiKey] on an EXISTING key leaves the stored one alone,
  /// which is what lets a cap be raised without retyping a secret
  /// nobody still has — this app cannot show anybody the key it holds.
  /// On a new one the function refuses a blank, so the screen need not
  /// decide what an empty box means.
  Future<String> save(
    String provider, {
    String? orgId,
    String? id,
    String? label,
    String? apiKey,
    int? perMinute,
    int? perDay,
    int? perMonth,
    List<int> hours = const [],
    List<int> weekdays = const [],
    List<int> months = const [],
    bool isActive = true,
  }) async =>
      '${await client.rpc('save_ocr_key', params: {
        'p_provider': provider,
        'p_org_id': orgId,
        'p_id': id,
        'p_label': label,
        'p_api_key': apiKey,
        'p_per_minute': perMinute,
        'p_per_day': perDay,
        'p_per_month': perMonth,
        'p_hours': hours,
        'p_weekdays': weekdays,
        'p_months': months,
        'p_is_active': isActive,
      })}';

  Future<void> remove(String provider, String id, {String? orgId}) async =>
      await client.rpc('delete_ocr_key', params: {
        'p_provider': provider,
        'p_id': id,
        'p_org_id': orgId,
      });
}

/// One sheet of paper, and what became of it.
///
/// `0694`. `ocr_scans` has always recorded what was read, what it cost
/// and which provider answered; it never recorded what the photograph
/// BECAME, so a scan that quietly produced nothing was indistinguishable
/// from one that posted a bill.
///
/// [postedLabel] is resolved in SQL rather than here — see the migration
/// header. A row whose document was deleted afterwards comes back with
/// [postedTable] set and [postedLabel] null, which is the honest answer:
/// this became a bill that no longer exists.
class ScanInboxEntry {
  const ScanInboxEntry({
    required this.scanId,
    required this.scannedAt,
    this.attachmentId,
    this.fileName,
    this.storagePath,
    this.provider,
    this.status,
    this.error,
    this.documentKind,
    this.kindLabel,
    this.target,
    this.postedTable,
    this.postedId,
    this.postedAt,
    this.postedLabel,
    this.postedDate,
    this.reviewedAt,
    this.corrected = false,
  });

  final String scanId;
  final DateTime scannedAt;

  /// Null once the record this was filed against has been deleted:
  /// `delete_attachments_of_row` takes the picture with the document and
  /// `ocr_scans.attachment_id` is `on delete set null`.
  final String? attachmentId;

  /// Falls back to the storage object's own name for exactly that case.
  final String? fileName;
  final String? storagePath;
  final String? provider;
  final String? status;
  final String? error;
  final String? documentKind;
  final String? kindLabel;
  final String? target;
  final String? postedTable;
  final String? postedId;
  final DateTime? postedAt;
  final String? postedLabel;
  final DateTime? postedDate;
  final DateTime? reviewedAt;
  final bool corrected;

  /// Whether anything came of this reading.
  bool get isPosted => postedTable != null;

  /// Whether the picture can still be opened. A scan whose document was
  /// deleted keeps its row and loses its file.
  bool get hasImage => (storagePath ?? '').isNotEmpty && attachmentId != null;

  factory ScanInboxEntry.fromJson(Map<String, dynamic> j) => ScanInboxEntry(
        scanId: j['scan_id'].toString(),
        attachmentId: j['attachment_id']?.toString(),
        fileName: j['file_name']?.toString(),
        storagePath: j['storage_path']?.toString(),
        scannedAt: DateTime.parse(j['scanned_at'].toString()).toLocal(),
        provider: j['provider']?.toString(),
        status: j['status']?.toString(),
        error: j['error']?.toString(),
        documentKind: j['document_kind']?.toString(),
        kindLabel: j['kind_label']?.toString(),
        target: j['target']?.toString(),
        postedTable: j['posted_table']?.toString(),
        postedId: j['posted_id']?.toString(),
        postedAt: Fmt.parseDate(j['posted_at']),
        postedLabel: j['posted_label']?.toString(),
        postedDate: Fmt.parseDate(j['posted_date']),
        reviewedAt: Fmt.parseDate(j['reviewed_at']),
        corrected: j['corrected'] == true,
      );
}

extension RepoScanInbox on Repo {
  /// Every reading this company has taken, newest first.
  ///
  /// [only] is `all`, `posted` or `unposted`. The last is the one worth
  /// looking at: a photograph that became nothing is either work left
  /// half done or a reading that failed, and both want a person.
  Future<List<ScanInboxEntry>> scanInbox({
    int limit = 100,
    String only = 'all',
  }) async {
    final rows = await callRpc('scan_inbox', params: {
      'p_org_id': orgId,
      'p_limit': limit,
      'p_only': only,
    });
    return [
      for (final r in Repo.rows(rows))
        ScanInboxEntry.fromJson(Map<String, dynamic>.from(r)),
    ];
  }

  /// Records what a reading became.
  ///
  /// With no [table] the destination is copied off the attachment, which
  /// is where the FILE went — see `0694`. [table] and [recordId] are for
  /// the one document that becomes many rows: a bank statement is filed
  /// against `bank_transactions` with a placeholder id.
  ///
  /// Best-effort by design. A posting that happened is not undone
  /// because the note about it failed, and the flows call this after the
  /// document already exists.
  Future<void> recordScanPosting({
    required String attachmentId,
    String? table,
    String? recordId,
  }) async {
    try {
      await callRpc('record_scan_posting', params: {
        'p_org_id': orgId,
        'p_attachment_id': attachmentId,
        if (table != null) 'p_table': table,
        if (recordId != null) 'p_id': recordId,
      });
    } catch (_) {
      // Swallowed for the reason above. The inbox showing "nothing came
      // of this" about a bill that exists is a smaller wrong than a
      // posted bill rolled back over a note.
    }
  }
}

extension RepoScanReading on Repo {
  /// The whole reading a scan produced.
  ///
  /// Read straight off `ocr_scans` rather than through a function:
  /// `ocr_scans_read` already lets anybody who may write or read the
  /// ledger see their own company's rows, which is the same audience
  /// the inbox has. A SECURITY DEFINER wrapper would be a second copy
  /// of that rule to keep in step.
  ///
  /// Null where the scan failed — there is no reading — or where the
  /// row is not this company's, which RLS turns into no row rather than
  /// an error.
  Future<OcrExtraction?> scanReading(String scanId) async {
    final rows = await client
        .from('ocr_scans')
        .select('extracted')
        .eq('id', scanId)
        .limit(1);
    if (rows.isEmpty) return null;
    final held = rows.first['extracted'];
    if (held is! Map) return null;
    return OcrExtraction.fromJson(Map<String, dynamic>.from(held));
  }
}
