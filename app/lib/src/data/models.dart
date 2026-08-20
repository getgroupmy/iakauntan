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
    this.addressLine3,
    this.registeredAddressLine1,
    this.registeredAddressLine2,
    this.registeredAddressLine3,
    this.registeredPostcode,
    this.registeredCity,
    this.registeredStateCode,
    this.city,
    this.postcode,
    this.stateCode,
    this.countryCode = 'MYS',
    this.email,
    this.phone,
    this.logoUrl,
    this.baseCurrency = 'MYR',
    this.isSstRegistered = false,
    this.sstRegisteredFrom,
    this.parentOrgId,
    this.ownedPercent,
    this.usesPreprintedLetterhead = false,
    this.creditControl = 'warn',
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
  final String? addressLine3;

  /// The registered office as filed with SSM. Null throughout means the
  /// same as the business address, which is the ordinary case — a
  /// company that has never thought about the distinction is not asked
  /// to.
  final String? registeredAddressLine1;
  final String? registeredAddressLine2;
  final String? registeredAddressLine3;
  final String? registeredPostcode;
  final String? registeredCity;
  final String? registeredStateCode;

  /// True where the company has filed a registered office of its own.
  bool get hasSeparateRegisteredAddress =>
      (registeredAddressLine1 ?? '').trim().isNotEmpty;

  final String? city;
  final String? postcode;
  final String? stateCode;
  final String countryCode;
  final String? email;
  final String? phone;
  final String? logoUrl;
  final String baseCurrency;
  final bool isSstRegistered;

  /// The date registration took effect. Once it is set, a document dated
  /// before it may not carry tax — see 0145.
  final DateTime? sstRegisteredFrom;

  /// The company in the same group that owns this one, and how much of
  /// it. Both null until somebody records it — and until they do, the
  /// consolidated report refuses, because whether the whole of a
  /// subsidiary belongs to the group is the question minority interest
  /// turns on. See 0148.
  final String? parentOrgId;
  final double? ownedPercent;

  /// The company prints onto its own letterhead paper, so the generated
  /// PDFs leave room for a header rather than drawing one.
  final bool usesPreprintedLetterhead;

  /// off | warn | block — what happens when an invoice would take a
  /// customer past their credit limit.
  final String creditControl;

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
    addressLine3: j['address_line3'] as String?,
    registeredAddressLine1: j['registered_address_line1'] as String?,
    registeredAddressLine2: j['registered_address_line2'] as String?,
    registeredAddressLine3: j['registered_address_line3'] as String?,
    registeredPostcode: j['registered_postcode'] as String?,
    registeredCity: j['registered_city'] as String?,
    registeredStateCode: j['registered_state_code'] as String?,
    city: j['city'] as String?,
    postcode: j['postcode'] as String?,
    stateCode: j['state_code'] as String?,
    countryCode: j['country_code']?.toString() ?? 'MYS',
    email: j['email'] as String?,
    phone: j['phone'] as String?,
    logoUrl: j['logo_url'] as String?,
    baseCurrency: j['base_currency']?.toString() ?? 'MYR',
    isSstRegistered: j['is_sst_registered'] == true,
    sstRegisteredFrom: j['sst_registered_from'] == null
        ? null
        : DateTime.tryParse(j['sst_registered_from'].toString()),
    usesPreprintedLetterhead: j['uses_preprinted_letterhead'] == true,
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
    this.addressLine3,
    this.registeredAddressLine1,
    this.registeredAddressLine2,
    this.registeredAddressLine3,
    this.registeredPostcode,
    this.registeredCity,
    this.registeredStateCode,
    this.city,
    this.postcode,
    this.stateCode,
    this.countryCode = 'MYS',
    this.currency = 'MYR',
    this.creditLimit = 0,
    this.paymentTermId,
    this.priceLevelId,
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
  final String? addressLine3;

  /// The registered office as filed with SSM. Null throughout means the
  /// same as the business address, which is the ordinary case — a
  /// company that has never thought about the distinction is not asked
  /// to.
  final String? registeredAddressLine1;
  final String? registeredAddressLine2;
  final String? registeredAddressLine3;
  final String? registeredPostcode;
  final String? registeredCity;
  final String? registeredStateCode;

  /// True where the company has filed a registered office of its own.
  bool get hasSeparateRegisteredAddress =>
      (registeredAddressLine1 ?? '').trim().isNotEmpty;

  final String? city;
  final String? postcode;
  final String? stateCode;
  final String countryCode;
  final String currency;
  final double creditLimit;
  final String? paymentTermId;

  /// Which price list this customer buys on. Null falls back to the
  /// organization's default level, and then to the item's list price.
  final String? priceLevelId;
  final bool isActive;
  final String entityType;

  bool get isCustomer => contactType == 'customer' || contactType == 'both';
  bool get isSupplier => contactType == 'supplier' || contactType == 'both';

  /// LHDN requires a buyer TIN on every B2B e-Invoice.
  bool get readyForEinvoice =>
      (tin ?? '').isNotEmpty && (idValue ?? '').isNotEmpty;

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
    priceLevelId: j['price_level_id'] as String?,
    isActive: j['is_active'] != false,
    entityType: j['entity_type']?.toString() ?? 'sdn_bhd',
  );

  /// The same contact under a different code, for the one caller that
  /// has to try more than one — see
  /// [Repo.createContactWithGeneratedCode].
  Contact withCode(String value) => Contact(
    id: id,
    code: value,
    name: name,
    contactType: contactType,
    legalName: legalName,
    tin: tin,
    registrationNo: registrationNo,
    idType: idType,
    idValue: idValue,
    sstRegistrationNo: sstRegistrationNo,
    isTinVerified: isTinVerified,
    email: email,
    phone: phone,
    mobile: mobile,
    addressLine1: addressLine1,
    addressLine2: addressLine2,
    city: city,
    postcode: postcode,
    stateCode: stateCode,
    countryCode: countryCode,
    currency: currency,
    creditLimit: creditLimit,
    paymentTermId: paymentTermId,
    priceLevelId: priceLevelId,
    isActive: isActive,
    entityType: entityType,
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
    'price_level_id': priceLevelId,
    'is_active': isActive,
    'entity_type': entityType,
  };
}

/// A row of `ref_currencies`. Shared across every tenant, so it is read
/// once and cached rather than fetched per organization.
class Currency {
  const Currency({
    required this.code,
    required this.name,
    this.symbol,
    this.decimalPlaces = 2,
  });

  final String code;
  final String name;
  final String? symbol;

  /// Yen and won have none. Kept because a rate field that offers cents
  /// on a currency without them invites a figure that cannot be paid.
  final int decimalPlaces;

  /// "USD — US Dollar", which is how a picker has to read: the code is
  /// what appears on the invoice, the name is what makes it findable.
  String get label => '$code — $name';

  factory Currency.fromJson(Map<String, dynamic> j) => Currency(
    code: j['code']?.toString() ?? '',
    name: j['name']?.toString() ?? '',
    symbol: j['symbol'] as String?,
    decimalPlaces: (j['decimal_places'] as num?)?.toInt() ?? 2,
  );
}

/// One currency's worth of open foreign balances, as at a date: what the
/// books carry, what they would carry at the closing rate, and the
/// difference between the two.
class FxRevaluation {
  const FxRevaluation({
    required this.currency,
    required this.closingRate,
    required this.documents,
    required this.booked,
    required this.restated,
    required this.difference,
  });

  final String currency;
  final double closingRate;
  final int documents;

  /// Net of receivables less payables, at the rates the documents were
  /// raised at. Signed: a net payable position is negative.
  final double booked;
  final double restated;

  /// Positive is a gain — more asset, or less liability, than booked.
  final double difference;

  factory FxRevaluation.fromJson(Map<String, dynamic> j) => FxRevaluation(
    currency: j['currency']?.toString().trim() ?? '',
    closingRate: Fmt.toDouble(j['closing_rate']),
    documents: (j['documents'] as num?)?.toInt() ?? 0,
    booked: Fmt.toDouble(j['booked']),
    restated: Fmt.toDouble(j['restated']),
    difference: Fmt.toDouble(j['difference']),
  );
}

/// One line of the fixed asset register.
class FixedAsset {
  const FixedAsset({
    required this.id,
    required this.assetNo,
    required this.name,
    required this.acquisitionDate,
    required this.cost,
    this.description,
    this.category,
    this.residualValue = 0,
    this.method = 'straight_line',
    this.usefulLifeMonths,
    this.ratePercent,
    this.accumulatedDepreciation = 0,
    this.depreciatedTo,
    this.serialNo,
    this.location,
    this.status = 'active',
    this.disposalDate,
    this.disposalProceeds,
    this.notes,
  });

  final String id;
  final String assetNo;
  final String name;
  final String? description;
  final String? category;
  final DateTime acquisitionDate;
  final double cost;

  /// What it is expected to be worth at the end of its life. Never
  /// depreciated below this.
  final double residualValue;

  /// 'straight_line' or 'reducing_balance'.
  final String method;
  final int? usefulLifeMonths;

  /// Annual rate, for reducing balance.
  final double? ratePercent;

  final double accumulatedDepreciation;
  final DateTime? depreciatedTo;
  final String? serialNo;
  final String? location;
  final String status;
  final DateTime? disposalDate;
  final double? disposalProceeds;
  final String? notes;

  double get netBookValue => cost - accumulatedDepreciation;
  bool get isDisposed => status == 'disposed';

  /// How the life reads on a register: "5 years" or "20% reducing".
  String get basis => method == 'reducing_balance'
      ? '${Fmt.rate(ratePercent ?? 0)}% reducing'
      : usefulLifeMonths == null
      ? 'Straight line'
      : usefulLifeMonths! % 12 == 0
      ? '${usefulLifeMonths! ~/ 12} year straight line'
      : '$usefulLifeMonths month straight line';

  factory FixedAsset.fromJson(Map<String, dynamic> j) => FixedAsset(
    id: j['id'] as String,
    assetNo: j['asset_no']?.toString() ?? '',
    name: j['name']?.toString() ?? '',
    description: j['description'] as String?,
    category: j['category'] as String?,
    acquisitionDate: Fmt.parseDate(j['acquisition_date']) ?? DateTime.now(),
    cost: Fmt.toDouble(j['cost']),
    residualValue: Fmt.toDouble(j['residual_value']),
    method: j['method']?.toString() ?? 'straight_line',
    usefulLifeMonths: (j['useful_life_months'] as num?)?.toInt(),
    ratePercent: j['rate_percent'] == null
        ? null
        : Fmt.toDouble(j['rate_percent']),
    accumulatedDepreciation: Fmt.toDouble(j['accumulated_depreciation']),
    depreciatedTo: Fmt.parseDate(j['depreciated_to']),
    serialNo: j['serial_no'] as String?,
    location: j['location'] as String?,
    status: j['status']?.toString() ?? 'active',
    disposalDate: Fmt.parseDate(j['disposal_date']),
    disposalProceeds: j['disposal_proceeds'] == null
        ? null
        : Fmt.toDouble(j['disposal_proceeds']),
    notes: j['notes'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'asset_no': assetNo,
    'name': name,
    'description': description,
    'category': category,
    'acquisition_date': Fmt.iso(acquisitionDate),
    'cost': cost,
    'residual_value': residualValue,
    'method': method,
    // Only the figure this method needs is sent. The table refuses a
    // straight-line asset with no life and a reducing-balance one
    // with no rate, and sending both would let a stale value from
    // the other method sit there looking authoritative.
    'useful_life_months': method == 'straight_line' ? usefulLifeMonths : null,
    'rate_percent': method == 'reducing_balance' ? ratePercent : null,
    'serial_no': serialNo,
    'location': location,
    'notes': notes,
  };
}

/// What a depreciation run would charge against one asset.
class DepreciationLine {
  const DepreciationLine({
    required this.assetId,
    required this.assetNo,
    required this.name,
    required this.cost,
    required this.accumulated,
    required this.charge,
    required this.netBookValue,
  });

  final String assetId;
  final String assetNo;
  final String name;
  final double cost;
  final double accumulated;
  final double charge;
  final double netBookValue;

  factory DepreciationLine.fromJson(Map<String, dynamic> j) => DepreciationLine(
    assetId: j['asset_id'] as String,
    assetNo: j['asset_no']?.toString() ?? '',
    name: j['name']?.toString() ?? '',
    cost: Fmt.toDouble(j['cost']),
    accumulated: Fmt.toDouble(j['accumulated']),
    charge: Fmt.toDouble(j['charge']),
    netBookValue: Fmt.toDouble(j['net_book_value']),
  );
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
    this.tracking = 'none',
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

  /// `none`, `batch` or `serial`. Identity, not cost: a serialised item
  /// still values at weighted average, because making it cost-specific
  /// would restate every figure already filed.
  final String tracking;
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
    tracking: j['tracking']?.toString() ?? 'none',
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
    'tracking': trackInventory ? tracking : 'none',
    'is_active': isActive,
    'sales_tax_code_id': salesTaxCodeId,
    'purchase_tax_code_id': purchaseTaxCodeId,
    'category_id': categoryId,
    'barcode': barcode,
  };
}

/// A fiscal year and the twelve periods under it.
///
/// Nothing posts to a date no period covers, so the year that has not
/// been created yet is the year the books stop working.
class FiscalYear {
  FiscalYear({
    required this.id,
    required this.name,
    required this.startDate,
    required this.endDate,
    this.status = 'open',
    this.periods = const [],
  });

  final String id;
  final String name;
  final DateTime startDate;
  final DateTime endDate;
  final String status;
  final List<FiscalPeriod> periods;

  bool covers(DateTime day) =>
      !day.isBefore(startDate) && !day.isAfter(endDate);

  factory FiscalYear.fromJson(Map<String, dynamic> j) => FiscalYear(
    id: j['id'] as String,
    name: j['name']?.toString() ?? '',
    startDate: Fmt.parseDate(j['start_date'])!,
    endDate: Fmt.parseDate(j['end_date'])!,
    status: j['status']?.toString() ?? 'open',
    periods: [
      for (final p in (j['fiscal_periods'] as List? ?? const []))
        FiscalPeriod.fromJson(Map<String, dynamic>.from(p as Map)),
    ]..sort((a, b) => a.periodNo.compareTo(b.periodNo)),
  );
}

class FiscalPeriod {
  FiscalPeriod({
    required this.id,
    required this.periodNo,
    required this.name,
    required this.startDate,
    required this.endDate,
    this.status = 'open',
  });

  final String id;
  final int periodNo;
  final String name;
  final DateTime startDate;
  final DateTime endDate;
  final String status;

  bool get isOpen => status == 'open';

  /// Locked is terminal — it is what year-end sign-off means, so the UI
  /// must not offer to reopen it.
  bool get isLocked => status == 'locked';

  factory FiscalPeriod.fromJson(Map<String, dynamic> j) => FiscalPeriod(
    id: j['id'] as String,
    periodNo: Fmt.toInt(j['period_no']),
    name: j['name']?.toString() ?? '',
    startDate: Fmt.parseDate(j['start_date'])!,
    endDate: Fmt.parseDate(j['end_date'])!,
    status: j['status']?.toString() ?? 'open',
  );
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

/// Which side of the ledger a document belongs to. The sales and purchase
/// tables are deliberately the same shape, so this is all the editor and
/// list screens need to switch between them.
enum DocKind { sales, purchase }

extension DocKindX on DocKind {
  bool get isSales => this == DocKind.sales;

  String get table => isSales ? 'sales_documents' : 'purchase_documents';
  String get lineTable =>
      isSales ? 'sales_document_lines' : 'purchase_document_lines';

  /// Which contacts may be chosen on this kind of document.
  String get contactType => isSales ? 'customer' : 'supplier';
  String get contactLabel => isSales ? 'Customer' : 'Supplier';

  String get postRpc =>
      isSales ? 'post_sales_document' : 'post_purchase_document';

  String get routePrefix => isSales ? '/sales' : '/purchases';
}

/// A sales or purchase document header. The two tables share a shape, so
/// one model serves both and the editor screens stay generic.
class BusinessDocument {
  BusinessDocument({
    required this.id,
    required this.docType,
    required this.docNo,
    required this.docDate,
    required this.contactId,
    this.contactName,
    this.dueDate,
    this.reference,
    this.supplierDocNo,
    this.currency = 'MYR',
    this.exchangeRate = 1,
    this.subtotal = 0,
    this.discountAmount = 0,
    this.taxAmount = 0,
    this.shippingAmount = 0,
    this.roundingAmount = 0,
    this.totalAmount = 0,
    this.paidAmount = 0,
    this.balanceAmount = 0,
    this.status = 'draft',
    this.fulfilmentStatus = 'pending',
    this.einvoiceStatus = 'not_applicable',
    this.einvoiceId,
    this.glEntryId,
    this.notes,
    this.termsConditions,
    this.paymentTermId,
    this.salespersonId,
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

  /// The supplier's own invoice number. Purchase documents only.
  final String? supplierDocNo;
  final String currency;

  /// Units of base currency per unit of [currency], frozen at the moment
  /// the document was raised. Every posting multiplies by this and not
  /// by today's rate, which is what makes the gain or loss on settlement
  /// computable at all.
  final double exchangeRate;
  final double subtotal;
  final double discountAmount;
  final double taxAmount;
  final double shippingAmount;
  final double roundingAmount;
  final double totalAmount;
  final double paidAmount;
  final double balanceAmount;
  final String status;

  /// How much of this document has been taken forward into the next one
  /// in its cycle: pending, partial, fulfilled or cancelled. Maintained
  /// by the database from the lines that were transferred out of it.
  final String fulfilmentStatus;
  final String einvoiceStatus;
  final String? einvoiceId;
  final String? glEntryId;
  final String? notes;
  final String? termsConditions;
  final String? paymentTermId;

  /// Who won the order. Sales documents only, and optional — plenty of
  /// businesses never attribute a sale to anyone, and the report says so
  /// out loud rather than quietly dropping what nobody was credited with.
  final String? salespersonId;
  final List<DocumentLine> lines;

  bool get isPosted => glEntryId != null;
  bool get isOverdue =>
      balanceAmount > 0 &&
      dueDate != null &&
      dueDate!.isBefore(DateTime.now()) &&
      status != 'void';

  factory BusinessDocument.fromJson(Map<String, dynamic> j) {
    final contact = j['contacts'];
    // The embedded line list is named after whichever table it came from.
    final rawLines =
        (j['sales_document_lines'] ?? j['purchase_document_lines']) as List?;
    return BusinessDocument(
      id: j['id'] as String,
      docType: j['doc_type']?.toString() ?? 'invoice',
      docNo: j['doc_no']?.toString() ?? '',
      docDate: Fmt.parseDate(j['doc_date']) ?? DateTime.now(),
      contactId: j['contact_id']?.toString() ?? '',
      contactName: contact is Map ? contact['name'] as String? : null,
      dueDate: Fmt.parseDate(j['due_date']),
      reference: j['reference'] as String?,
      supplierDocNo: j['supplier_doc_no'] as String?,
      currency: j['currency']?.toString() ?? 'MYR',
      exchangeRate: j['exchange_rate'] == null
          ? 1
          : Fmt.toDouble(j['exchange_rate']),
      subtotal: Fmt.toDouble(j['subtotal']),
      discountAmount: Fmt.toDouble(j['discount_amount']),
      taxAmount: Fmt.toDouble(j['tax_amount']),
      shippingAmount: Fmt.toDouble(j['shipping_amount']),
      roundingAmount: Fmt.toDouble(j['rounding_amount']),
      totalAmount: Fmt.toDouble(j['total_amount']),
      paidAmount: Fmt.toDouble(j['paid_amount']),
      balanceAmount: Fmt.toDouble(j['balance_amount']),
      status: j['status']?.toString() ?? 'draft',
      fulfilmentStatus: j['fulfilment_status']?.toString() ?? 'pending',
      einvoiceStatus: j['einvoice_status']?.toString() ?? 'not_applicable',
      einvoiceId: j['einvoice_id'] as String?,
      glEntryId: j['gl_entry_id'] as String?,
      notes: j['notes'] as String?,
      termsConditions: j['terms_conditions'] as String?,
      paymentTermId: j['payment_term_id'] as String?,
      salespersonId: j['salesperson_id'] as String?,
      lines:
          (rawLines ?? const [])
              .map((e) => DocumentLine.fromJson(e as Map<String, dynamic>))
              .toList()
            ..sort((a, b) => a.lineNo.compareTo(b.lineNo)),
    );
  }
}

class DocumentLine {
  DocumentLine({
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
    this.warehouseId,
    this.sourceLineId,
    this.projectCode,
    this.departmentCode,
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
  final String? warehouseId;

  /// The line on an earlier document this was transferred from. Carried
  /// through the editor because saving deletes and re-inserts the lines,
  /// and a line that came back without it would release the quantity on
  /// the order it came from — which could then be ordered twice.
  final String? sourceLineId;
  final String? projectCode;

  /// The part of the business this line belongs to. Carried for the same
  /// reason as the project: `gl_lines.department_code` is what the
  /// by-dimension P&L reads, and it can only hold what the document line
  /// put there.
  final String? departmentCode;

  factory DocumentLine.fromJson(Map<String, dynamic> j) => DocumentLine(
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
    warehouseId: j['warehouse_id'] as String?,
    sourceLineId: j['source_line_id'] as String?,
    projectCode: j['project_code'] as String?,
    departmentCode: j['department_code'] as String?,
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

  Duration? get cancelWindowLeft => cancelDeadline?.difference(DateTime.now());

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

// =====================================================================
// Access control
// =====================================================================

/// The roles a company can assign, with the wording used in the UI.
/// Ownership is transferred rather than granted, so it is not offered
/// when inviting someone.
const memberRoles = <String, ({String label, String description})>{
  'owner': (
    label: 'Owner',
    description: 'Full control including billing and closing the company',
  ),
  'admin': (
    label: 'Company Admin',
    description: 'Everything except ownership transfer',
  ),
  'accountant': (
    label: 'Accountant',
    description: 'Prepares and posts to the ledger, closes periods',
  ),
  'accounts_clerk': (
    label: 'Accounts Clerk',
    description: 'Prepares documents but cannot post to the ledger',
  ),
  'auditor': (
    label: 'Auditor',
    description:
        'Reads everything including the ledger and audit trail; changes nothing',
  ),
  'sales': (label: 'Sales', description: 'CRM and sales documents'),
  'purchaser': (label: 'Purchasing', description: 'Purchase documents'),
  'viewer': (
    label: 'View Only',
    description: 'Read-only access to day-to-day records',
  ),
};

String roleLabel(String? role) => memberRoles[role]?.label ?? Fmt.label(role);

/// What an approval rule covers, in words. A null `docType` means every
/// document of that kind, which is what the column's null means.
///
/// Deliberately not built from `docTypes` in the documents feature: a
/// journal is not a document type at all, and the three-way switch here
/// is the same three-way switch `app.approval_entity` has.
String approvalEntityLabel(String? entityKind, Object? docType) {
  final scope = docType == null ? null : Fmt.label(docType.toString());
  return switch (entityKind) {
    'sales_document' => scope == null ? 'Every sales document' : '${scope}s',
    'purchase_document' =>
      scope == null ? 'Every purchase document' : '${scope}s',
    _ => 'Manual journals',
  };
}

class TeamMember {
  TeamMember({
    required this.memberId,
    required this.role,
    required this.status,
    this.userId,
    this.email,
    this.fullName,
    this.joinedAt,
    this.accessTypeId,
    this.accessTypeName,
  });

  final String memberId;
  final String? userId;
  final String? email;
  final String? fullName;
  final String role;
  final String status;
  final DateTime? joinedAt;

  /// Null where nobody has narrowed this person's access, which is how
  /// every member stands until a company defines an access type.
  final String? accessTypeId;
  final String? accessTypeName;

  bool get isPending => status == 'invited';
  String get displayName =>
      (fullName ?? '').trim().isNotEmpty ? fullName! : (email ?? 'Unknown');

  factory TeamMember.fromJson(Map<String, dynamic> j) => TeamMember(
    memberId: j['member_id'] as String,
    userId: j['user_id'] as String?,
    email: j['email'] as String?,
    fullName: j['full_name'] as String?,
    role: j['role']?.toString() ?? 'viewer',
    status: j['status']?.toString() ?? 'active',
    joinedAt: Fmt.parseDate(j['joined_at']),
    accessTypeId: j['access_type_id'] as String?,
    accessTypeName: j['access_type_name'] as String?,
  );
}

/// A named set of module permissions a company defines for itself.
///
/// The ten built-in roles say what *kind* of thing somebody may do —
/// post to the ledger, run payroll, administer the company. An access
/// type says which *modules* they may reach and whether they may change
/// anything there. Both have to say yes; an access type can only take
/// away.
class AccessType {
  AccessType({
    required this.id,
    required this.name,
    this.description,
    this.isActive = true,
    this.modules = const {},
  });

  final String id;
  final String name;
  final String? description;
  final bool isActive;

  /// Module code to one of `none`, `read`, `write`. A module absent from
  /// the map is `none` — an access type grants what it lists and nothing
  /// else, so forgetting one denies it rather than opening it.
  final Map<String, String> modules;

  String accessTo(String moduleCode) => modules[moduleCode] ?? 'none';

  int get grantedCount =>
      modules.values.where((a) => a == 'read' || a == 'write').length;

  factory AccessType.fromJson(Map<String, dynamic> j) => AccessType(
    id: j['id'] as String,
    name: j['name']?.toString() ?? '',
    description: j['description'] as String?,
    isActive: j['is_active'] != false,
    modules: {
      for (final m in (j['access_type_modules'] as List? ?? const []))
        (m as Map)['module_code'].toString(): m['access']?.toString() ?? 'none',
    },
  );
}

// =====================================================================
// Platform administration
// =====================================================================

class ModuleInfo {
  ModuleInfo({
    required this.code,
    required this.name,
    required this.isCore,
    required this.monthlyPrice,
    this.description,
  });

  final String code;
  final String name;
  final String? description;
  final bool isCore;
  final double monthlyPrice;

  factory ModuleInfo.fromJson(Map<String, dynamic> j) => ModuleInfo(
    code: j['code'] as String,
    name: j['name'] as String,
    description: j['description'] as String?,
    isCore: j['is_core'] == true,
    monthlyPrice: Fmt.toDouble(j['monthly_price']),
  );
}

/// One module as this company sees it: whether it holds it, whether it
/// has put it away, and what it costs.
///
/// `entitled` and `visible` are deliberately separate. Entitlement is a
/// permission and decides what the API answers; visibility is a
/// preference and decides what the navigation shows. A company can put
/// away a module it pays for -- the screens go, the ledger behind them
/// does not.
class ModuleSurface {
  ModuleSurface({
    required this.code,
    required this.name,
    required this.isCore,
    required this.monthlyPrice,
    required this.entitled,
    required this.hidden,
    required this.visible,
    this.description,
  });

  final String code;
  final String name;
  final String? description;
  final bool isCore;
  final double monthlyPrice;
  final bool entitled;
  final bool hidden;
  final bool visible;

  factory ModuleSurface.fromMap(Map<String, dynamic> j) => ModuleSurface(
    code: j['module_code'] as String,
    name: j['name'] as String,
    description: j['description'] as String?,
    isCore: j['is_core'] == true,
    monthlyPrice: Fmt.toDouble(j['monthly_price']),
    entitled: j['entitled'] == true,
    hidden: j['hidden'] == true,
    visible: j['visible'] == true,
  );
}

class PlatformOrg {
  PlatformOrg({
    required this.id,
    required this.name,
    required this.status,
    required this.memberCount,
    required this.invoiceCount,
    required this.invoicedValue,
    required this.modules,
    this.registrationNo,
    this.tin,
    this.einvoiceEnabled = false,
    this.createdAt,
  });

  final String id;
  final String name;
  final String status;
  final String? registrationNo;
  final String? tin;
  final bool einvoiceEnabled;
  final int memberCount;
  final int invoiceCount;
  final double invoicedValue;
  final List<String> modules;
  final DateTime? createdAt;

  factory PlatformOrg.fromJson(Map<String, dynamic> j) => PlatformOrg(
    id: j['id'] as String,
    name: j['name'] as String,
    status: j['status']?.toString() ?? 'active',
    registrationNo: j['registration_no'] as String?,
    tin: j['tin'] as String?,
    einvoiceEnabled: j['einvoice_enabled'] == true,
    memberCount: Fmt.toInt(j['member_count']),
    invoiceCount: Fmt.toInt(j['invoice_count']),
    invoicedValue: Fmt.toDouble(j['invoiced_value']),
    modules: ((j['modules'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList(),
    createdAt: Fmt.parseDate(j['created_at']),
  );
}

// =====================================================================
// Legal firm accounting
// =====================================================================

class Matter {
  Matter({
    required this.id,
    required this.matterNo,
    required this.name,
    required this.clientId,
    required this.status,
    this.clientName,
    this.matterType,
    this.practiceArea,
    this.courtReference,
    this.hourlyRate = 0,
    this.estimatedFees = 0,
    this.depositRequired = 0,
    this.openedDate,
    this.currency = 'MYR',
  });

  final String id;
  final String matterNo;
  final String name;
  final String clientId;
  final String? clientName;
  final String status;
  final String? matterType;
  final String? practiceArea;
  final String? courtReference;
  final double hourlyRate;
  final double estimatedFees;
  final double depositRequired;
  final DateTime? openedDate;
  final String currency;

  factory Matter.fromJson(Map<String, dynamic> j) {
    final client = j['contacts'];
    return Matter(
      id: j['id'] as String,
      matterNo: j['matter_no']?.toString() ?? '',
      name: j['name']?.toString() ?? '',
      clientId: j['client_id']?.toString() ?? '',
      clientName: client is Map ? client['name'] as String? : null,
      status: j['status']?.toString() ?? 'open',
      matterType: j['matter_type'] as String?,
      practiceArea: j['practice_area'] as String?,
      courtReference: j['court_reference'] as String?,
      hourlyRate: Fmt.toDouble(j['hourly_rate']),
      estimatedFees: Fmt.toDouble(j['estimated_fees']),
      depositRequired: Fmt.toDouble(j['deposit_required']),
      openedDate: Fmt.parseDate(j['opened_date']),
      currency: j['currency']?.toString() ?? 'MYR',
    );
  }
}

class MatterSummary {
  MatterSummary({
    required this.matterId,
    required this.matterNo,
    required this.matterName,
    required this.clientName,
    required this.status,
    required this.clientFunds,
    required this.unbilledTime,
    required this.unbilledDisbursements,
    required this.billed,
    required this.outstanding,
  });

  final String matterId;
  final String matterNo;
  final String matterName;
  final String clientName;
  final String status;
  final double clientFunds;
  final double unbilledTime;
  final double unbilledDisbursements;
  final double billed;
  final double outstanding;

  double get workInProgress => unbilledTime + unbilledDisbursements;

  factory MatterSummary.fromJson(Map<String, dynamic> j) => MatterSummary(
    matterId: j['matter_id'] as String,
    matterNo: j['matter_no']?.toString() ?? '',
    matterName: j['matter_name']?.toString() ?? '',
    clientName: j['client_name']?.toString() ?? '',
    status: j['status']?.toString() ?? 'open',
    clientFunds: Fmt.toDouble(j['client_funds']),
    unbilledTime: Fmt.toDouble(j['unbilled_time']),
    unbilledDisbursements: Fmt.toDouble(j['unbilled_disbursements']),
    billed: Fmt.toDouble(j['billed']),
    outstanding: Fmt.toDouble(j['outstanding']),
  );
}

class ClientTransaction {
  ClientTransaction({
    required this.id,
    required this.transactionNo,
    required this.transactionDate,
    required this.transactionType,
    required this.amount,
    required this.status,
    this.description,
    this.payee,
    this.reference,
  });

  final String id;
  final String transactionNo;
  final DateTime transactionDate;
  final String transactionType;
  final double amount;
  final String status;
  final String? description;
  final String? payee;
  final String? reference;

  bool get isMoneyIn => amount >= 0;

  factory ClientTransaction.fromJson(Map<String, dynamic> j) =>
      ClientTransaction(
        id: j['id'] as String,
        transactionNo: j['transaction_no']?.toString() ?? '',
        transactionDate: Fmt.parseDate(j['transaction_date']) ?? DateTime.now(),
        transactionType: j['transaction_type']?.toString() ?? 'receipt',
        amount: Fmt.toDouble(j['amount']),
        status: j['status']?.toString() ?? 'draft',
        description: j['description'] as String?,
        payee: j['payee'] as String?,
        reference: j['reference'] as String?,
      );
}

class TimeEntry {
  TimeEntry({
    required this.id,
    required this.entryDate,
    required this.description,
    required this.minutes,
    required this.hourlyRate,
    required this.amount,
    required this.isBillable,
    required this.isBilled,
    this.activityCode,
  });

  final String id;
  final DateTime entryDate;
  final String description;
  final int minutes;
  final double hourlyRate;
  final double amount;
  final bool isBillable;
  final bool isBilled;
  final String? activityCode;

  String get duration {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return h == 0 ? '${m}m' : (m == 0 ? '${h}h' : '${h}h ${m}m');
  }

  factory TimeEntry.fromJson(Map<String, dynamic> j) => TimeEntry(
    id: j['id'] as String,
    entryDate: Fmt.parseDate(j['entry_date']) ?? DateTime.now(),
    description: j['description']?.toString() ?? '',
    minutes: Fmt.toInt(j['minutes']),
    hourlyRate: Fmt.toDouble(j['hourly_rate']),
    amount: Fmt.toDouble(j['amount']),
    isBillable: j['is_billable'] != false,
    isBilled: j['is_billed'] == true,
    activityCode: j['activity_code'] as String?,
  );
}

// =====================================================================
// HRMS
// =====================================================================

class Employee {
  Employee({
    required this.id,
    required this.employeeNo,
    required this.fullName,
    this.email,
    this.phone,
    this.photoUrl,
    this.departmentName,
    this.positionTitle,
    this.managerName,
    this.employmentStatus = 'active',
    this.employmentType = 'full_time',
    this.hireDate,
    this.basicSalary = 0,
    this.nric,
    this.epfNo,
    this.socsoNo,
    this.incomeTaxNo,
    this.bankName,
    this.bankAccountNo,
    this.maritalStatus = 'single',
    this.residencyStatus = 'citizen',
    this.dateOfBirth,
    this.userId,
  });

  final String id;
  final String employeeNo;
  final String fullName;
  final String? email;
  final String? phone;
  final String? photoUrl;
  final String? departmentName;
  final String? positionTitle;
  final String? managerName;
  final String employmentStatus;
  final String employmentType;
  final DateTime? hireDate;
  final double basicSalary;
  final String? nric;
  final String? epfNo;
  final String? socsoNo;
  final String? incomeTaxNo;
  final String? bankName;
  final String? bankAccountNo;
  final String maritalStatus;
  final String residencyStatus;
  final DateTime? dateOfBirth;
  final String? userId;

  /// True when this row came from the directory function, which carries
  /// no pay data — used to hide salary rather than show a false zero.
  bool get isDirectoryOnly => basicSalary == 0 && nric == null;

  factory Employee.fromJson(Map<String, dynamic> j) {
    final dept = j['departments'];
    final pos = j['positions'];
    return Employee(
      id: j['id'] as String,
      employeeNo: j['employee_no']?.toString() ?? '',
      fullName: j['full_name']?.toString() ?? '',
      email: j['email']?.toString(),
      phone: j['phone']?.toString(),
      photoUrl: j['photo_url']?.toString(),
      departmentName:
          j['department_name']?.toString() ??
          (dept is Map ? dept['name'] as String? : null),
      positionTitle:
          j['position_title']?.toString() ??
          (pos is Map ? pos['title'] as String? : null),
      managerName: j['manager_name']?.toString(),
      employmentStatus: j['employment_status']?.toString() ?? 'active',
      employmentType: j['employment_type']?.toString() ?? 'full_time',
      hireDate: Fmt.parseDate(j['hire_date']),
      basicSalary: Fmt.toDouble(j['basic_salary']),
      nric: j['nric']?.toString(),
      epfNo: j['epf_no']?.toString(),
      socsoNo: j['socso_no']?.toString(),
      incomeTaxNo: j['income_tax_no']?.toString(),
      bankName: j['bank_name']?.toString(),
      bankAccountNo: j['bank_account_no']?.toString(),
      maritalStatus: j['marital_status']?.toString() ?? 'single',
      residencyStatus: j['residency_status']?.toString() ?? 'citizen',
      dateOfBirth: Fmt.parseDate(j['date_of_birth']),
      userId: j['user_id']?.toString(),
    );
  }
}

class AttendanceRecord {
  AttendanceRecord({
    required this.id,
    required this.workDate,
    required this.status,
    this.employeeName,
    this.clockIn,
    this.clockOut,
    this.workedMinutes = 0,
    this.lateMinutes = 0,
    this.otMinutes = 0,
    this.clockInMethod,
    this.clockInAddress,
  });

  final String id;
  final DateTime workDate;
  final String status;
  final String? employeeName;
  final DateTime? clockIn;
  final DateTime? clockOut;
  final int workedMinutes;
  final int lateMinutes;
  final int otMinutes;
  final String? clockInMethod;
  final String? clockInAddress;

  factory AttendanceRecord.fromJson(Map<String, dynamic> j) {
    final emp = j['employees'];
    return AttendanceRecord(
      id: j['id'] as String,
      workDate: Fmt.parseDate(j['work_date']) ?? DateTime.now(),
      status: j['status']?.toString() ?? 'present',
      employeeName: emp is Map ? emp['full_name'] as String? : null,
      clockIn: Fmt.parseDate(j['clock_in']),
      clockOut: Fmt.parseDate(j['clock_out']),
      workedMinutes: Fmt.toInt(j['worked_minutes']),
      lateMinutes: Fmt.toInt(j['late_minutes']),
      otMinutes:
          Fmt.toInt(j['ot_normal_minutes']) +
          Fmt.toInt(j['ot_restday_minutes']) +
          Fmt.toInt(j['ot_holiday_minutes']),
      clockInMethod: j['clock_in_method']?.toString(),
      clockInAddress: j['clock_in_address']?.toString(),
    );
  }
}

class LeaveType {
  LeaveType({
    required this.id,
    required this.code,
    required this.name,
    this.isPaid = true,
    this.defaultDays = 0,
  });

  final String id;
  final String code;
  final String name;
  final bool isPaid;
  final double defaultDays;

  factory LeaveType.fromJson(Map<String, dynamic> j) => LeaveType(
    id: j['id'] as String,
    code: j['code']?.toString() ?? '',
    name: j['name']?.toString() ?? '',
    isPaid: j['is_paid'] == true,
    defaultDays: Fmt.toDouble(j['default_days']),
  );
}

class LeaveBalance {
  LeaveBalance({
    required this.leaveTypeId,
    required this.leaveTypeName,
    this.entitled = 0,
    this.carriedForward = 0,
    this.adjustment = 0,
    this.taken = 0,
    this.pending = 0,
  });

  final String leaveTypeId;
  final String leaveTypeName;
  final double entitled;
  final double carriedForward;
  final double adjustment;
  final double taken;
  final double pending;

  double get available =>
      entitled + carriedForward + adjustment - taken - pending;

  factory LeaveBalance.fromJson(Map<String, dynamic> j) {
    final lt = j['leave_types'];
    return LeaveBalance(
      leaveTypeId: j['leave_type_id']?.toString() ?? '',
      leaveTypeName: lt is Map ? (lt['name'] as String? ?? '') : '',
      entitled: Fmt.toDouble(j['entitled_days']),
      carriedForward: Fmt.toDouble(j['carried_forward']),
      adjustment: Fmt.toDouble(j['adjustment_days']),
      taken: Fmt.toDouble(j['taken_days']),
      pending: Fmt.toDouble(j['pending_days']),
    );
  }
}

class LeaveRequest {
  LeaveRequest({
    required this.id,
    required this.requestNo,
    required this.startDate,
    required this.endDate,
    required this.totalDays,
    required this.status,
    this.employeeName,
    this.leaveTypeName,
    this.reason,
    this.decisionNote,
  });

  final String id;
  final String requestNo;
  final DateTime startDate;
  final DateTime endDate;
  final double totalDays;
  final String status;
  final String? employeeName;
  final String? leaveTypeName;
  final String? reason;
  final String? decisionNote;

  factory LeaveRequest.fromJson(Map<String, dynamic> j) {
    final emp = j['employees'];
    final lt = j['leave_types'];
    return LeaveRequest(
      id: j['id'] as String,
      requestNo: j['request_no']?.toString() ?? '',
      startDate: Fmt.parseDate(j['start_date']) ?? DateTime.now(),
      endDate: Fmt.parseDate(j['end_date']) ?? DateTime.now(),
      totalDays: Fmt.toDouble(j['total_days']),
      status: j['status']?.toString() ?? 'draft',
      employeeName: emp is Map ? emp['full_name'] as String? : null,
      leaveTypeName: lt is Map ? lt['name'] as String? : null,
      reason: j['reason']?.toString(),
      decisionNote: j['decision_note']?.toString(),
    );
  }
}

class ExpenseClaim {
  ExpenseClaim({
    required this.id,
    required this.claimNo,
    required this.claimDate,
    required this.status,
    this.title,
    this.employeeName,
    this.totalAmount = 0,
    this.approvedAmount = 0,
    this.paidAt,
    this.payWithPayroll = true,
    this.glEntryId,
  });

  final String id;
  final String claimNo;
  final DateTime claimDate;
  final String status;
  final String? title;
  final String? employeeName;
  final double totalAmount;
  final double approvedAmount;
  final DateTime? paidAt;
  final bool payWithPayroll;

  /// The journal this claim posted, once it has. Null on an approved
  /// claim means the expense has been agreed and has not yet reached the
  /// ledger.
  final String? glEntryId;

  /// Approved, not reimbursed with payroll, and not yet in the ledger —
  /// so somebody has to post it, and until the claims screen grew a Post
  /// action nobody could.
  bool get awaitingPosting =>
      status == 'approved' && !payWithPayroll && glEntryId == null;

  factory ExpenseClaim.fromJson(Map<String, dynamic> j) {
    final emp = j['employees'];
    return ExpenseClaim(
      id: j['id'] as String,
      claimNo: j['claim_no']?.toString() ?? '',
      claimDate: Fmt.parseDate(j['claim_date']) ?? DateTime.now(),
      status: j['status']?.toString() ?? 'draft',
      title: j['title']?.toString(),
      employeeName: emp is Map ? emp['full_name'] as String? : null,
      totalAmount: Fmt.toDouble(j['total_amount']),
      approvedAmount: Fmt.toDouble(j['approved_amount']),
      paidAt: Fmt.parseDate(j['paid_at']),
      payWithPayroll: j['pay_with_payroll'] != false,
      glEntryId: j['gl_entry_id'] as String?,
    );
  }
}

class PayrollRun {
  PayrollRun({
    required this.id,
    required this.runNo,
    required this.status,
    this.periodCode,
    this.payDate,
    this.description,
    this.employeeCount = 0,
    this.totalGross = 0,
    this.totalNet = 0,
    this.totalDeductions = 0,
    this.totalEmployerCost = 0,
    this.totalEpfEmployee = 0,
    this.totalEpfEmployer = 0,
    this.totalSocsoEmployee = 0,
    this.totalSocsoEmployer = 0,
    this.totalEisEmployee = 0,
    this.totalEisEmployer = 0,
    this.totalPcb = 0,
    this.totalHrdf = 0,
  });

  final String id;
  final String runNo;
  final String status;
  final String? periodCode;
  final DateTime? payDate;
  final String? description;
  final int employeeCount;
  final double totalGross;
  final double totalNet;
  final double totalDeductions;
  final double totalEmployerCost;
  final double totalEpfEmployee;
  final double totalEpfEmployer;
  final double totalSocsoEmployee;
  final double totalSocsoEmployer;
  final double totalEisEmployee;
  final double totalEisEmployer;
  final double totalPcb;
  final double totalHrdf;

  bool get isPosted => status == 'posted' || status == 'paid';

  factory PayrollRun.fromJson(Map<String, dynamic> j) {
    final p = j['pay_periods'];
    return PayrollRun(
      id: j['id'] as String,
      runNo: j['run_no']?.toString() ?? '',
      status: j['status']?.toString() ?? 'draft',
      periodCode: p is Map ? p['code'] as String? : null,
      payDate: p is Map ? Fmt.parseDate(p['pay_date']) : null,
      description: j['description']?.toString(),
      employeeCount: Fmt.toInt(j['employee_count']),
      totalGross: Fmt.toDouble(j['total_gross']),
      totalNet: Fmt.toDouble(j['total_net']),
      totalDeductions: Fmt.toDouble(j['total_deductions']),
      totalEmployerCost: Fmt.toDouble(j['total_employer_cost']),
      totalEpfEmployee: Fmt.toDouble(j['total_epf_employee']),
      totalEpfEmployer: Fmt.toDouble(j['total_epf_employer']),
      totalSocsoEmployee: Fmt.toDouble(j['total_socso_employee']),
      totalSocsoEmployer: Fmt.toDouble(j['total_socso_employer']),
      totalEisEmployee: Fmt.toDouble(j['total_eis_employee']),
      totalEisEmployer: Fmt.toDouble(j['total_eis_employer']),
      totalPcb: Fmt.toDouble(j['total_pcb']),
      totalHrdf: Fmt.toDouble(j['total_hrdf']),
    );
  }
}

/// A journal, as it sits in the ledger.
///
/// Everything in the system posts through `create_gl_entry`, so this is
/// where an invoice, a payroll run and a hand-written correction all end
/// up looking the same.
class JournalEntry {
  JournalEntry({
    required this.id,
    required this.entryNo,
    required this.entryDate,
    required this.source,
    required this.status,
    this.description,
    this.reference,
    this.totalDebit = 0,
    this.totalCredit = 0,
    this.isReversal = false,
    this.reversedEntryId,
    this.lines = const [],
  });

  final String id;
  final String entryNo;
  final DateTime entryDate;
  final String source;
  final String status;
  final String? description;
  final String? reference;
  final double totalDebit;
  final double totalCredit;
  final bool isReversal;
  final String? reversedEntryId;
  final List<JournalLine> lines;

  bool get isVoid => status == 'void';
  bool get canReverse => status == 'posted';

  factory JournalEntry.fromJson(Map<String, dynamic> j) => JournalEntry(
    id: j['id'] as String,
    entryNo: j['entry_no']?.toString() ?? '',
    entryDate: Fmt.parseDate(j['entry_date']) ?? DateTime.now(),
    source: j['source']?.toString() ?? 'manual',
    status: j['status']?.toString() ?? 'posted',
    description: j['description']?.toString(),
    reference: j['reference']?.toString(),
    totalDebit: Fmt.toDouble(j['total_debit']),
    totalCredit: Fmt.toDouble(j['total_credit']),
    isReversal: j['is_reversal'] == true,
    reversedEntryId: j['reversed_entry_id'] as String?,
    lines: [
      for (final l in (j['gl_lines'] as List? ?? const []))
        JournalLine.fromJson(Map<String, dynamic>.from(l as Map)),
    ]..sort((a, b) => a.lineNo.compareTo(b.lineNo)),
  );
}

class JournalLine {
  JournalLine({
    required this.lineNo,
    required this.accountCode,
    required this.accountName,
    this.description,
    this.debit = 0,
    this.credit = 0,
  });

  final int lineNo;
  final String accountCode;
  final String accountName;
  final String? description;
  final double debit;
  final double credit;

  factory JournalLine.fromJson(Map<String, dynamic> j) {
    final a = j['accounts'];
    return JournalLine(
      lineNo: Fmt.toInt(j['line_no']),
      accountCode: a is Map ? a['code']?.toString() ?? '' : '',
      accountName: a is Map ? a['name']?.toString() ?? '' : '',
      description: j['description']?.toString(),
      debit: Fmt.toDouble(j['debit']),
      credit: Fmt.toDouble(j['credit']),
    );
  }
}

/// One recorded change to something worth watching.
///
/// [changes] holds only the fields that moved, from and to, so a salary
/// change reads as a salary change rather than a wall of unchanged
/// columns.
class AuditEntry {
  AuditEntry({
    required this.id,
    required this.at,
    required this.actor,
    required this.action,
    required this.tableName,
    this.recordId,
    this.before = const {},
    this.after = const {},
  });

  final int id;
  final DateTime at;
  final String actor;
  final String action;
  final String tableName;
  final String? recordId;
  final Map<String, dynamic> before;
  final Map<String, dynamic> after;

  /// The fields that moved, in a stable order so the list does not
  /// reshuffle itself between reads.
  List<String> get fields => ({...before.keys, ...after.keys}.toList()..sort());

  factory AuditEntry.fromJson(Map<String, dynamic> j) {
    final changes = j['changes'];
    Map<String, dynamic> side(String key) {
      if (changes is! Map) return const {};
      final v = changes[key];
      return v is Map ? Map<String, dynamic>.from(v) : const {};
    }

    return AuditEntry(
      id: Fmt.toInt(j['id']),
      at: Fmt.parseDate(j['at']) ?? DateTime.now(),
      actor: j['actor']?.toString() ?? 'system',
      action: j['action']?.toString() ?? '',
      tableName: j['table_name']?.toString() ?? '',
      recordId: j['record_id'] as String?,
      before: side('from'),
      after: side('to'),
    );
  }
}

/// What an employee had already earned this tax year before payroll
/// started keeping their record.
///
/// PCB works by projecting the year, so a company adopting in July with
/// nothing here projects six months of pay as if it were the whole year
/// and deducts a fraction of what it should. The figures come off the
/// employee's last payslip or their EA form from the previous employer.
class YtdOpening {
  YtdOpening({
    required this.taxYear,
    this.id,
    this.grossPay = 0,
    this.epfEmployee = 0,
    this.pcbPaid = 0,
    this.zakatPaid = 0,
    this.benefitsInKind = 0,
    this.notes,
  });

  final String? id;
  final int taxYear;
  final double grossPay;
  final double epfEmployee;
  final double pcbPaid;
  final double zakatPaid;
  final double benefitsInKind;
  final String? notes;

  bool get isEmpty =>
      grossPay == 0 &&
      epfEmployee == 0 &&
      pcbPaid == 0 &&
      zakatPaid == 0 &&
      benefitsInKind == 0;

  factory YtdOpening.fromJson(Map<String, dynamic> j) => YtdOpening(
    id: j['id'] as String?,
    taxYear: Fmt.toInt(j['tax_year']),
    grossPay: Fmt.toDouble(j['gross_pay']),
    epfEmployee: Fmt.toDouble(j['epf_employee']),
    pcbPaid: Fmt.toDouble(j['pcb_paid']),
    zakatPaid: Fmt.toDouble(j['zakat_paid']),
    benefitsInKind: Fmt.toDouble(j['benefits_in_kind']),
    notes: j['notes']?.toString(),
  );
}

/// A relief the employee has declared — the TP1 form. Reliefs the
/// company can work out for itself (the individual allowance, EPF,
/// SOCSO, spouse, children) are applied automatically and are not
/// entered here.
class DeclaredRelief {
  DeclaredRelief({
    required this.reliefCode,
    required this.amount,
    required this.taxYear,
    this.id,
    this.name,
    this.maxAmount,
    this.notes,
  });

  final String? id;
  final String reliefCode;
  final String? name;
  final double amount;
  final double? maxAmount;
  final int taxYear;
  final String? notes;

  factory DeclaredRelief.fromJson(Map<String, dynamic> j) => DeclaredRelief(
    id: j['id'] as String?,
    reliefCode: j['relief_code']?.toString() ?? '',
    amount: Fmt.toDouble(j['amount']),
    taxYear: Fmt.toInt(j['tax_year']),
    notes: j['notes']?.toString(),
  );
}

/// A relief the statutory schedule offers, for the picker.
class ReliefType {
  ReliefType({required this.code, required this.name, this.maxAmount});

  final String code;
  final String name;
  final double? maxAmount;

  factory ReliefType.fromJson(Map<String, dynamic> j) => ReliefType(
    code: j['code']?.toString() ?? '',
    name: j['name']?.toString() ?? '',
    maxAmount: j['max_amount'] == null ? null : Fmt.toDouble(j['max_amount']),
  );
}

/// One line of a bank payment instruction.
///
/// [problem] is set when the line cannot be paid as it stands — no bank
/// account, no bank, or nothing owing. Those lines are carried rather
/// than dropped, because an employee who quietly falls out of the file is
/// an employee who does not get paid and nobody notices.
class PaymentLine {
  PaymentLine({
    required this.employeeNo,
    required this.employeeName,
    required this.amount,
    required this.reference,
    this.bankName,
    this.bankAccountNo,
    this.problem,
  });

  final String employeeNo;
  final String employeeName;
  final double amount;
  final String reference;
  final String? bankName;
  final String? bankAccountNo;
  final String? problem;

  bool get isPayable => problem == null;

  factory PaymentLine.fromJson(Map<String, dynamic> j) => PaymentLine(
    employeeNo: j['employee_no']?.toString() ?? '',
    employeeName: j['employee_name']?.toString() ?? '',
    amount: Fmt.toDouble(j['amount']),
    reference: j['reference']?.toString() ?? '',
    bankName: j['bank_name']?.toString(),
    bankAccountNo: j['bank_account_no']?.toString(),
    problem: j['problem']?.toString(),
  );
}

class Payslip {
  Payslip({
    required this.id,
    required this.employeeName,
    this.employeeNo,
    this.departmentName,
    this.positionTitle,
    this.periodCode,
    this.basicSalary = 0,
    this.grossPay = 0,
    this.totalDeductions = 0,
    this.netPay = 0,
    this.epfWage = 0,
    this.socsoWage = 0,
    this.eisWage = 0,
    this.taxableIncome = 0,
    this.epfEmployee = 0,
    this.epfEmployer = 0,
    this.socsoEmployee = 0,
    this.socsoEmployer = 0,
    this.eisEmployee = 0,
    this.eisEmployer = 0,
    this.pcb = 0,
    this.zakat = 0,
    this.hrdf = 0,
    this.otHours = 0,
    this.schedulesVerified = false,
    this.lines = const [],
  });

  final String id;
  final String employeeName;
  final String? employeeNo;
  final String? departmentName;
  final String? positionTitle;
  final String? periodCode;
  final double basicSalary;
  final double grossPay;
  final double totalDeductions;
  final double netPay;
  final double epfWage;
  final double socsoWage;
  final double eisWage;
  final double taxableIncome;
  final double epfEmployee;
  final double epfEmployer;
  final double socsoEmployee;
  final double socsoEmployer;
  final double eisEmployee;
  final double eisEmployer;
  final double pcb;
  final double zakat;
  final double hrdf;
  final double otHours;
  final bool schedulesVerified;
  final List<PayslipLine> lines;

  factory Payslip.fromJson(Map<String, dynamic> j) {
    final raw = j['payslip_lines'];
    final run = j['payroll_runs'];
    final period = run is Map ? run['pay_periods'] : null;
    return Payslip(
      id: j['id'] as String,
      employeeName: j['employee_name']?.toString() ?? '',
      employeeNo: j['employee_no']?.toString(),
      departmentName: j['department_name']?.toString(),
      positionTitle: j['position_title']?.toString(),
      periodCode: period is Map ? period['code'] as String? : null,
      basicSalary: Fmt.toDouble(j['basic_salary']),
      grossPay: Fmt.toDouble(j['gross_pay']),
      totalDeductions: Fmt.toDouble(j['total_deductions']),
      netPay: Fmt.toDouble(j['net_pay']),
      epfWage: Fmt.toDouble(j['epf_wage']),
      socsoWage: Fmt.toDouble(j['socso_wage']),
      eisWage: Fmt.toDouble(j['eis_wage']),
      taxableIncome: Fmt.toDouble(j['taxable_income']),
      epfEmployee: Fmt.toDouble(j['epf_employee']),
      epfEmployer: Fmt.toDouble(j['epf_employer']),
      socsoEmployee: Fmt.toDouble(j['socso_employee']),
      socsoEmployer: Fmt.toDouble(j['socso_employer']),
      eisEmployee: Fmt.toDouble(j['eis_employee']),
      eisEmployer: Fmt.toDouble(j['eis_employer']),
      pcb: Fmt.toDouble(j['pcb']) + Fmt.toDouble(j['cp38']),
      zakat: Fmt.toDouble(j['zakat']),
      hrdf: Fmt.toDouble(j['hrdf']),
      otHours: Fmt.toDouble(j['ot_hours']),
      schedulesVerified: j['schedules_verified'] == true,
      lines: raw is List
          ? raw
                .map((e) => PayslipLine.fromJson(Map<String, dynamic>.from(e)))
                .toList()
          : const [],
    );
  }
}

class PayslipLine {
  PayslipLine({
    required this.kind,
    required this.code,
    required this.description,
    required this.amount,
    this.quantity,
    this.rate,
  });

  final String kind;
  final String code;
  final String description;
  final double amount;
  final double? quantity;
  final double? rate;

  factory PayslipLine.fromJson(Map<String, dynamic> j) => PayslipLine(
    kind: j['kind']?.toString() ?? 'earning',
    code: j['code']?.toString() ?? '',
    description: j['description']?.toString() ?? '',
    amount: Fmt.toDouble(j['amount']),
    quantity: j['quantity'] == null ? null : Fmt.toDouble(j['quantity']),
    rate: j['rate'] == null ? null : Fmt.toDouble(j['rate']),
  );
}

class JobRequisition {
  JobRequisition({
    required this.id,
    required this.requisitionNo,
    required this.title,
    required this.status,
    this.departmentName,
    this.headcount = 1,
    this.location,
    this.salaryMin,
    this.salaryMax,
    this.applicantCount = 0,
  });

  final String id;
  final String requisitionNo;
  final String title;
  final String status;
  final String? departmentName;
  final int headcount;
  final String? location;
  final double? salaryMin;
  final double? salaryMax;
  final int applicantCount;

  factory JobRequisition.fromJson(Map<String, dynamic> j) {
    final dept = j['departments'];
    final apps = j['applicants'];
    return JobRequisition(
      id: j['id'] as String,
      requisitionNo: j['requisition_no']?.toString() ?? '',
      title: j['title']?.toString() ?? '',
      status: j['status']?.toString() ?? 'draft',
      departmentName: dept is Map ? dept['name'] as String? : null,
      headcount: Fmt.toInt(j['headcount']),
      location: j['location']?.toString(),
      salaryMin: j['salary_min'] == null ? null : Fmt.toDouble(j['salary_min']),
      salaryMax: j['salary_max'] == null ? null : Fmt.toDouble(j['salary_max']),
      applicantCount: apps is List && apps.isNotEmpty && apps.first is Map
          ? Fmt.toInt((apps.first as Map)['count'])
          : 0,
    );
  }
}

class Applicant {
  Applicant({
    required this.id,
    required this.fullName,
    required this.status,
    this.email,
    this.phone,
    this.currentPosition,
    this.expectedSalary,
    this.source,
    this.rating,
    this.requisitionTitle,
    this.appliedAt,
  });

  final String id;
  final String fullName;
  final String status;
  final String? email;
  final String? phone;
  final String? currentPosition;
  final double? expectedSalary;
  final String? source;
  final int? rating;
  final String? requisitionTitle;
  final DateTime? appliedAt;

  factory Applicant.fromJson(Map<String, dynamic> j) {
    final req = j['job_requisitions'];
    return Applicant(
      id: j['id'] as String,
      fullName: j['full_name']?.toString() ?? '',
      status: j['status']?.toString() ?? 'applied',
      email: j['email']?.toString(),
      phone: j['phone']?.toString(),
      currentPosition: j['current_position']?.toString(),
      expectedSalary: j['expected_salary'] == null
          ? null
          : Fmt.toDouble(j['expected_salary']),
      source: j['source']?.toString(),
      rating: j['rating'] == null ? null : Fmt.toInt(j['rating']),
      requisitionTitle: req is Map ? req['title'] as String? : null,
      appliedAt: Fmt.parseDate(j['applied_at']),
    );
  }
}

class Appraisal {
  Appraisal({
    required this.id,
    required this.status,
    this.employeeName,
    this.reviewerName,
    this.cycleName,
    this.selfRating,
    this.managerRating,
    this.finalRating,
    this.recommendedIncrement,
  });

  final String id;
  final String status;
  final String? employeeName;
  final String? reviewerName;
  final String? cycleName;
  final double? selfRating;
  final double? managerRating;
  final double? finalRating;
  final double? recommendedIncrement;

  factory Appraisal.fromJson(Map<String, dynamic> j) {
    final emp = j['employees'];
    final cyc = j['appraisal_cycles'];
    return Appraisal(
      id: j['id'] as String,
      status: j['status']?.toString() ?? 'draft',
      employeeName: emp is Map ? emp['full_name'] as String? : null,
      cycleName: cyc is Map ? cyc['name'] as String? : null,
      selfRating: j['self_rating'] == null
          ? null
          : Fmt.toDouble(j['self_rating']),
      managerRating: j['manager_rating'] == null
          ? null
          : Fmt.toDouble(j['manager_rating']),
      finalRating: j['final_rating'] == null
          ? null
          : Fmt.toDouble(j['final_rating']),
      recommendedIncrement: j['recommended_increment_percent'] == null
          ? null
          : Fmt.toDouble(j['recommended_increment_percent']),
    );
  }
}

/// An auditor's request to read payslips, and the admin decision on it.
class PayslipAccessRequest {
  PayslipAccessRequest({
    required this.id,
    required this.status,
    required this.reason,
    required this.requestedAt,
    this.requesterName,
    this.decidedByName,
    this.decisionNote,
    this.periodFrom,
    this.periodTo,
    this.expiresAt,
    this.decidedAt,
  });

  final String id;
  final String status;
  final String reason;
  final DateTime requestedAt;
  final String? requesterName;
  final String? decidedByName;
  final String? decisionNote;
  final DateTime? periodFrom;
  final DateTime? periodTo;
  final DateTime? expiresAt;
  final DateTime? decidedAt;

  bool get isPending => status == 'pending';

  /// Approved but past its expiry. The database stops honouring it either
  /// way; this is so the UI does not call a dead grant "approved".
  bool get hasLapsed =>
      status == 'approved' &&
      expiresAt != null &&
      expiresAt!.isBefore(DateTime.now());

  bool get isLive => status == 'approved' && !hasLapsed;

  /// What to show on a chip: the stored status, unless it has quietly run out.
  String get displayStatus => hasLapsed ? 'expired' : status;

  String get scopeLabel {
    if (periodFrom == null && periodTo == null) return 'All periods';
    return '${Fmt.date(periodFrom)} – ${Fmt.date(periodTo)}';
  }

  factory PayslipAccessRequest.fromJson(Map<String, dynamic> j) {
    final requester = j['requester'];
    final decider = j['decider'];
    return PayslipAccessRequest(
      id: j['id'] as String,
      status: j['status']?.toString() ?? 'pending',
      reason: j['reason']?.toString() ?? '',
      requestedAt: Fmt.parseDate(j['requested_at']) ?? DateTime.now(),
      requesterName: requester is Map
          ? (requester['full_name'] ?? requester['email'])?.toString()
          : null,
      decidedByName: decider is Map
          ? (decider['full_name'] ?? decider['email'])?.toString()
          : null,
      decisionNote: j['decision_note']?.toString(),
      periodFrom: Fmt.parseDate(j['period_from']),
      periodTo: Fmt.parseDate(j['period_to']),
      expiresAt: Fmt.parseDate(j['expires_at']),
      decidedAt: Fmt.parseDate(j['decided_at']),
    );
  }
}

/// One entry in the payslip read log: who opened what, and under which
/// grant. Written by the read functions themselves.
class PayslipAccessLogEntry {
  PayslipAccessLogEntry({
    required this.id,
    required this.action,
    required this.viewedAt,
    this.actorName,
    this.employeeName,
    this.periodCode,
    this.payslipCount,
    this.ipAddress,
  });

  final String id;
  final String action;
  final DateTime viewedAt;
  final String? actorName;
  final String? employeeName;
  final String? periodCode;
  final int? payslipCount;
  final String? ipAddress;

  bool get isView => action == 'view';

  /// What was actually looked at, in words.
  String get summary => isView
      ? '${employeeName ?? 'A payslip'}${periodCode == null ? '' : ' · $periodCode'}'
      : 'Listed ${payslipCount ?? 0} payslip(s)';

  factory PayslipAccessLogEntry.fromJson(Map<String, dynamic> j) {
    final actor = j['actor'];
    return PayslipAccessLogEntry(
      id: j['id'] as String,
      action: j['action']?.toString() ?? 'view',
      viewedAt: Fmt.parseDate(j['viewed_at']) ?? DateTime.now(),
      actorName: actor is Map
          ? (actor['full_name'] ?? actor['email'])?.toString()
          : null,
      employeeName: j['employee_name']?.toString(),
      periodCode: j['period_code']?.toString(),
      payslipCount: j['payslip_count'] == null
          ? null
          : Fmt.toInt(j['payslip_count']),
      ipAddress: j['ip_address']?.toString(),
    );
  }
}
