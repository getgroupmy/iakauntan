import 'package:flutter/material.dart';

import '../../data/models.dart';
import 'document_dates.dart';

/// Everything the generic list and editor screens need to know about a
/// document type. Keeping it in one table is what lets a single editor
/// serve the whole sales and purchase cycle.
class DocTypeMeta {
  const DocTypeMeta({
    required this.plural,
    required this.singular,
    required this.icon,
    required this.kind,
    this.posts = false,
    this.einvoice = false,
    this.settles = false,
    this.postRpc,
  });

  final String plural;
  final String singular;
  final IconData icon;
  final DocKind kind;

  /// Writes a journal entry when posted. Quotations and orders do not.
  final bool posts;

  /// Which function posts it, where it is not the one for its kind.
  ///
  /// `goods_received` is the only one. A receiving note is not a bill —
  /// it accrues what is owed rather than recording it as payable — so
  /// `post_purchase_document` refuses it by name, and `0609` gave it
  /// `post_goods_received` of its own.
  final String? postRpc;

  /// Can be submitted to LHDN MyInvois.
  final bool einvoice;

  /// Carries a balance that payments are applied against.
  final bool settles;
}

const docTypes = <String, DocTypeMeta>{
  // Sales cycle
  'quotation': DocTypeMeta(
    plural: 'Quotations',
    singular: 'Quotation',
    icon: Icons.request_quote_outlined,
    kind: DocKind.sales,
  ),
  // A price in writing that is not a tax invoice: what an importer's
  // bank asks for before it opens a letter of credit, and what a
  // customer's procurement department raises a purchase order against.
  // `0081` has known `proforma → invoice` all along and so does
  // `transferTargets`; this row is the only reason neither could be
  // reached. It posts nothing, which is the whole point — a proforma
  // that wrote a journal would be an invoice with a softer name.
  'proforma': DocTypeMeta(
    plural: 'Proforma Invoices',
    singular: 'Proforma Invoice',
    icon: Icons.description_outlined,
    kind: DocKind.sales,
  ),
  'sales_order': DocTypeMeta(
    plural: 'Sales Orders',
    singular: 'Sales Order',
    icon: Icons.shopping_cart_outlined,
    kind: DocKind.sales,
  ),
  'delivery_order': DocTypeMeta(
    plural: 'Delivery Orders',
    singular: 'Delivery Order',
    icon: Icons.local_shipping_outlined,
    kind: DocKind.sales,
  ),
  'invoice': DocTypeMeta(
    plural: 'Invoices',
    singular: 'Invoice',
    icon: Icons.receipt_long_outlined,
    kind: DocKind.sales,
    posts: true,
    einvoice: true,
    settles: true,
  ),
  'credit_note': DocTypeMeta(
    plural: 'Credit Notes',
    singular: 'Credit Note',
    icon: Icons.undo_outlined,
    kind: DocKind.sales,
    posts: true,
    einvoice: true,
  ),
  'debit_note': DocTypeMeta(
    plural: 'Debit Notes',
    singular: 'Debit Note',
    icon: Icons.redo_outlined,
    kind: DocKind.sales,
    posts: true,
    einvoice: true,
  ),
  // LHDN's fourth document type, and the one that was missing.
  // MyInvois recognises 01 Invoice, 02 Credit Note, 03 Debit Note and
  // 04 Refund Note; `0015` maps all four and the app could raise three.
  // A refund note is money actually returned rather than a balance
  // written down, which is why it is not a credit note: `0013` gives it
  // the same negative sign and `0096` ages it the same way, and the
  // difference is what the customer got back.
  'refund_note': DocTypeMeta(
    plural: 'Refund Notes',
    singular: 'Refund Note',
    icon: Icons.currency_exchange_outlined,
    kind: DocKind.sales,
    posts: true,
    einvoice: true,
  ),

  // Purchase cycle
  //
  // The requisition is where it starts: somebody asks for something
  // before anybody commits to buying it. The type has been in
  // `purchase_doc_type` and the transfer chain has known
  // `purchase_request → purchase_order` all along; what it never had was
  // a row here, which is the only reason it could not be reached. It
  // posts nothing — a request is not a liability — which is exactly why
  // it needs an approval rule rather than a posting gate to mean
  // anything.
  'purchase_request': DocTypeMeta(
    plural: 'Purchase Requisitions',
    singular: 'Purchase Requisition',
    icon: Icons.playlist_add_check_outlined,
    kind: DocKind.purchase,
  ),
  'purchase_order': DocTypeMeta(
    plural: 'Purchase Orders',
    singular: 'Purchase Order',
    icon: Icons.shopping_bag_outlined,
    kind: DocKind.purchase,
  ),
  // The goods are here and the bill is not, which is a real position
  // with a real name: goods received not invoiced.
  //
  // It POSTS, which reads oddly beside the purchase order above it and
  // is the whole of `0609`. Until then the note wrote nothing anywhere
  // — no journal and, despite what `post_purchase_document` assumed, no
  // stock movement either — so ten units bought through one reached the
  // shelf nowhere. It now debits inventory and credits 2118; the bill
  // clears 2118 when it arrives.
  'goods_received': DocTypeMeta(
    plural: 'Goods Received',
    singular: 'Goods Received Note',
    icon: Icons.inventory_outlined,
    kind: DocKind.purchase,
    posts: true,
    postRpc: 'post_goods_received',
  ),
  'bill': DocTypeMeta(
    plural: 'Bills',
    singular: 'Bill',
    icon: Icons.request_page_outlined,
    kind: DocKind.purchase,
    posts: true,
    settles: true,
  ),
  'purchase_credit_note': DocTypeMeta(
    plural: 'Purchase Credit Notes',
    singular: 'Purchase Credit Note',
    icon: Icons.undo_outlined,
    kind: DocKind.purchase,
    posts: true,
  ),
  // The supplier's debit note: an undercharge they are now billing for.
  // `0013` posts it, `0096` ages it alongside the bill it belongs to,
  // and `report_sst_summary` counts its input tax — so leaving it out
  // here did not merely hide a menu entry, it put a claimable input tax
  // credit out of reach.
  //
  // Not an e-Invoice. It is the supplier's document, and submitting it
  // would be filing somebody else's under our TIN.
  'purchase_debit_note': DocTypeMeta(
    plural: 'Purchase Debit Notes',
    singular: 'Purchase Debit Note',
    icon: Icons.redo_outlined,
    kind: DocKind.purchase,
    posts: true,
  ),
};

DocTypeMeta metaFor(String docType) =>
    docTypes[docType] ?? docTypes['invoice']!;

/// Who a document of this type may be made out to: the picker's
/// contact filter, in the terms `Repo.contactTypesFor` reads.
///
/// An offer -- a quotation or a proforma, the two documents that carry
/// a validity -- may be made to a prospect. Somebody you have not sold
/// to yet is exactly who you send a quotation to, and until 0478 the
/// picker offered customers only, so quoting a prospect meant making a
/// customer record for a company that had bought nothing. The documents
/// that record a sale still pick from customers: `transfer_document`
/// lands an accepted offer on the company's customer record, and
/// refuses where there is none.
String contactTypeFor(String docType) => showsValidUntil(docType)
    ? 'customer_or_prospect'
    : metaFor(docType).kind.contactType;

/// Document types shown in the type switcher, in cycle order.
Iterable<MapEntry<String, DocTypeMeta>> docTypesFor(DocKind kind) =>
    docTypes.entries.where((e) => e.value.kind == kind);
