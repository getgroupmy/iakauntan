import 'attachments_repository.dart' show RepoAttachments;
import 'repository.dart';

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
  });

  final bool enabled;

  /// `claude` or `google`.
  final String provider;

  /// `platform` — drawn from purchased credit — or `own`.
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
  /// organization on its own key never runs out.
  bool get outOfCredit =>
      enabled && keySource == 'platform' && price > 0 && balance < price;

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
  final String? supplierTaxId;
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
