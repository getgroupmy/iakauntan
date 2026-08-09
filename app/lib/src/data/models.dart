import '../core/format.dart';

/// Plain data models mapped straight from PostgREST JSON. They stay
/// deliberately thin — the database owns the business rules, so these
/// only need to read cleanly in the UI.

class Organization {
  Organization({
    required this.id,
    required this.name,
    required this.slug,
    this.legalName,
    this.registrationNo,
    this.tin,
    this.sstRegistrationNo,
    this.msicCode,
    this.businessActivity,
    this.addressLine1,
    this.addressLine2,
    this.city,
    this.postcode,
    this.stateCode,
    this.countryCode = 'MYS',
    this.email,
    this.phone,
    this.logoUrl,
    this.baseCurrency = 'MYR',
    this.isSstRegistered = false,
    this.einvoiceEnabled = false,
    this.einvoiceEnvironment = 'sandbox',
    this.entityType = 'sdn_bhd',
    this.roundingMethod = 'nearest_5cent',
    this.fiscalYearEndMonth = 12,
  });

  final String id;
  final String name;
  final String slug;
  final String? legalName;
  final String? registrationNo;
  final String? tin;
  final String? sstRegistrationNo;
  final String? msicCode;
  final String? businessActivity;
  final String? addressLine1;
  final String? addressLine2;
  final String? city;
  final String? postcode;
  final String? stateCode;
  final String countryCode;
  final String? email;
  final String? phone;
  final String? logoUrl;
  final String baseCurrency;
  final bool isSstRegistered;
  final bool einvoiceEnabled;
  final String einvoiceEnvironment;
  final String entityType;
  final String roundingMethod;
  final int fiscalYearEndMonth;

  factory Organization.fromJson(Map<String, dynamic> j) => Organization(
        id: j['id'] as String,
        name: j['name'] as String,
        slug: j['slug']?.toString() ?? '',
        legalName: j['legal_name'] as String?,
        registrationNo: j['registration_no'] as String?,
        tin: j['tin'] as String?,
        sstRegistrationNo: j['sst_registration_no'] as String?,
        msicCode: j['msic_code'] as String?,
        businessActivity: j['business_activity'] as String?,
        addressLine1: j['address_line1'] as String?,
        addressLine2: j['address_line2'] as String?,
        city: j['city'] as String?,
        postcode: j['postcode'] as String?,
        stateCode: j['state_code'] as String?,
        countryCode: j['country_code']?.toString() ?? 'MYS',
        email: j['email'] as String?,
        phone: j['phone'] as String?,
        logoUrl: j['logo_url'] as String?,
        baseCurrency: j['base_currency']?.toString() ?? 'MYR',
        isSstRegistered: j['is_sst_registered'] == true,
        einvoiceEnabled: j['einvoice_enabled'] == true,
        einvoiceEnvironment: j['einvoice_environment']?.toString() ?? 'sandbox',
        entityType: j['entity_type']?.toString() ?? 'sdn_bhd',
        roundingMethod: j['rounding_method']?.toString() ?? 'nearest_5cent',
        fiscalYearEndMonth: Fmt.toInt(j['fiscal_year_end_month']),
      );
}

class Contact {
  Contact({
    required this.id,
    required this.code,
    required this.name,
    required this.contactType,
    this.legalName,
    this.tin,
    this.registrationNo,
    this.idType,
    this.idValue,
    this.sstRegistrationNo,
    this.isTinVerified = false,
    this.email,
    this.phone,
    this.mobile,
    this.addressLine1,
    this.addressLine2,
    this.city,
    this.postcode,
    this.stateCode,
    this.countryCode = 'MYS',
    this.currency = 'MYR',
    this.creditLimit = 0,
    this.paymentTermId,
    this.isActive = true,
    this.entityType = 'sdn_bhd',
  });

  final String id;
  final String code;
  final String name;
  final String contactType;
  final String? legalName;
  final String? tin;
  final String? registrationNo;
  final String? idType;
  final String? idValue;
  final String? sstRegistrationNo;
  final bool isTinVerified;
  final String? email;
  final String? phone;
  final String? mobile;
  final String? addressLine1;
  final String? addressLine2;
  final String? city;
  final String? postcode;
  final String? stateCode;
  final String countryCode;
  final String currency;
  final double creditLimit;
  final String? paymentTermId;
  final bool isActive;
  final String entityType;

  bool get isCustomer => contactType == 'customer' || contactType == 'both';
  bool get isSupplier => contactType == 'supplier' || contactType == 'both';

  /// LHDN requires a buyer TIN on every B2B e-Invoice.
  bool get readyForEinvoice => (tin ?? '').isNotEmpty && (idValue ?? '').isNotEmpty;

  factory Contact.fromJson(Map<String, dynamic> j) => Contact(
        id: j['id'] as String,
        code: j['code']?.toString() ?? '',
        name: j['name'] as String,
        contactType: j['contact_type']?.toString() ?? 'customer',
        legalName: j['legal_name'] as String?,
        tin: j['tin'] as String?,
        registrationNo: j['registration_no'] as String?,
        idType: j['id_type'] as String?,
        idValue: j['id_value'] as String?,
        sstRegistrationNo: j['sst_registration_no'] as String?,
        isTinVerified: j['is_tin_verified'] == true,
        email: j['email'] as String?,
        phone: j['phone'] as String?,
        mobile: j['mobile'] as String?,
        addressLine1: j['address_line1'] as String?,
        addressLine2: j['address_line2'] as String?,
        city: j['city'] as String?,
        postcode: j['postcode'] as String?,
        stateCode: j['state_code'] as String?,
        countryCode: j['country_code']?.toString() ?? 'MYS',
        currency: j['currency']?.toString() ?? 'MYR',
        creditLimit: Fmt.toDouble(j['credit_limit']),
        paymentTermId: j['payment_term_id'] as String?,
        isActive: j['is_active'] != false,
        entityType: j['entity_type']?.toString() ?? 'sdn_bhd',
      );

  Map<String, dynamic> toJson() => {
        'code': code,
        'name': name,
        'contact_type': contactType,
        'legal_name': legalName,
        'tin': tin,
        'registration_no': registrationNo,
        'id_type': idType,
        'id_value': idValue,
        'sst_registration_no': sstRegistrationNo,
        'email': email,
        'phone': phone,
        'mobile': mobile,
        'address_line1': addressLine1,
        'address_line2': addressLine2,
        'city': city,
        'postcode': postcode,
        'state_code': stateCode,
        'country_code': countryCode,
        'currency': currency,
        'credit_limit': creditLimit,
        'is_active': isActive,
        'entity_type': entityType,
      };
}

class Item {
  Item({
    required this.id,
    required this.code,
    required this.name,
    required this.itemType,
    this.description,
    this.uomCode = 'C62',
    this.classificationCode = '022',
    this.unitPrice = 0,
    this.costPrice = 0,
    this.quantityOnHand = 0,
    this.averageCost = 0,
    this.reorderLevel = 0,
    this.trackInventory = true,
    this.isActive = true,
    this.salesTaxCodeId,
    this.purchaseTaxCodeId,
    this.categoryId,
    this.barcode,
  });

  final String id;
  final String code;
  final String name;
  final String itemType;
  final String? description;
  final String uomCode;
  final String classificationCode;
  final double unitPrice;
  final double costPrice;
  final double quantityOnHand;
  final double averageCost;
  final double reorderLevel;
  final bool trackInventory;
  final bool isActive;
  final String? salesTaxCodeId;
  final String? purchaseTaxCodeId;
  final String? categoryId;
  final String? barcode;

  bool get isLowStock =>
      trackInventory && reorderLevel > 0 && quantityOnHand <= reorderLevel;

  factory Item.fromJson(Map<String, dynamic> j) => Item(
        id: j['id'] as String,
        code: j['code']?.toString() ?? '',
        name: j['name'] as String,
        itemType: j['item_type']?.toString() ?? 'stock',
        description: j['description'] as String?,
        uomCode: j['uom_code']?.toString() ?? 'C62',
        classificationCode: j['classification_code']?.toString() ?? '022',
        unitPrice: Fmt.toDouble(j['unit_price']),
        costPrice: Fmt.toDouble(j['cost_price']),
        quantityOnHand: Fmt.toDouble(j['quantity_on_hand']),
        averageCost: Fmt.toDouble(j['average_cost']),
        reorderLevel: Fmt.toDouble(j['reorder_level']),
        trackInventory: j['track_inventory'] != false,
        isActive: j['is_active'] != false,
        salesTaxCodeId: j['sales_tax_code_id'] as String?,
        purchaseTaxCodeId: j['purchase_tax_code_id'] as String?,
        categoryId: j['category_id'] as String?,
        barcode: j['barcode'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'code': code,
        'name': name,
        'item_type': itemType,
        'description': description,
        'uom_code': uomCode,
        'classification_code': classificationCode,
        'unit_price': unitPrice,
        'cost_price': costPrice,
        'reorder_level': reorderLevel,
        'track_inventory': trackInventory,
        'is_active': isActive,
        'sales_tax_code_id': salesTaxCodeId,
        'purchase_tax_code_id': purchaseTaxCodeId,
        'category_id': categoryId,
        'barcode': barcode,
      };
}

class TaxCode {
  TaxCode({
    required this.id,
    required this.code,
    required this.name,
    required this.rate,
    required this.taxTypeCode,
    this.isDefault = false,
    this.isExempt = false,
  });

  final String id;
  final String code;
  final String name;
  final double rate;
  final String taxTypeCode;
  final bool isDefault;
  final bool isExempt;

  factory TaxCode.fromJson(Map<String, dynamic> j) => TaxCode(
        id: j['id'] as String,
        code: j['code']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        rate: Fmt.toDouble(j['rate']),
        taxTypeCode: j['tax_type_code']?.toString() ?? '06',
        isDefault: j['is_default'] == true,
        isExempt: j['is_exempt'] == true,
      );
}

class Account {
  Account({
    required this.id,
    required this.code,
    required this.name,
    required this.accountType,
    required this.accountSubtype,
    this.isGroup = false,
    this.currentBalance = 0,
    this.isActive = true,
  });

  final String id;
  final String code;
  final String name;
  final String accountType;
  final String accountSubtype;
  final bool isGroup;
  final double currentBalance;
  final bool isActive;

  factory Account.fromJson(Map<String, dynamic> j) => Account(
        id: j['id'] as String,
        code: j['code']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        accountType: j['account_type']?.toString() ?? 'asset',
        accountSubtype: j['account_subtype']?.toString() ?? 'current_asset',
        isGroup: j['is_group'] == true,
        currentBalance: Fmt.toDouble(j['current_balance']),
        isActive: j['is_active'] != false,
      );
}

class SalesDocument {
  SalesDocument({
    required this.id,
    required this.docType,
    required this.docNo,
    required this.docDate,
    required this.contactId,
    this.contactName,
    this.dueDate,
    this.reference,
    this.currency = 'MYR',
    this.subtotal = 0,
    this.discountAmount = 0,
    this.taxAmount = 0,
    this.shippingAmount = 0,
    this.roundingAmount = 0,
    this.totalAmount = 0,
    this.paidAmount = 0,
    this.balanceAmount = 0,
    this.status = 'draft',
    this.einvoiceStatus = 'not_applicable',
    this.einvoiceId,
    this.glEntryId,
    this.notes,
    this.termsConditions,
    this.paymentTermId,
    this.lines = const [],
  });

  final String id;
  final String docType;
  final String docNo;
  final DateTime docDate;
  final String contactId;
  final String? contactName;
  final DateTime? dueDate;
  final String? reference;
  final String currency;
  final double subtotal;
  final double discountAmount;
  final double taxAmount;
  final double shippingAmount;
  final double roundingAmount;
  final double totalAmount;
  final double paidAmount;
  final double balanceAmount;
  final String status;
  final String einvoiceStatus;
  final String? einvoiceId;
  final String? glEntryId;
  final String? notes;
  final String? termsConditions;
  final String? paymentTermId;
  final List<SalesLine> lines;

  bool get isPosted => glEntryId != null;
  bool get isOverdue =>
      balanceAmount > 0 &&
      dueDate != null &&
      dueDate!.isBefore(DateTime.now()) &&
      status != 'void';

  factory SalesDocument.fromJson(Map<String, dynamic> j) {
    final contact = j['contacts'];
    return SalesDocument(
      id: j['id'] as String,
      docType: j['doc_type']?.toString() ?? 'invoice',
      docNo: j['doc_no']?.toString() ?? '',
      docDate: Fmt.parseDate(j['doc_date']) ?? DateTime.now(),
      contactId: j['contact_id']?.toString() ?? '',
      contactName: contact is Map ? contact['name'] as String? : null,
      dueDate: Fmt.parseDate(j['due_date']),
      reference: j['reference'] as String?,
      currency: j['currency']?.toString() ?? 'MYR',
      subtotal: Fmt.toDouble(j['subtotal']),
      discountAmount: Fmt.toDouble(j['discount_amount']),
      taxAmount: Fmt.toDouble(j['tax_amount']),
      shippingAmount: Fmt.toDouble(j['shipping_amount']),
      roundingAmount: Fmt.toDouble(j['rounding_amount']),
      totalAmount: Fmt.toDouble(j['total_amount']),
      paidAmount: Fmt.toDouble(j['paid_amount']),
      balanceAmount: Fmt.toDouble(j['balance_amount']),
      status: j['status']?.toString() ?? 'draft',
      einvoiceStatus: j['einvoice_status']?.toString() ?? 'not_applicable',
      einvoiceId: j['einvoice_id'] as String?,
      glEntryId: j['gl_entry_id'] as String?,
      notes: j['notes'] as String?,
      termsConditions: j['terms_conditions'] as String?,
      paymentTermId: j['payment_term_id'] as String?,
      lines: (j['sales_document_lines'] as List?)
              ?.map((e) => SalesLine.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }
}

class SalesLine {
  SalesLine({
    this.id,
    required this.lineNo,
    this.itemId,
    this.description = '',
    this.quantity = 1,
    this.unitPrice = 0,
    this.discountPercent = 0,
    this.discountAmount = 0,
    this.taxCodeId,
    this.taxRate = 0,
    this.taxAmount = 0,
    this.lineSubtotal = 0,
    this.lineTotal = 0,
    this.uomCode,
    this.classificationCode,
    this.isTaxInclusive = false,
  });

  final String? id;
  final int lineNo;
  final String? itemId;
  final String description;
  final double quantity;
  final double unitPrice;
  final double discountPercent;
  final double discountAmount;
  final String? taxCodeId;
  final double taxRate;
  final double taxAmount;
  final double lineSubtotal;
  final double lineTotal;
  final String? uomCode;
  final String? classificationCode;
  final bool isTaxInclusive;

  /// Mirrors app.calc_document_line() so the editor can show live totals
  /// before the row is saved. The database remains the source of truth.
  static ({double net, double tax, double total}) compute({
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
      final net = _r((gross - discount) / (1 + taxRate / 100));
      final tax = _r(gross - discount - net);
      return (net: net, tax: tax, total: net + tax);
    }
    final net = _r(gross - discount);
    final tax = _r(net * taxRate / 100);
    return (net: net, tax: tax, total: net + tax);
  }

  static double _r(double v) => (v * 100).roundToDouble() / 100;

  factory SalesLine.fromJson(Map<String, dynamic> j) => SalesLine(
        id: j['id'] as String?,
        lineNo: Fmt.toInt(j['line_no']),
        itemId: j['item_id'] as String?,
        description: j['description']?.toString() ?? '',
        quantity: Fmt.toDouble(j['quantity']),
        unitPrice: Fmt.toDouble(j['unit_price']),
        discountPercent: Fmt.toDouble(j['discount_percent']),
        discountAmount: Fmt.toDouble(j['discount_amount']),
        taxCodeId: j['tax_code_id'] as String?,
        taxRate: Fmt.toDouble(j['tax_rate']),
        taxAmount: Fmt.toDouble(j['tax_amount']),
        lineSubtotal: Fmt.toDouble(j['line_subtotal']),
        lineTotal: Fmt.toDouble(j['line_total']),
        uomCode: j['uom_code'] as String?,
        classificationCode: j['classification_code'] as String?,
        isTaxInclusive: j['is_tax_inclusive'] == true,
      );
}

class EinvoiceDocument {
  EinvoiceDocument({
    required this.id,
    required this.internalDocNo,
    required this.status,
    required this.typeCode,
    required this.issueDate,
    this.buyerName,
    this.payableAmount = 0,
    this.myinvoisUuid,
    this.validationLink,
    this.errorMessage,
    this.validationErrors = const [],
    this.validatedAt,
    this.cancelDeadline,
    this.currency = 'MYR',
  });

  final String id;
  final String internalDocNo;
  final String status;
  final String typeCode;
  final DateTime issueDate;
  final String? buyerName;
  final double payableAmount;
  final String? myinvoisUuid;
  final String? validationLink;
  final String? errorMessage;
  final List<dynamic> validationErrors;
  final DateTime? validatedAt;
  final DateTime? cancelDeadline;
  final String currency;

  /// LHDN allows the supplier to cancel only inside a 72-hour window.
  bool get canCancel =>
      status == 'valid' &&
      cancelDeadline != null &&
      cancelDeadline!.isAfter(DateTime.now());

  Duration? get cancelWindowLeft =>
      cancelDeadline?.difference(DateTime.now());

  factory EinvoiceDocument.fromJson(Map<String, dynamic> j) => EinvoiceDocument(
        id: j['id'] as String,
        internalDocNo: j['internal_doc_no']?.toString() ?? '',
        status: j['status']?.toString() ?? 'draft',
        typeCode: j['einvoice_type_code']?.toString() ?? '01',
        issueDate: Fmt.parseDate(j['issue_date']) ?? DateTime.now(),
        buyerName: j['buyer_name'] as String?,
        payableAmount: Fmt.toDouble(j['payable_amount']),
        myinvoisUuid: j['myinvois_uuid'] as String?,
        validationLink: j['validation_link'] as String?,
        errorMessage: j['error_message'] as String?,
        validationErrors: (j['validation_errors'] as List?) ?? const [],
        validatedAt: Fmt.parseDate(j['validated_at']),
        cancelDeadline: Fmt.parseDate(j['cancel_deadline']),
        currency: j['currency']?.toString() ?? 'MYR',
      );
}

class Opportunity {
  Opportunity({
    required this.id,
    required this.opportunityNo,
    required this.name,
    required this.stageId,
    required this.pipelineId,
    this.contactId,
    this.contactName,
    this.amount = 0,
    this.probability = 0,
    this.weightedAmount = 0,
    this.status = 'open',
    this.expectedCloseDate,
    this.currency = 'MYR',
  });

  final String id;
  final String opportunityNo;
  final String name;
  final String stageId;
  final String pipelineId;
  final String? contactId;
  final String? contactName;
  final double amount;
  final double probability;
  final double weightedAmount;
  final String status;
  final DateTime? expectedCloseDate;
  final String currency;

  factory Opportunity.fromJson(Map<String, dynamic> j) {
    final contact = j['contacts'];
    return Opportunity(
      id: j['id'] as String,
      opportunityNo: j['opportunity_no']?.toString() ?? '',
      name: j['name']?.toString() ?? '',
      stageId: j['stage_id']?.toString() ?? '',
      pipelineId: j['pipeline_id']?.toString() ?? '',
      contactId: j['contact_id'] as String?,
      contactName: contact is Map ? contact['name'] as String? : null,
      amount: Fmt.toDouble(j['amount']),
      probability: Fmt.toDouble(j['probability']),
      weightedAmount: Fmt.toDouble(j['weighted_amount']),
      status: j['status']?.toString() ?? 'open',
      expectedCloseDate: Fmt.parseDate(j['expected_close_date']),
      currency: j['currency']?.toString() ?? 'MYR',
    );
  }
}

class PipelineStage {
  PipelineStage({
    required this.id,
    required this.pipelineId,
    required this.name,
    required this.probability,
    required this.stageType,
    required this.sortOrder,
    this.color,
  });

  final String id;
  final String pipelineId;
  final String name;
  final double probability;
  final String stageType;
  final int sortOrder;
  final String? color;

  factory PipelineStage.fromJson(Map<String, dynamic> j) => PipelineStage(
        id: j['id'] as String,
        pipelineId: j['pipeline_id']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        probability: Fmt.toDouble(j['probability']),
        stageType: j['stage_type']?.toString() ?? 'open',
        sortOrder: Fmt.toInt(j['sort_order']),
        color: j['color'] as String?,
      );
}

class DashboardSummary {
  DashboardSummary(this._raw);
  final Map<String, dynamic> _raw;

  double get revenue => Fmt.toDouble(_raw['revenue']);
  double get expenses => Fmt.toDouble(_raw['expenses']);
  double get profit => revenue - expenses;
  double get receivables => Fmt.toDouble(_raw['receivables']);
  double get payables => Fmt.toDouble(_raw['payables']);
  double get overdueReceivables => Fmt.toDouble(_raw['overdue_receivables']);
  double get bankBalance => Fmt.toDouble(_raw['bank_balance']);
  int get draftInvoices => Fmt.toInt(_raw['draft_invoices']);
  int get einvoicePending => Fmt.toInt(_raw['einvoice_pending']);
  int get einvoiceInvalid => Fmt.toInt(_raw['einvoice_invalid']);
  double get openOpportunities => Fmt.toDouble(_raw['open_opportunities']);
  double get weightedPipeline => Fmt.toDouble(_raw['weighted_pipeline']);
  int get activitiesDue => Fmt.toInt(_raw['activities_due']);
  int get lowStock => Fmt.toInt(_raw['low_stock']);
}
