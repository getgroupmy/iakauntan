import '../../core/format.dart';
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
    this.serviceStart,
    this.serviceEnd,
    this.lots = const [],
    this.customFields = const {},
  });

  String? itemId;

  /// The fields this company added to a document line.
  Map<String, dynamic> customFields;
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

  /// The period this line is earned over. Null on both means earned on
  /// the invoice date, which is what almost every line is. Set, and 0309
  /// credits deferred revenue instead and releases it month by month.
  ///
  /// The two are set and cleared together — `sales_document_lines` has
  /// a check constraint refusing one without the other — so the editor
  /// never writes a half-open period.
  DateTime? serviceStart;
  DateTime? serviceEnd;

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
    'custom_fields': customFields,
    // Only when set, and only then. `saveDocument` inserts this map
    // straight into `sales_document_lines` or `purchase_document_lines`,
    // and the purchase table has no such columns — sending the keys as
    // nulls would have PostgREST reject every bill. Omitting them is
    // also how a period is cleared: the save path deletes and reinserts
    // every line, so an absent key lands as null.
    if (serviceStart != null && serviceEnd != null) ...{
      'service_start': Fmt.iso(serviceStart!),
      'service_end': Fmt.iso(serviceEnd!),
    },
  };

  factory LineDraft.fromLine(DocumentLine l) => LineDraft(
    customFields: l.customFields,
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
    serviceStart: l.serviceStart,
    serviceEnd: l.serviceEnd,
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
  // `v_gross numeric(18, 4)`, so the product is held to four decimals
  // and not to whatever a double happens to carry. Four rather than two
  // because a price per thousand is real and would otherwise be lost
  // before the discount is taken off it.
  final gross = _r4(quantity * unitPrice);

  // `Fmt.percentOf`, not the arithmetic written out, and for the reason
  // that function gives: `((base * pct / 100) * 100).round() / 100` is
  // a cent low whenever the answer lands exactly on a half-cent. On a
  // one-unit line at RM 2.90 with 5% off, the editor used to show 14
  // sen of discount against the 15 the trigger would store.
  final discount = discountPercent > 0
      ? Fmt.percentOf(gross, discountPercent, baseDecimals: 4)
      : discountAmount;

  if (taxInclusive && taxRate > 0) {
    // unit_price already contains tax: strip it back out.
    //
    // A division rather than a percentage, so there is nothing for
    // `percentOf` to do here. It is left as the SQL writes it, and the
    // tax falls out by subtraction — which is what keeps net and tax
    // adding back to the gross exactly.
    final net = _r((gross - discount) / (1 + taxRate / 100));
    final tax = _r(gross - discount - net);
    return (net: net, tax: tax, total: net + tax);
  }

  final net = _r(gross - discount);
  final tax = Fmt.percentOf(net, taxRate);
  return (net: net, tax: tax, total: net + tax);
}

double _r(double v) => (v * 100).roundToDouble() / 100;

/// To four decimals, which is what `numeric(18, 4)` holds a line's
/// gross at.
double _r4(double v) => (v * 10000).roundToDouble() / 10000;

/// How a service period reads on the line it belongs to.
///
/// Pure, and out here rather than in the widget, so the wording and the
/// month count can be asserted without a Flutter binding — the same
/// split `dashboardTabs` and `groupByModule` have.
///
/// The count is what somebody checks the contract against: "12 months"
/// is the thing they can compare with what they sold. It is claimed
/// only when the period is exactly that many whole months and falls
/// back to a day count otherwise, because a month count that is one day
/// out is worse on an invoice than a plain "365 days".
String servicePeriodLabel(DateTime? from, DateTime? to) {
  if (from == null || to == null) return 'Earned on the invoice date';
  final days = to.difference(from).inDays + 1;
  final months = (to.year - from.year) * 12 +
      (to.month - from.month) +
      (to.day >= from.day ? 1 : 0);
  final span = months > 0 && _wholeMonths(from, to, months)
      ? '$months month${months == 1 ? '' : 's'}'
      : '$days day${days == 1 ? '' : 's'}';
  return '${Fmt.date(from)} – ${Fmt.date(to)} · $span';
}

/// True when [from]..[to] inclusive is exactly [months] whole months.
///
/// Asked at the exclusive boundary — the day after the period ends —
/// because that is the only place the answer is unambiguous. A year
/// from 1 January ends the day before 1 January, whatever the months in
/// between were worth.
bool _wholeMonths(DateTime from, DateTime to, int months) =>
    _addMonths(from, months) ==
    DateTime(to.year, to.month, to.day).add(const Duration(days: 1));

/// [d] moved on by [months], clamped to the end of the month it lands
/// in, because `DateTime(2026, 2, 31)` is quietly 3 March.
///
/// The clamp is defensive and cannot be reached from
/// `servicePeriodLabel` as it stands: the rollover only bites when the
/// target month is short and the start day is past its end, and the
/// `months` that would put it there is always one more than the one the
/// count produces. Removing it therefore breaks no test. It stays
/// because it is the correct meaning of "a month later" and the count
/// above it is the kind of expression that gets adjusted.
DateTime _addMonths(DateTime d, int months) {
  final total = d.month - 1 + months;
  final year = d.year + (total ~/ 12);
  final month = total % 12 + 1;
  final last = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, d.day < last ? d.day : last);
}
