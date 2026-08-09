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

  // Purchase cycle
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
};

DocTypeMeta metaFor(String docType) =>
    docTypes[docType] ?? docTypes['invoice']!;

/// Document types shown in the type switcher, in cycle order.
Iterable<MapEntry<String, DocTypeMeta>> docTypesFor(DocKind kind) =>
    docTypes.entries.where((e) => e.value.kind == kind);
