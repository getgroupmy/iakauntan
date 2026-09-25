import '../../data/ocr_repository.dart';
import '../../data/scan_kinds_repository.dart';

/// Where a reading is going, decided once and in one place.
///
/// Until `0694` this decision was made four times — on the Bills list,
/// the Expenses screen, the Contacts screen and the bank reconciliation
/// — because each of those owned its own scan button, and each knew
/// only about its own destination. A receipt photographed on the Bills
/// screen could become a bill or nothing; the same receipt on the
/// Expenses screen could become an expense or nothing. The paper did
/// not change. The button did.
///
/// With one door, the reading has to say where it goes, so this is
/// where that is worked out.
enum ScanDestination {
  bill,
  purchaseOrder,
  goodsReceived,
  invoice,
  expense,
  contact,
  bankStatement,

  /// Read, and nothing on it says what it is. Not a failure: a
  /// photograph of something the platform has no destination for is a
  /// perfectly good photograph, and the person is asked.
  unknown;

  /// The table a capture is parked against while the record it belongs
  /// to does not exist yet.
  ///
  /// `attachments` takes a real table name — the storage policies read
  /// it straight out of the object path and a trigger refuses a row
  /// whose path disagrees with its columns — so this cannot be a
  /// friendly name.
  String get table => switch (this) {
        ScanDestination.bill ||
        ScanDestination.purchaseOrder ||
        ScanDestination.goodsReceived =>
          'purchase_documents',
        ScanDestination.invoice => 'sales_documents',
        ScanDestination.expense => 'expenses',
        ScanDestination.contact => 'contacts',
        ScanDestination.bankStatement => 'bank_transactions',
        // Parked where an expense would go, because that is the
        // destination that asks least of the paper: an amount and a
        // date. Nothing is posted until somebody chooses, and the
        // capture is re-pointed when they do.
        ScanDestination.unknown => 'expenses',
      };

  /// What this is called on screen.
  String get label => switch (this) {
        ScanDestination.bill => 'Supplier bill',
        ScanDestination.purchaseOrder => 'Purchase order',
        ScanDestination.goodsReceived => 'Goods received note',
        ScanDestination.invoice => 'Sales invoice',
        ScanDestination.expense => 'Expense',
        ScanDestination.contact => 'Contact',
        ScanDestination.bankStatement => 'Bank statement',
        ScanDestination.unknown => 'Not sure yet',
      };

  /// The `sales_documents.doc_type` / `purchase_documents.doc_type`
  /// this becomes, or null where it is not a document at all.
  String? get docType => switch (this) {
        ScanDestination.bill => 'bill',
        ScanDestination.purchaseOrder => 'purchase_order',
        ScanDestination.goodsReceived => 'goods_received',
        ScanDestination.invoice => 'invoice',
        _ => null,
      };

  /// The `scan_document_kinds.code` this destination is CERTAIN of
  /// before the reader has said anything, or null where the paper could
  /// honestly be more than one thing.
  ///
  /// ## The gap this closes
  ///
  /// `0614` put `document_kind` on the scan so that the question a
  /// bookkeeper asks three months later -- what did it think this was
  /// -- has an answer. The answer comes from the READER, which is right
  /// where the reader is the only one who saw the paper.
  ///
  /// It is not right on a screen that already knew. The bank statement
  /// importer tells the reader `accounting.bank_statement` before the
  /// file is even uploaded, and then recorded nothing, because the
  /// reader it had narrowed to one destination was never asked to
  /// choose a kind and so returned none. The one scan in the live
  /// database is exactly that: twenty rows read out of a statement, and
  /// `document_kind` null.
  ///
  /// ## And why most of these are null
  ///
  /// A destination is where a reading GOES; a kind is what the paper
  /// IS, and the two are not one to one. A quotation and a purchase
  /// order are the same destination and different papers. `invoice` is
  /// a sales invoice here and `0614`'s `bill` kind is a supplier's, so
  /// neither names the other. A contact comes off a name card or off an
  /// SSM profile, and only the reader can tell which.
  ///
  /// Guessing any of those would put a wrong answer where there is
  /// currently an honest blank, which is worse than the blank: the
  /// blank is readable as "nobody recorded this" and a wrong kind is
  /// not readable as anything.
  String? get knownKind => switch (this) {
        ScanDestination.bankStatement => 'bank_statement',
        ScanDestination.goodsReceived => 'delivery_order',
        ScanDestination.expense => 'receipt',
        ScanDestination.bill => 'bill',
        ScanDestination.purchaseOrder ||
        ScanDestination.invoice ||
        ScanDestination.contact ||
        ScanDestination.unknown =>
          null,
      };

  /// Whether this destination needs a contact before anything can be
  /// created. A bill with no supplier is refused by the database —
  /// `purchase_documents.contact_id` is NOT NULL — so it is asked for
  /// in the flow rather than discovered at the save.
  bool get needsContact => switch (this) {
        ScanDestination.bill ||
        ScanDestination.purchaseOrder ||
        ScanDestination.goodsReceived ||
        ScanDestination.invoice =>
          true,
        _ => false,
      };
}

/// The destination a `module.action` names, or null for one nothing
/// here handles.
///
/// `0681` had the READER choose this, with the platform's configured
/// destinations in front of it and the page in its hand. That is a
/// better answer than anything string matching produces afterwards,
/// which is why it is asked first.
/// The `module.action` key this destination is on the server.
///
/// The inverse of [destinationFromTarget], and written beside it so
/// the two cannot drift -- a test walks every value and asserts the
/// round trip.
///
/// Sent to the reader by a screen that already KNOWS what it is
/// holding, so the reader is told rather than asked. `ScanDestination
/// .unknown` has no key, because "I do not know" is not a destination
/// and naming it would narrow the reader to nothing.
extension ScanDestinationTarget on ScanDestination {
  String? get targetKey => switch (this) {
        ScanDestination.bill => 'purchases.bill',
        ScanDestination.purchaseOrder => 'purchases.purchase_order',
        ScanDestination.goodsReceived => 'purchases.goods_received',
        ScanDestination.invoice => 'sales.invoice',
        ScanDestination.expense => 'accounting.expense',
        ScanDestination.bankStatement => 'accounting.bank_statement',
        ScanDestination.contact => 'contacts.contact',
        ScanDestination.unknown => null,
      };
}

ScanDestination? destinationFromTarget(String? target) =>
    switch (target?.trim()) {
      'purchases.bill' => ScanDestination.bill,
      'purchases.purchase_order' => ScanDestination.purchaseOrder,
      'purchases.goods_received' => ScanDestination.goodsReceived,
      'sales.invoice' => ScanDestination.invoice,
      'accounting.expense' => ScanDestination.expense,
      'accounting.bank_statement' => ScanDestination.bankStatement,
      'contacts.contact' => ScanDestination.contact,
      _ => null,
    };

/// Where a reading goes, or [ScanDestination.unknown] if nothing says.
///
/// Two sources, in this order and deliberately:
///
///  1. [OcrExtraction.target] — the reader's own judgement, made while
///     it had the page in front of it. `0681`.
///  2. [OcrExtraction.documentKind] — what the app's own classifier
///     made of the text afterwards, or what a person chose in the
///     result dialog. Resolved through [kinds] because a kind carries
///     the module and action it becomes and this file must not hold a
///     second copy of that table.
///
/// A person's choice beats both, and that is not handled here: by the
/// time somebody has picked a kind it is ON the reading, so it arrives
/// as (2).
ScanDestination destinationFor(OcrExtraction? read, List<ScanKind> kinds) {
  if (read == null) return ScanDestination.unknown;

  final fromReader = destinationFromTarget(read.target);
  if (fromReader != null) return fromReader;

  final kind = read.documentKind?.trim();
  if (kind == null || kind.isEmpty) return ScanDestination.unknown;

  for (final k in kinds) {
    if (k.code == kind) {
      return destinationFromTarget(k.targetKey) ?? ScanDestination.unknown;
    }
  }
  return ScanDestination.unknown;
}

/// The destinations somebody may pick from when nothing was detected.
///
/// [ScanDestination.unknown] is not among them: it is an answer the
/// machine may give and not one a person can choose, because choosing
/// it would mean pressing a button to do nothing.
const offerableDestinations = [
  ScanDestination.bill,
  ScanDestination.invoice,
  ScanDestination.expense,
  ScanDestination.contact,
  ScanDestination.bankStatement,
  ScanDestination.purchaseOrder,
  ScanDestination.goodsReceived,
];
