import '../../core/format.dart';

/// Which document a document can become, and how much of it is left to
/// take.
///
/// These rules mirror `app.transfer_counter` in migration 0081. The
/// database is the authority — it raises 23514 on a transition it does
/// not recognise and on a quantity larger than remains — and this exists
/// so the app can offer the right menu and refuse the obvious mistakes
/// before a round trip.

/// A line of the source document, as the transfer dialog sees it.
class TransferLine {
  const TransferLine({
    required this.lineId,
    required this.lineNo,
    required this.description,
    required this.quantity,
    required this.taken,
    required this.outstanding,
  });

  final String lineId;
  final int lineNo;
  final String description;

  /// What the source line was for.
  final double quantity;

  /// How much has already gone forward by this route.
  final double taken;

  /// What is still available to take.
  final double outstanding;

  factory TransferLine.fromJson(Map<String, dynamic> j) => TransferLine(
        lineId: j['line_id'] as String,
        lineNo: (j['line_no'] as num?)?.toInt() ?? 0,
        description: j['description']?.toString() ?? '',
        quantity: Fmt.toDouble(j['quantity']),
        taken: Fmt.toDouble(j['taken']),
        outstanding: Fmt.toDouble(j['outstanding']),
      );
}

/// The document types [docType] can be transferred to, in the order a
/// menu should offer them: the next step in the cycle first, the
/// shortcuts after it.
List<String> transferTargets(String docType) => switch (docType) {
      'quotation' => const ['sales_order', 'delivery_order', 'invoice'],
      'proforma' => const ['invoice'],
      'sales_order' => const ['delivery_order', 'invoice'],
      'delivery_order' => const ['invoice'],
      'purchase_request' => const ['purchase_order'],
      'purchase_order' => const ['goods_received', 'bill'],
      'goods_received' => const ['bill'],
      _ => const [],
    };

/// Whether this document has a next step at all. Invoices, bills and
/// credit notes are the end of their chain.
bool canTransfer(String docType) => transferTargets(docType).isNotEmpty;

/// What is wrong with a requested set of quantities, or null if nothing.
///
/// Taking more than remains is refused here for the same reason the
/// database refuses it rather than clamping: a clamp delivers nine of
/// the ten somebody asked for and reports success, and the difference is
/// not noticed until the customer counts the boxes.
String? transferProblem(
  List<TransferLine> lines,
  Map<String, double> requested,
) {
  var total = 0.0;

  for (final line in lines) {
    final want = requested[line.lineId] ?? 0;
    if (want < 0) {
      return 'Line ${line.lineNo} cannot take a negative quantity.';
    }
    if (want > line.outstanding) {
      return 'Line ${line.lineNo} has ${Fmt.qty(line.outstanding)} '
          'outstanding; ${Fmt.qty(want)} was asked for.';
    }
    total += want;
  }

  if (total <= 0) {
    return 'Enter a quantity on at least one line.';
  }
  return null;
}
