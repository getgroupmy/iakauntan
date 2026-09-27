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
    this.matterId,
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

  /// Which matter this line is billed for or bought for, on a law firm's
  /// books. Set from the document like the two above, and written per
  /// line because `app.post_sales_document_internal` and its purchase
  /// twin read it off the line to put on `gl_lines.matter_id` — which is
  /// the entire input to a matter's own trial balance. 0691.
  String? matterId;

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
    'matter_id': matterId,
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
    matterId: l.matterId,
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

  final tax = taxForItem(item, taxCodes);
  // Null is not "no tax" here — see the test. An item that names no
  // code in a company that has no default leaves the line as it was.
  if (tax != null) applyTaxCodeToLine(line, tax);
}

/// The tax code an item would put on a line: its own, or the company's
/// default where it names none.
///
/// Its own function since `0704`'s successor, because two things now
/// need the same answer — [applyItemToLine], which applies it, and
/// [itemWouldOverwrite], which has to say what it would replace. Asking
/// the question twice in two places is how they come to disagree.
TaxCode? taxForItem(Item item, List<TaxCode> taxCodes) =>
    taxCodes.where((t) => t.id == item.salesTaxCodeId).firstOrNull ??
    taxCodes.where((t) => t.isDefault).firstOrNull;

/// One thing on a line that an item would write over.
enum LinePart { description, unitPrice, taxCode, unit }

/// What [LinePart] would change, in words somebody can judge.
class ItemChange {
  const ItemChange({
    required this.part,
    required this.label,
    required this.current,
    required this.suggested,
  });

  final LinePart part;

  /// The field's name as the line editor labels it.
  final String label;

  /// What the line says now, and what the item would put there. Both
  /// already formatted: the dialog shows them and judges nothing.
  final String current;
  final String suggested;
}

/// Everything applying [item] would overwrite that somebody would miss.
///
/// Empty when nothing worth asking about would change, which is the
/// ordinary case: a blank line takes the item's everything without a
/// word.
///
/// Reported twice from the same scanned bill. First the description --
/// four lines of the supplier's own wording replaced by the item
/// master's name. Then, once that was asked about, the rest of it: "why
/// when the item number is keyed in replace the unit price disc% tax and
/// amount". The price read off the paper was 23.3332258 and the item's
/// was zero, so the line went to RM 0.00 and the amount with it.
///
/// The three exemptions are the description's three, generalised,
/// because each of them is about the same thing -- whether the value on
/// the line came from a PERSON or from us:
///
///   * EMPTY, which for a price means zero. Nothing to lose;
///   * the SAME value. A dialog asking whether to replace a thing with
///     itself is one people learn to dismiss without reading;
///   * what the PREVIOUSLY BOUND item put there. Correcting a mis-picked
///     item would otherwise ask about every field it had filled in.
///
/// [previous] is the item the line is bound to now, where it is still on
/// the list. Null for a line that is bound to nothing, or whose item has
/// since been deleted -- and then every non-empty value counts as
/// somebody's.
List<ItemChange> itemWouldOverwrite(
  LineDraft line,
  Item item,
  List<TaxCode> taxCodes, {
  Item? previous,
}) {
  final out = <ItemChange>[];

  if (descriptionIsWorthKeeping(
    current: line.description,
    suggested: item.name,
    boundItemName: previous?.name,
  )) {
    out.add(ItemChange(
      part: LinePart.description,
      label: 'Description',
      current: line.description,
      suggested: item.name,
    ));
  }

  // Zero is this field's empty. A line nobody has priced reads zero,
  // and asking about it would put a dialog in front of the commonest
  // path there is.
  if (line.unitPrice != 0 &&
      line.unitPrice != item.unitPrice &&
      line.unitPrice != previous?.unitPrice) {
    out.add(ItemChange(
      part: LinePart.unitPrice,
      label: 'Unit price',
      current: _number(line.unitPrice),
      suggested: _number(item.unitPrice),
    ));
  }

  final tax = taxForItem(item, taxCodes);
  // A company with no default and an item that names no code leaves the
  // line's tax alone, so there is nothing to ask about.
  if (tax != null &&
      line.taxCodeId != null &&
      line.taxCodeId != tax.id &&
      line.taxCodeId != (previous == null
          ? null
          : taxForItem(previous, taxCodes)?.id)) {
    out.add(ItemChange(
      part: LinePart.taxCode,
      label: 'Tax',
      current: _taxLabel(line.taxCodeId, taxCodes),
      suggested: '${tax.code} (${_number(tax.rate)}%)',
    ));
  }

  // The unit is the same class of silent loss as the rest: a line that
  // says the supplier billed in `MON` becomes whatever the item is
  // counted in, and the quantity beside it then means something else.
  //
  // `Item.uomCode` is not nullable -- it defaults to `C62`, the UN/CEFACT
  // code for "one" -- so there is no case here where the item would
  // blank the line's unit, only one where it changes it.
  final lineUom = line.uomCode ?? '';
  if (lineUom.isNotEmpty &&
      lineUom != item.uomCode &&
      lineUom != previous?.uomCode) {
    out.add(ItemChange(
      part: LinePart.unit,
      label: 'Unit',
      current: lineUom,
      suggested: item.uomCode,
    ));
  }

  return out;
}

/// Applies [item] to [line], keeping the parts that were not chosen.
///
/// Written as "apply, then put back" rather than as a per-field apply,
/// so that [applyItemToLine] stays the ONE description of what an item
/// gives a line. A second copy that set four fields conditionally would
/// be a second copy to drift -- which is exactly the fault this file's
/// header already records.
void applyItemKeeping(
  LineDraft line,
  Item item,
  List<TaxCode> taxCodes,
  Set<LinePart> take,
) {
  final description = line.description;
  final unitPrice = line.unitPrice;
  final taxCodeId = line.taxCodeId;
  final taxRate = line.taxRate;
  final inclusive = line.isTaxInclusive;
  final uom = line.uomCode;

  applyItemToLine(line, item, taxCodes);

  if (!take.contains(LinePart.description)) line.description = description;
  if (!take.contains(LinePart.unitPrice)) line.unitPrice = unitPrice;
  if (!take.contains(LinePart.unit)) line.uomCode = uom;
  if (!take.contains(LinePart.taxCode)) {
    // All three together. The rate and the inclusive flag are what the
    // code MEANS -- `0641`'s header has what a line that took one and
    // not the other costs: RM 108 quoted and RM 116.64 charged.
    line
      ..taxCodeId = taxCodeId
      ..taxRate = taxRate
      ..isTaxInclusive = inclusive;
  }
}

/// A number as somebody typed it, not rounded to look tidy.
///
/// A scanned unit price of 23.3332258 shown as 23.33 is a dialog asking
/// about a number that is not the one on the line.
String _number(double v) {
  final s = v.toString();
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

String _taxLabel(String? id, List<TaxCode> taxCodes) {
  final t = taxCodes.where((t) => t.id == id).firstOrNull;
  if (t == null) return '';
  return '${t.code} (${_number(t.rate)}%)';
}

/// Whether filling this line from an item would throw away something a
/// PERSON wrote in the description.
///
/// Asked for from a bill scanned off a supplier's PDF: the reading had
/// put "Google Workspace Business Starter Usage" on four lines, an item
/// was assigned afterwards, and [applyItemToLine] replaced all four with
/// the item master's name without a word. The supplier's own wording is
/// often the more useful of the two — it is what the paper says, and it
/// is what somebody reconciling the bill will look for.
///
/// Three cases are deliberately NOT worth a prompt, and each of them
/// would make this a nuisance rather than a safeguard:
///
///   * an EMPTY box. There is nothing to lose and the item's name is
///     exactly what is wanted;
///   * the SAME text, ignoring case and surrounding space. A dialog
///     asking whether to replace a thing with itself is a dialog people
///     learn to dismiss without reading;
///   * the name of the item the line is ALREADY bound to. That text got
///     there because this function's caller put it there a moment ago,
///     so changing item A for item B is not overriding anybody's work.
///     Without this, correcting a mis-picked item asks twice.
bool descriptionIsWorthKeeping({
  required String current,
  required String suggested,
  String? boundItemName,
}) {
  String tidy(String s) => s.trim().toLowerCase();
  final now = tidy(current);
  if (now.isEmpty) return false;
  if (now == tidy(suggested)) return false;
  if (boundItemName != null && now == tidy(boundItemName)) return false;
  return true;
}

/// Everything a line takes from the tax code it is charged at.
///
/// One function because there are two places that choose a code — the
/// item master fills one in above, and the editor's tax picker changes
/// it — and they are the same choice. This file's other fill function
/// exists because those two had already drifted once, the narrow card
/// setting everything except the tax code, so a line added on a phone
/// silently carried no SST.
///
/// [tax] of null is "no tax": the rate goes to zero and the price
/// becomes the whole of the net, which is what
/// `app.calc_document_line` computes for a line with no code.
///
/// The FLAG matters as much as the rate. `0641` has the trigger resolve
/// `is_tax_inclusive` from the code the moment the code is chosen, and
/// [computeLine] below mirrors that trigger so the editor can show a
/// total before the row exists. A line that took the rate and not the
/// flag would put an inclusive price on screen at its exclusive total
/// and then store the other number — RM 108 quoted, RM 116.64 charged.
void applyTaxCodeToLine(LineDraft line, TaxCode? tax) {
  line
    ..taxCodeId = tax?.id
    ..taxRate = tax?.rate ?? 0
    ..isTaxInclusive = tax?.isInclusive ?? false;
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
