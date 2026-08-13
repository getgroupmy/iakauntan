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
  final String? blurb;

  factory OcrProvider.fromJson(Map<String, dynamic> j) => OcrProvider(
        code: j['code'].toString(),
        name: j['name']?.toString() ?? j['code'].toString(),
        price: OcrSettings._num(j['price']),
        takesKey: j['takes_key'] != false,
        runsOnDevice: j['runs_on_device'] == true,
        ready: j['ready'] != false,
        blurb: (j['blurb']?.toString().trim().isEmpty ?? true)
            ? null
            : j['blurb'].toString().trim(),
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

  Future<void> setOcrSettings({
    required bool enabled,
    required String provider,
    required String keySource,
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
