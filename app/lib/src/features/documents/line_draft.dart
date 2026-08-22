import '../../data/models.dart';

/// Mutable working copy of a document line while it is being edited.
/// Shared by the sales and purchase editors.
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
    this.warehouseId,
    this.sourceLineId,
    this.projectCode,
    this.departmentCode,
    this.lots = const [],
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
  String? warehouseId;

  /// Which batches or serial numbers this line is made up of, held here
  /// rather than written straight through. Saving a document deletes its
  /// lines and reinserts them, so a line id is not stable enough to hang
  /// an allocation off until the save has finished.
  List<Map<String, dynamic>> lots;

  /// Where this line came from, if it was transferred. Never edited —
  /// only carried, so that saving the document does not sever the link
  /// and hand the quantity back to the order it came off.
  final String? sourceLineId;

  /// The job this line belongs to. Set from the document rather than
  /// per line: the column is per line because the ledger needs it there,
  /// but nobody splits one invoice across two jobs often enough to give
  /// every line its own picker.
  String? projectCode;

  /// The part of the business this line belongs to, set from the
  /// document for the same reason as the project above. Written per line
  /// because that is where `gl_lines.department_code` reads it from, and
  /// that column is the entire input to the by-department P&L.
  String? departmentCode;

  ({double net, double tax, double total}) get totals => computeLine(
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
    'warehouse_id': warehouseId,
    'source_line_id': sourceLineId,
    'project_code': projectCode,
    'department_code': departmentCode,
  };

  factory LineDraft.fromLine(DocumentLine l) => LineDraft(
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
    warehouseId: l.warehouseId,
    sourceLineId: l.sourceLineId,
    projectCode: l.projectCode,
    departmentCode: l.departmentCode,
  );
}

/// Fills a line from the item master: price, unit, classification and the
/// tax code the item carries.
///
/// Shared by the wide row and the narrow card because they were doing it
/// separately and had already drifted — the narrow one set everything
/// except the tax code, so a line added on a phone silently carried no
/// SST.
void applyItemToLine(LineDraft line, Item item, List<TaxCode> taxCodes) {
  line
    ..itemId = item.id
    ..description = item.name
    ..unitPrice = item.unitPrice
    ..uomCode = item.uomCode
    ..classificationCode = item.classificationCode;

  final tax =
      taxCodes.where((t) => t.id == item.salesTaxCodeId).firstOrNull ??
      taxCodes.where((t) => t.isDefault).firstOrNull;
  if (tax != null) {
    line
      ..taxCodeId = tax.id
      ..taxRate = tax.rate;
  }
}

/// How many of the item's own units one of [uom] is, from the rows
/// `item_uom_options` returns.
///
/// Falls back to 1 for the item's own unit and for a unit that is not on
/// the list — the same answer `app.uom_qty` gives when there is nothing
/// to convert through, so the editor never disagrees with the ledger by
/// guessing.
double uomFactor(List<Map<String, dynamic>> options, String? uom) {
  if (uom == null) return 1;
  for (final o in options) {
    if ('${o['uom_code']}' == uom) {
      final q = o['qty_in_stock_uom'];
      final v = q is num ? q.toDouble() : double.tryParse('$q') ?? 1;
      return v > 0 ? v : 1;
    }
  }
  return 1;
}

/// A price written per one unit, re-written per a different one.
///
/// The money on a line is per the line's own unit — that is the whole
/// design, and the database agrees. So switching a line from tins to
/// cartons of twenty-four without touching the price would sell a
/// carton for the price of a tin. Rescaling keeps the line worth what it
/// was worth a moment ago, and the number stays editable afterwards.
double rescaleForUom(double price, double fromFactor, double toFactor) {
  if (fromFactor <= 0 || toFactor <= 0) return price;
  return price * toFactor / fromFactor;
}

/// What this line actually takes off the shelf, in the item's own unit,
/// or null when the line is already written in it and there is nothing
/// worth saying.
///
/// Shown under the quantity because the number the shop types and the
/// number the stock moves by are no longer the same number, and the
/// place to notice a wrong pack size is before the invoice is posted.
String? baseQuantityHint({
  required double quantity,
  required String? uom,
  required String baseUom,
  required double factor,
}) {
  if (uom == null || uom == baseUom || factor == 1) return null;
  final base = quantity * factor;
  final text = base == base.roundToDouble()
      ? base.toStringAsFixed(0)
      : base.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');
  return '= $text $baseUom';
}

/// Mirrors app.calc_document_line() so the editor can show live totals
/// before a row is saved. The database remains the source of truth.
({double net, double tax, double total}) computeLine({
  required double quantity,
  required double unitPrice,
  required double discountPercent,
  required double discountAmount,
  required double taxRate,
  required bool taxInclusive,
}) {
  final gross = quantity * unitPrice;
  final discount = discountPercent > 0
      ? _r(gross * discountPercent / 100)
      : discountAmount;

  if (taxInclusive && taxRate > 0) {
    // unit_price already contains tax: strip it back out.
    final net = _r((gross - discount) / (1 + taxRate / 100));
    final tax = _r(gross - discount - net);
    return (net: net, tax: tax, total: net + tax);
  }

  final net = _r(gross - discount);
  final tax = _r(net * taxRate / 100);
  return (net: net, tax: tax, total: net + tax);
}

double _r(double v) => (v * 100).roundToDouble() / 100;
