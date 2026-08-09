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
      );
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
  final discount =
      discountPercent > 0 ? _r(gross * discountPercent / 100) : discountAmount;

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
