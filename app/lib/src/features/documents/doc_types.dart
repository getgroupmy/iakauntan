import 'package:flutter/material.dart';

import '../../data/models.dart';

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
  });

  final String plural;
  final String singular;
  final IconData icon;
  final DocKind kind;

  /// Writes a journal entry when posted. Quotations and orders do not.
  final bool posts;

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
  'goods_received': DocTypeMeta(
    plural: 'Goods Received',
    singular: 'Goods Received Note',
    icon: Icons.inventory_outlined,
    kind: DocKind.purchase,
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

/// Document types shown in the type switcher, in cycle order.
Iterable<MapEntry<String, DocTypeMeta>> docTypesFor(DocKind kind) =>
    docTypes.entries.where((e) => e.value.kind == kind);
