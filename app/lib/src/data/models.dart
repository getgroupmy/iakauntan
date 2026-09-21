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
    this.tourismTaxRegNo,
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

  /// The Tourism Tax registration RMCD issued, for an operator within
  /// the Tourism Tax Act 2017 — accommodation, and the platforms that
  /// sell it. A separate register from SST with a separate number, and
  /// a registered operator prints it on the invoice beside the SST one.
  ///
  /// Held here and nowhere else: the column has existed since `0001`
  /// beside `sst_registration_no` and nothing had ever written to it.
  final String? tourismTaxRegNo;
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
    tourismTaxRegNo: j['tourism_tax_reg_no'] as String?,
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
    this.oldRegistrationNo,
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
    this.creditHold = false,
    this.receivableAccountId,
    this.payableAccountId,
    this.paymentTermId,
    this.priceLevelId,
    this.customFields = const {},
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

  /// The number the register issued before 2019 -- `571389-H`,
  /// `JM0167410-V`. A company or business registered before the
  /// numbering changed carries both, and a counterparty searching for
  /// one will not find the other. `set_contact_ssm_entity` has written
  /// this column since 0589 and nothing in the app could show it, so a
  /// lookup filled a field nobody could read or correct.
  final String? oldRegistrationNo;

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

  /// No further credit until somebody takes it off. Unlike the limit,
  /// which the organization's `credit_control` mode decides whether to
  /// enforce, a hold refuses an invoice either way: it is a person's
  /// instruction rather than arithmetic. Credit notes still post.
  final bool creditHold;

  /// Where this contact's balance sits, when it is not the company's
  /// usual control account. 0013 reads both in four places — the
  /// invoice, the bill, the receipt and the payment — and falls back to
  /// 1210 and 2110 only when the contact names nothing.
  final String? receivableAccountId;
  final String? payableAccountId;
  final String? paymentTermId;

  /// Which price list this customer buys on. Null falls back to the
  /// organization's default level, and then to the item's list price.
  final String? priceLevelId;

  /// The fields this company added for itself, keyed as
  /// `custom_fields_def.key`. 0542 gives them definitions and a guard;
  /// what arrives here has already been held to them.
  final Map<String, dynamic> customFields;
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
    oldRegistrationNo: j['old_registration_no'] as String?,
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
    creditHold: j['credit_hold'] == true,
    receivableAccountId: j['receivable_account_id'] as String?,
    payableAccountId: j['payable_account_id'] as String?,
    paymentTermId: j['payment_term_id'] as String?,
    priceLevelId: j['price_level_id'] as String?,
    customFields: Map<String, dynamic>.from(
      (j['custom_fields'] as Map?) ?? const {},
    ),
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
    oldRegistrationNo: oldRegistrationNo,
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
    creditHold: creditHold,
    receivableAccountId: receivableAccountId,
    payableAccountId: payableAccountId,
    paymentTermId: paymentTermId,
    priceLevelId: priceLevelId,
    customFields: customFields,
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
    'old_registration_no': oldRegistrationNo,
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
    'credit_hold': creditHold,
    'receivable_account_id': receivableAccountId,
    'payable_account_id': payableAccountId,
    'price_level_id': priceLevelId,
    'custom_fields': customFields,
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

/// One month of deferred revenue waiting to be released.
///
/// The shape `recognise_revenue` posts in: one journal per period end,
/// carrying every line that matures on it. So a row here is a journal
/// that is about to exist, not an internal grouping the ledger will
/// disagree with.
class RevenueDue {
  const RevenueDue({
    required this.periodEnd,
    required this.amount,
    required this.lines,
    required this.documents,
  });

  final DateTime periodEnd;
  final double amount;

  /// How many invoice lines mature on this date, and across how many
  /// documents. Both, because "3 lines" and "3 invoices" are different
  /// numbers and the second is the one somebody recognises.
  final int lines;
  final int documents;

  factory RevenueDue.fromJson(Map<String, dynamic> j) => RevenueDue(
    periodEnd: Fmt.parseDate(j['period_end']) ?? DateTime.now(),
    amount: Fmt.toDouble(j['amount']),
    lines: (j['lines'] as num?)?.toInt() ?? 0,
    documents: (j['documents'] as num?)?.toInt() ?? 0,
  );
}

/// Which of [rows] a release dated [upto] would post, and which it
/// would leave.
///
/// Inclusive of the date itself, because `recognise_revenue` filters on
/// `period_end <= p_upto`. A month ending exactly on the date chosen is
/// earned by it, and being off by one here would leave a month behind
/// every single time — the date anybody picks for a release is a month
/// end, so the boundary is not an edge case, it is the case.
///
/// Out here rather than in the card so the boundary can be asserted
/// without a Flutter binding, the same split `servicePeriodLabel` has.
({List<RevenueDue> ready, List<RevenueDue> later}) splitRevenueDue(
  List<RevenueDue> rows,
  DateTime upto,
) => (
  ready: [
    for (final r in rows)
      if (!r.periodEnd.isAfter(upto)) r,
  ],
  later: [
    for (final r in rows)
      if (r.periodEnd.isAfter(upto)) r,
  ],
);

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
    this.caClassCode,
    this.caNotes,
    this.status = 'active',
    this.disposalDate,
    this.disposalProceeds,
    this.notes,
    this.purchaseDocumentId,
    this.purchaseDocNo,
    this.supplierId,
    this.supplierName,
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

  /// The Schedule 3 class, or null for an asset that attracts no
  /// capital allowance at all — land, goodwill. Null is a real answer
  /// rather than a gap, and `0664` says so on the column.
  final String? caClassCode;

  /// Why it is in the class it is in — the reasoning a reviewer would
  /// otherwise reconstruct from the cost and the label.
  final String? caNotes;

  final String status;
  final DateTime? disposalDate;
  final double? disposalProceeds;
  final String? notes;

  /// The bill this came from, and who it was bought from. Both were
  /// columns nothing wrote until `0382`, so the register and the fixed
  /// asset accounts in the ledger had no way to be compared — the
  /// reconciliation an auditor opens with.
  final String? purchaseDocumentId;
  final String? purchaseDocNo;
  final String? supplierId;
  final String? supplierName;

  /// Whether the cost in the register can be traced to a posted bill.
  /// A typed-in asset is not wrong, but nothing can check it.
  bool get isTraceable => purchaseDocumentId != null;

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
    caClassCode: j['ca_class_code'] as String?,
    caNotes: j['ca_notes'] as String?,
    status: j['status']?.toString() ?? 'active',
    disposalDate: Fmt.parseDate(j['disposal_date']),
    disposalProceeds: j['disposal_proceeds'] == null
        ? null
        : Fmt.toDouble(j['disposal_proceeds']),
    notes: j['notes'] as String?,
    purchaseDocumentId: j['purchase_document_id'] as String?,
    purchaseDocNo: j['purchase_documents'] is Map
        ? j['purchase_documents']['doc_no']?.toString()
        : null,
    supplierId: j['supplier_id'] as String?,
    supplierName:
        j['contacts'] is Map ? j['contacts']['name']?.toString() : null,
  );

  // `purchase_document_id`, `purchase_line_id` and `supplier_id` are
  // deliberately not sent. They are written once, by
  // `capitalise_bill_line`, out of the row the asset came from; an
  // editor that could change them afterwards could point an asset at a
  // bill it did not come from, which is worse than pointing at none.
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
    'ca_class_code': caClassCode,
    'ca_notes': caNotes,
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
    this.tariffCode,
    this.countryOfOrigin,
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
    this.customFields = const {},
  });

  final String id;
  final String code;
  final String name;
  final String itemType;
  final String? description;
  final String uomCode;
  final String classificationCode;

  /// The customs tariff / HS code, carried onto an e-Invoice line. NOT
  /// [classificationCode], which is LHDN's list of what a purchase is
  /// for relief purposes -- the two are constantly confused. 0636.
  final String? tariffCode;

  /// Where the goods were made. Null is unstated, and the UBL builder
  /// then sends MYS as it always has.
  final String? countryOfOrigin;
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

  /// The fields this company added for itself. 0542 gives them
  /// definitions and a guard; what arrives here has been held to them.
  final Map<String, dynamic> customFields;

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
    tariffCode: j['tariff_code'] as String?,
    countryOfOrigin: j['country_of_origin'] as String?,
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
    customFields: Map<String, dynamic>.from(
      (j['custom_fields'] as Map?) ?? const {},
    ),
  );

  Map<String, dynamic> toJson() => {
    'code': code,
    'name': name,
    'item_type': itemType,
    'description': description,
    'uom_code': uomCode,
    'classification_code': classificationCode,
    'tariff_code': tariffCode,
    'country_of_origin': countryOfOrigin,
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
    'custom_fields': customFields,
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
    this.isInclusive = false,
    this.exemptionReason,
  });

  final String id;
  final String code;
  final String name;
  final double rate;
  final String taxTypeCode;
  final bool isDefault;
  final bool isExempt;

  /// Whether a price quoted against this code already contains the tax.
  ///
  /// A property of the code rather than of the line, for the reason
  /// `0641` gives: "prices include SST" is how a business quotes, not a
  /// choice to re-make on every line, and a document that is half
  /// inclusive is a document nobody can check. `app.calc_document_line`
  /// reads it the moment the code is chosen and writes the answer onto
  /// `is_tax_inclusive`, which is then the line's own for good — like
  /// the rate beside it.
  final bool isInclusive;

  /// Why it is exempt, as a `ref_exemption_reasons` code. LHDN puts it
  /// on the exempt line; `0015_einvoice_prepare` carries it through as
  /// `tax_exemption_reason`.
  final String? exemptionReason;

  /// How this code reads in a picker: the code, its rate, and — when it
  /// matters — that a price quoted against it already contains the tax.
  ///
  /// One place rather than three, because two codes at the same rate
  /// that differ only in [isInclusive] are the ordinary shape of this
  /// (a company quoting retail inclusive and trade exclusive), and
  /// without the marker they are the same row twice in every list.
  /// Nothing is said at a zero rate, inclusive or not: the trigger's
  /// inclusive branch is guarded on `tax_rate > 0`, so a zero-rated code
  /// computes identically either way and the marker would name a
  /// difference that does not exist.
  String get pickerLabel => rate == 0
      ? code
      : '$code (${Fmt.percent(rate)}${isInclusive ? ' incl.' : ''})';

  factory TaxCode.fromJson(Map<String, dynamic> j) => TaxCode(
    id: j['id'] as String,
    code: j['code']?.toString() ?? '',
    name: j['name']?.toString() ?? '',
    rate: Fmt.toDouble(j['rate']),
    taxTypeCode: j['tax_type_code']?.toString() ?? '06',
    isDefault: j['is_default'] == true,
    isExempt: j['is_exempt'] == true,
    isInclusive: j['is_inclusive'] == true,
    exemptionReason: j['exemption_reason'] as String?,
  );
}

class Account {
  Account({
    required this.id,
    required this.code,
    required this.name,
    required this.accountType,
    required this.accountSubtype,
    this.taxTreatment,
    this.isGroup = false,
    this.currentBalance = 0,
    this.isActive = true,
  });

  final String id;
  final String code;
  final String name;
  final String accountType;
  final String accountSubtype;

  /// How a tax computation treats it. Null means ordinary — an expense
  /// is deductible, revenue is taxable — which is what almost every
  /// account is. Not a to-do.
  final String? taxTreatment;
  final bool isGroup;
  final double currentBalance;
  final bool isActive;

  factory Account.fromJson(Map<String, dynamic> j) => Account(
    id: j['id'] as String,
    code: j['code']?.toString() ?? '',
    name: j['name']?.toString() ?? '',
    accountType: j['account_type']?.toString() ?? 'asset',
    accountSubtype: j['account_subtype']?.toString() ?? 'current_asset',
    taxTreatment: j['tax_treatment'] as String?,
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

  /// The named embed for this kind's customer or supplier.
  ///
  /// Both document tables reach `contacts` twice: by `contact_id`, and by
  /// the composite `(org_id, contact_id)` key 0512 added to hold every
  /// document to its own company's contacts. PostgREST will not guess
  /// between two relationships — it answers PGRST201 and refuses the
  /// whole request — so the constraint is named here rather than at each
  /// call site, which is how one of them was missed.
  String get contactEmbed => isSales
      ? 'contacts!sales_documents_contact_id_fkey'
      : 'contacts!purchase_documents_contact_id_fkey';

  /// The named embed for this kind's LINES.
  ///
  /// Same trap as [contactEmbed] and found the same way — in production,
  /// on a screen. A line table reaches its document twice: by
  /// `document_id`, and by the composite `(org_id, document_id)` key.
  /// `${kind.lineTable}(*)` reads as an ordinary embed and is one
  /// PostgREST refuses.
  String get lineEmbed => isSales
      ? 'sales_document_lines!sales_document_lines_document_id_fkey'
      : 'purchase_document_lines!purchase_document_lines_document_id_fkey';

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
    this.validUntil,
    this.deliveryDate,
    this.reference,
    this.supplierDocNo,
    this.currency = 'MYR',
    this.exchangeRate = 1,
    this.subtotal = 0,
    this.discountAmount = 0,
    this.taxAmount = 0,
    this.shippingAmount = 0,
    this.serviceChargeAmount = 0,
    this.roundingAmount = 0,
    this.totalAmount = 0,
    this.paidAmount = 0,
    this.balanceAmount = 0,
    this.status = 'draft',
    this.fulfilmentStatus = 'pending',
    this.einvoiceStatus = 'not_applicable',
    this.requiresSelfBilled = false,
    this.einvoiceId,
    this.glEntryId,
    this.notes,
    this.termsConditions,
    this.paymentTermId,
    this.salespersonId,
    this.lines = const [],
    this.customFields = const {},
  });

  final String id;
  final String docType;
  final String docNo;
  final DateTime docDate;
  final String contactId;
  final String? contactName;
  final DateTime? dueDate;

  /// The day a quotation's or proforma's price stops holding. `0374`
  /// refuses to transfer an offer past it, which is why it is on the
  /// model at all: a column since `0005` that nothing read.
  final DateTime? validUntil;

  /// The day delivery was promised, carried forward from the quotation
  /// through the order to the delivery order.
  final DateTime? deliveryDate;
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

  /// Ten per cent for the table. `0410` put it on `sales_documents` and
  /// on the POS sale; it is a header amount like shipping, it is taxed,
  /// and it posts to 4250 rather than to sales.
  final double serviceChargeAmount;
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

  /// Whether this bill owes LHDN an e-Invoice that WE have to file.
  ///
  /// Where the seller cannot — a foreign supplier outside MyInvois, an
  /// individual who is not registered — the buyer files one on their
  /// behalf. `0611` sets it from the supplier's country on insert and
  /// `set_requires_self_billed` lets somebody say otherwise. Meaningless
  /// on a sales document, which is why nothing reads it there.
  final bool requiresSelfBilled;
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
  /// Overdue is STRICTLY before today, on the date and not the moment.
  ///
  /// This has to mean what `v_ar_aging` means, because that view is
  /// what the aging report, the collections worklist and every
  /// statement are built from:
  ///
  ///     when d.due_date is null or current_date <= d.due_date
  ///       then 'current'
  ///
  /// `dueDate` comes from a date column and so is MIDNIGHT. Comparing
  /// it to `DateTime.now()` made every invoice overdue from 00:01 on
  /// the day it fell due, while the report beside it still said
  /// current -- one day wide, every invoice, every day of the year.
  /// `Todo.isOverdue` had it right and this did not.
  bool get isOverdue {
    final due = dueDate;
    if (due == null || balanceAmount <= 0 || status == 'void') return false;
    final today = DateTime.now();
    return DateTime(due.year, due.month, due.day)
        .isBefore(DateTime(today.year, today.month, today.day));
  }

  /// The fields this company added to a document.
  final Map<String, dynamic> customFields;

  factory BusinessDocument.fromJson(Map<String, dynamic> j) {
    final contact = j['contacts'];
    // The embedded line list is named after whichever table it came from.
    final rawLines =
        (j['sales_document_lines'] ?? j['purchase_document_lines']) as List?;
    return BusinessDocument(
      customFields: Map<String, dynamic>.from(
        (j['custom_fields'] as Map?) ?? const {},
      ),
      id: j['id'] as String,
      docType: j['doc_type']?.toString() ?? 'invoice',
      docNo: j['doc_no']?.toString() ?? '',
      docDate: Fmt.parseDate(j['doc_date']) ?? DateTime.now(),
      contactId: j['contact_id']?.toString() ?? '',
      contactName: contact is Map ? contact['name'] as String? : null,
      dueDate: Fmt.parseDate(j['due_date']),
      validUntil: Fmt.parseDate(j['valid_until']),
      deliveryDate: Fmt.parseDate(j['delivery_date']),
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
      serviceChargeAmount: Fmt.toDouble(j['service_charge_amount']),
      roundingAmount: Fmt.toDouble(j['rounding_amount']),
      totalAmount: Fmt.toDouble(j['total_amount']),
      paidAmount: Fmt.toDouble(j['paid_amount']),
      balanceAmount: Fmt.toDouble(j['balance_amount']),
      status: j['status']?.toString() ?? 'draft',
      fulfilmentStatus: j['fulfilment_status']?.toString() ?? 'pending',
      einvoiceStatus: j['einvoice_status']?.toString() ?? 'not_applicable',
      requiresSelfBilled: j['requires_self_billed'] == true,
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
    this.serviceStart,
    this.serviceEnd,
    this.customFields = const {},
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

  /// The period this line is earned over, or null for a line earned on
  /// the invoice date. 0309 defers a line that carries one: it credits
  /// deferred revenue instead of revenue, and a schedule releases it
  /// month by month.
  final DateTime? serviceStart;
  final DateTime? serviceEnd;

  /// True when this line will be deferred rather than earned at once.
  /// The two dates are set and cleared together — the database refuses
  /// one without the other — so either answers the question.
  bool get isDeferred => serviceStart != null;

  /// The fields this company added to a document line.
  final Map<String, dynamic> customFields;

  factory DocumentLine.fromJson(Map<String, dynamic> j) => DocumentLine(
    customFields: Map<String, dynamic>.from(
      (j['custom_fields'] as Map?) ?? const {},
    ),
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
    serviceStart: Fmt.parseDate(j['service_start']),
    serviceEnd: Fmt.parseDate(j['service_end']),
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
    this.retryCount = 0,
    this.ublPayload,
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

  /// How many times the submitter has tried and been refused.
  ///
  /// `supabase/functions/myinvois/retry.ts` counts it and stops the
  /// BULK sweep at [einvoiceMaxAttempts]; pressing Submit on the
  /// document itself is never refused, because whatever made it fail
  /// is usually what somebody has just fixed.
  final int retryCount;

  /// The document as LHDN received it.
  ///
  /// Kept on the accepted path since `0007` and, since the submitter
  /// learned to, on the REJECTED path too — which is the one that
  /// matters. A rejection names a field on a document, and until the
  /// submitter kept it the document named was the one thrown away.
  final Map<String, dynamic>? ublPayload;

  /// Whether the sweep has stopped sending this one.
  ///
  /// Shown rather than implied. A document that quietly stops being
  /// retried looks exactly like a document that is fine, and the whole
  /// point of stopping is that somebody has to go and look at it.
  bool get retriesExhausted => retryCount >= einvoiceMaxAttempts;

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
    retryCount: (j['retry_count'] as num?)?.toInt() ?? 0,
    ublPayload: j['ubl_payload'] is Map
        ? Map<String, dynamic>.from(j['ubl_payload'] as Map)
        : null,
  );
}

/// The ceiling `supabase/functions/myinvois/retry.ts` stops the bulk
/// sweep at, repeated here because Dart cannot import TypeScript.
///
/// Two copies of one number, which is a thing this repository
/// otherwise refuses -- so `einvoice_retry_test.dart` reads the real
/// figure out of `retry.ts` and asserts they agree. A screen saying
/// "stopped after 5 attempts" while the submitter stops at 3 is worse
/// than a screen saying nothing.
const int einvoiceMaxAttempts = 5;

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
    this.quotationId,
    this.quotationNo,
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

  /// The quotation this deal was priced on. A column since `0008` with
  /// a comment saying it is set when the deal is converted, and nothing
  /// set it — so the forecast came off `amount` and the invoice off the
  /// quotation, and the two never met.
  final String? quotationId;
  final String? quotationNo;

  bool get isQuoted => quotationId != null;

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
      quotationId: j['quotation_id'] as String?,
      quotationNo: j['sales_documents'] is Map
          ? j['sales_documents']['doc_no']?.toString()
          : null,
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

/// One item on the list a bookkeeper keeps beside the books.
///
/// 0526. Personal: a to-do belongs to one person at one company, and
/// nothing here can name anybody else — the row is written with the
/// signed-in user's own id and row level security refuses any other.
class Todo {
  Todo({
    required this.id,
    required this.title,
    this.notes,
    this.dueDate,
    this.priority = 'normal',
    this.doneAt,
    this.link,
    this.contactId,
    this.contactName,
  });

  factory Todo.fromJson(Map<String, dynamic> json) => Todo(
    id: json['id'] as String,
    title: json['title'] as String? ?? '',
    notes: json['notes'] as String?,
    dueDate: json['due_date'] == null
        ? null
        : DateTime.parse(json['due_date'] as String),
    priority: json['priority'] as String? ?? 'normal',
    doneAt: json['done_at'] == null
        ? null
        : DateTime.parse(json['done_at'] as String),
    link: json['link'] as String?,
    contactId: json['contact_id'] as String?,
    contactName: json['contact_name'] as String?,
  );

  /// The same item with its party's name filled in.
  ///
  /// The name is not on `todos` -- it is on `contacts`, where a rename
  /// belongs -- so the repository reads it separately and puts it here.
  Todo withContactName(String? name) => Todo(
    id: id,
    title: title,
    notes: notes,
    dueDate: dueDate,
    priority: priority,
    doneAt: doneAt,
    link: link,
    contactId: contactId,
    contactName: name,
  );

  final String id;
  final String title;
  final String? notes;
  final DateTime? dueDate;

  /// `low`, `normal` or `high`.
  final String priority;

  /// When it was cleared, or null while it is still open. A time rather
  /// than a flag, so "what did I finish yesterday" has an answer.
  final DateTime? doneAt;

  /// Where in the app this is about, if anywhere.
  final String? link;

  /// The customer or supplier this is about, if any. `0656`.
  ///
  /// Separate from [link], which is a route to a SCREEN: this is a
  /// party. "Chase Ramli" is about a party, and a route could not say
  /// which one without being parsed.
  final String? contactId;

  /// That party's name, read alongside rather than stored.
  ///
  /// Null while it has not been looked up, which is not the same as
  /// having no party -- [contactId] is what says that.
  final String? contactName;

  bool get isDone => doneAt != null;

  /// Overdue is STRICTLY before today. An item due today is due, not
  /// late, and colouring it red at one minute past midnight is how a
  /// list trains somebody to ignore the colour.
  bool isOverdue(DateTime today) {
    final due = dueDate;
    if (due == null || isDone) return false;
    return DateTime(
      due.year,
      due.month,
      due.day,
    ).isBefore(DateTime(today.year, today.month, today.day));
  }
}

/// Where somebody lands when they sign in, and what they want on the
/// dashboard. 0527. One row per person, not per company.
class UserPreferences {
  const UserPreferences({
    this.landingRoute = '/dashboard',
    this.dashboardCards = defaultDashboardCards,
  });

  factory UserPreferences.fromJson(Map<String, dynamic> json) =>
      UserPreferences(
        landingRoute: json['landing_route'] as String? ?? '/dashboard',
        dashboardCards: [
          for (final c in (json['dashboard_cards'] as List? ?? const []))
            c as String,
        ],
      );

  final String landingRoute;
  final List<String> dashboardCards;

  /// What a person who has never opened the settings screen gets.
  /// Mirrors the column default in 0527; the two are asserted against
  /// each other in `supabase/tests/user_preferences.sql` and
  /// `app/test/landing_preference_test.dart`.
  static const defaultDashboardCards = <String>[
    'todos',
    'ticker',
    'metrics',
    'trend',
    'receivables',
  ];

  bool shows(String card) => dashboardCards.contains(card);
}

/// The pages somebody may choose to land on, and what to call them.
///
/// Deliberately a short list rather than every route in the app: a
/// landing page is a place to START, and an editor for one document or
/// a screen that needs an id is not one. Each is checked against the
/// modules the company holds before it is offered.
const landingChoices = <({String route, String label, String? module})>[
  (route: '/dashboard', label: 'Dashboard', module: null),
  (route: '/todos', label: 'To-do list', module: null),
  (route: '/sales/invoice', label: 'Invoices', module: null),
  (route: '/purchases/bill', label: 'Bills', module: 'purchases'),
  (route: '/customers', label: 'Customers', module: null),
  (route: '/expenses', label: 'Expenses', module: null),
  (route: '/reports', label: 'Reports', module: null),
  (route: '/pos', label: 'Point of sale', module: 'pos'),
];

/// The panels the dashboard can show, in the order they are offered.
const dashboardCardChoices = <({String code, String label, String hint})>[
  (
    code: 'todos',
    label: 'To-do list',
    hint: 'What you have told yourself to do, soonest first',
  ),
  (
    code: 'ticker',
    label: 'Ticker',
    hint: 'The day\'s figures, running across the top',
  ),
  (code: 'metrics', label: 'Key figures', hint: 'Revenue, profit, cash, debt'),
  (code: 'trend', label: 'Revenue trend', hint: 'The last twelve months'),
  (
    code: 'receivables',
    label: 'Who owes you',
    hint: 'The oldest debts, and what is overdue',
  ),
];

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
  // The role three migrations of HRMS assume exists and nothing could
  // assign. `app.can_manage_hr` and `app.can_run_payroll` name it, 0119
  // and 0121 route expense claims to it, and 0285 was written for
  // exactly this person — "an owner running their own company, or an
  // outsourced HR administrator". Without it here, payroll and leave
  // approval could only ever be done by a company admin, which is the
  // opposite of what a delegable HR role is for.
  'hr_manager': (
    label: 'HR Manager',
    description: 'Employees, payroll, leave and claims; cannot open the ledger',
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

/// The roles a company may hand to somebody, which is every role except
/// ownership: that is transferred rather than granted, and offering it
/// in a dropdown would make "make Siti the owner" a thing an admin
/// could do to a company they do not own.
///
/// Stated once because it was stated twice — the invite dialog and the
/// row's own dropdown each carried their own `e.key != 'owner'`, and two
/// copies of a rule are two places for it to stop being true.
///
/// Deliberately *not* what an approval rule offers. `rule_editor` names
/// a role that may approve, and an owner approving their own company's
/// invoices is the ordinary case rather than a privilege escalation.
Iterable<MapEntry<String, ({String label, String description})>>
get assignableRoles => memberRoles.entries.where((e) => e.key != 'owner');

/// Whether this row of the team list may be edited from it.
///
/// Three conditions, and each one prevents something different. Written
/// out here rather than inside the row so that all three can be
/// asserted, because a rule about who may change whose access is not
/// one to discover was wrong.
///
///   * [canAdmin] — only an owner or a company admin changes anybody's
///     access at all.
///   * not [isSelf] — nobody edits their own row. An admin who demotes
///     themselves by accident has locked the company out of its own
///     administration, and there may be no one else who can undo it.
///   * [role] is not `owner` — ownership is transferred deliberately
///     and is not a line in a dropdown. Note that `assignableRoles`
///     already withholds `owner` as a DESTINATION; this is the other
///     direction, the owner as a subject.
///
/// The server refuses all three as well, and is the authority. This is
/// what stops the screen offering a control whose only outcome is an
/// error message.
bool memberIsEditable({
  required bool canAdmin,
  required bool isSelf,
  required String role,
}) =>
    canAdmin && !isSelf && role != 'owner';

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
    this.promoPrice,
    this.promotion,
    this.promoKind,
    this.promoDays,
    this.promoUntil,
  });

  final String code;
  final String name;
  final String? description;
  final bool isCore;

  /// What the price list says. Not necessarily what this company pays.
  final double monthlyPrice;
  final bool entitled;
  final bool hidden;
  final bool visible;

  /// What this company would pay for it today, which is the list price
  /// unless a promotion (0548) says otherwise. Null only for a surface
  /// built by hand in a test.
  final double? promoPrice;

  /// The promotion's name, or null when the price is the list price.
  /// Set together with [promoPrice] by the server, so `promotion !=
  /// null` is the one test for "this is not the ordinary price".
  final String? promotion;

  /// `trial`, `free`, `percent_off` or `fixed_price`.
  final String? promoKind;

  /// How long a trial runs, in days. Null for every other kind.
  final int? promoDays;

  /// The day the promotion stops, when it has an end.
  final DateTime? promoUntil;

  /// What this company pays a month, promotion and all.
  double get price => promotion == null ? monthlyPrice : (promoPrice ?? 0);

  /// True when holding it costs nothing today -- either because it was
  /// never priced, or because a promotion has taken the price off.
  bool get isFreeNow => price <= 0;

  factory ModuleSurface.fromMap(Map<String, dynamic> j) => ModuleSurface(
    code: j['module_code'] as String,
    name: j['name'] as String,
    description: j['description'] as String?,
    isCore: j['is_core'] == true,
    monthlyPrice: Fmt.toDouble(j['monthly_price']),
    entitled: j['entitled'] == true,
    hidden: j['hidden'] == true,
    visible: j['visible'] == true,
    promoPrice: j['promo_price'] == null
        ? null
        : Fmt.toDouble(j['promo_price']),
    promotion: j['promotion'] as String?,
    promoKind: j['promo_kind'] as String?,
    promoDays: (j['promo_days'] as num?)?.toInt(),
    promoUntil: DateTime.tryParse('${j['promo_until'] ?? ''}'),
  );
}

/// One add-on's share of the month, as the server pro-rated it.
class ModuleCharge {
  const ModuleCharge({
    required this.code,
    required this.name,
    required this.days,
    required this.daysInMonth,
    required this.amount,
    this.listAmount,
    this.promotion,
  });

  factory ModuleCharge.fromMap(Map<String, dynamic> m) => ModuleCharge(
    code: m['module_code'] as String? ?? '',
    name: m['name'] as String? ?? '',
    days: (m['days'] as num?)?.toInt() ?? 0,
    daysInMonth: (m['days_in_month'] as num?)?.toInt() ?? 0,
    amount: (m['amount'] as num?)?.toDouble() ?? 0,
    listAmount: (m['list_amount'] as num?)?.toDouble(),
    promotion: m['promotion'] as String?,
  );

  final String code;
  final String name;
  final int days;
  final int daysInMonth;
  final double amount;

  /// What the same days would have come to at the price list, and the
  /// name of the promotion that made them come to less (0548). A line
  /// cheaper than the published price with nothing saying why is a
  /// support ticket.
  final double? listAmount;
  final String? promotion;

  /// True for a module that was not on for the whole month — the only
  /// case where the days are worth showing. "31/31 days" beside a full
  /// month's price is noise.
  bool get isPartial => daysInMonth > 0 && days < daysInMonth;
}

/// The month in progress: what is on, and what it has cost so far.
class SubscriptionMonth {
  const SubscriptionMonth({
    required this.month,
    required this.lines,
    required this.subtotal,
    this.saved = 0,
  });

  factory SubscriptionMonth.fromMap(Map<String, dynamic> m) =>
      SubscriptionMonth(
        month: DateTime.tryParse(m['month'] as String? ?? ''),
        lines: [
          for (final l in (m['lines'] as List? ?? const []))
            ModuleCharge.fromMap(Map<String, dynamic>.from(l as Map)),
        ],
        subtotal: (m['subtotal'] as num?)?.toDouble() ?? 0,
        saved: (m['saved'] as num?)?.toDouble() ?? 0,
      );

  final DateTime? month;
  final List<ModuleCharge> lines;
  final double subtotal;

  /// What the promotions came to this month: the price list less what
  /// is actually being charged (0548).
  final double saved;
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

/// The Form C working for one basis period.
///
/// Every figure derived from the ledger, the Schedule 3 schedule and
/// the rates — nothing here is stored. A computation opened a year
/// later still agrees with the books it came from, which is the whole
/// reason it is computed rather than typed.
class TaxComputation {
  TaxComputation({
    required this.yearOfAssessment,
    required this.periodFrom,
    required this.periodTo,
    required this.profitBeforeTax,
    required this.addBacks,
    required this.deductions,
    required this.balancingCharge,
    required this.adjustedIncome,
    required this.adjustedLoss,
    required this.caCurrent,
    required this.caBroughtForward,
    required this.caUsed,
    required this.caCarriedForward,
    required this.statutoryIncome,
    required this.lossBroughtForward,
    required this.lossUsed,
    required this.lossCarriedForward,
    required this.chargeableIncome,
    required this.isSme,
    required this.smeKnown,
    required this.taxCharged,
    required this.zakatRebate,
    required this.s110TaxDeducted,
    required this.cp204Paid,
    required this.taxPayable,
  });

  final int yearOfAssessment;
  final DateTime? periodFrom;
  final DateTime? periodTo;

  final double profitBeforeTax;
  final double addBacks;
  final double deductions;

  /// Taxable, and reported on its own rather than folded into the
  /// add-backs: it comes from a disposal rather than from an account,
  /// and a reviewer looking for it looks for it by name.
  final double balancingCharge;

  final double adjustedIncome;

  /// A loss is reported as a positive number under its own name. The
  /// adjusted income is nothing in that case, not a negative, because
  /// nothing downstream may be computed from a negative income.
  final double adjustedLoss;

  final double caCurrent;
  final double caBroughtForward;
  final double caUsed;

  /// Unabsorbed capital allowance. NOT a loss: it carries forward under
  /// its own rules and the two must never be added together.
  final double caCarriedForward;

  final double statutoryIncome;
  final double lossBroughtForward;
  final double lossUsed;
  final double lossCarriedForward;
  final double chargeableIncome;

  /// Whether the preferential band applies.
  final bool isSme;

  /// Whether the test could be taken at all. False means the two
  /// figures it needs have not both been given — and the computation
  /// then charges the standard rate while SAYING it does not know,
  /// rather than quietly assuming the company does not qualify.
  final bool smeKnown;

  final double taxCharged;
  final double zakatRebate;
  final double s110TaxDeducted;
  final double cp204Paid;

  /// Negative means refundable. Not clamped at zero: a refund is a real
  /// answer and rounding it away hides money the company is owed.
  final double taxPayable;

  bool get isRefund => taxPayable < 0;
  bool get hasLoss => adjustedLoss > 0;

  factory TaxComputation.fromMap(Map<String, dynamic> j) => TaxComputation(
    yearOfAssessment: Fmt.toInt(j['year_of_assessment']),
    periodFrom: Fmt.parseDate(j['period_from']),
    periodTo: Fmt.parseDate(j['period_to']),
    profitBeforeTax: Fmt.toDouble(j['profit_before_tax']),
    addBacks: Fmt.toDouble(j['add_backs']),
    deductions: Fmt.toDouble(j['deductions']),
    balancingCharge: Fmt.toDouble(j['balancing_charge']),
    adjustedIncome: Fmt.toDouble(j['adjusted_income']),
    adjustedLoss: Fmt.toDouble(j['adjusted_loss']),
    caCurrent: Fmt.toDouble(j['ca_current']),
    caBroughtForward: Fmt.toDouble(j['ca_brought_forward']),
    caUsed: Fmt.toDouble(j['ca_used']),
    caCarriedForward: Fmt.toDouble(j['ca_carried_forward']),
    statutoryIncome: Fmt.toDouble(j['statutory_income']),
    lossBroughtForward: Fmt.toDouble(j['loss_brought_forward']),
    lossUsed: Fmt.toDouble(j['loss_used']),
    lossCarriedForward: Fmt.toDouble(j['loss_carried_forward']),
    chargeableIncome: Fmt.toDouble(j['chargeable_income']),
    isSme: j['is_sme'] == true,
    smeKnown: j['sme_known'] == true,
    taxCharged: Fmt.toDouble(j['tax_charged']),
    zakatRebate: Fmt.toDouble(j['zakat_rebate']),
    s110TaxDeducted: Fmt.toDouble(j['s110_tax_deducted']),
    cp204Paid: Fmt.toDouble(j['cp204_paid']),
    taxPayable: Fmt.toDouble(j['tax_payable']),
  );
}

/// One instalment of a CP204 estimate.
class TaxInstalment {
  TaxInstalment({
    required this.number,
    required this.dueOn,
    required this.amount,
  });

  final int number;
  final DateTime? dueOn;
  final double amount;

  factory TaxInstalment.fromMap(Map<String, dynamic> j) => TaxInstalment(
    number: Fmt.toInt(j['instalment_no']),
    dueOn: Fmt.parseDate(j['due_on']),
    amount: Fmt.toDouble(j['amount']),
  );
}

/// One income tax obligation, against one period, with its date.
///
/// Three things here are decisions rather than data, and each is the
/// answer to a mistake `0668` was written to prevent:
///
///   * [dueDate] is the STATUTORY date. [efilingDueDate] is a
///     concession LHDN republishes every year and has changed, so it
///     is beside the deadline and never instead of it.
///   * [periodFrom] and [periodTo] are not always the company's own
///     financial year. Form E covers a calendar year whatever the year
///     end is, and the server labels it accordingly.
///   * [daysLeft] goes negative rather than stopping at zero. An
///     obligation already missed is the one somebody most needs to
///     see.
class TaxFiling {
  TaxFiling({
    required this.filingType,
    required this.name,
    required this.formLabel,
    required this.periodFrom,
    required this.periodTo,
    required this.yearOfAssessment,
    required this.dueDate,
    required this.daysLeft,
    required this.isOverdue,
    required this.status,
    this.statuteRef,
    this.efilingDueDate,
    this.description,
    this.fiscalYearId,
    this.computationId,
    this.estimateId,
    this.filingId,
  });

  final String filingType;
  final String name;

  /// What somebody looks for on LHDN's site: 'C', 'B', 'E', 'CP204'.
  final String formLabel;
  final String? statuteRef;

  final DateTime? periodFrom;
  final DateTime? periodTo;
  final int yearOfAssessment;

  final DateTime? dueDate;

  /// Null where the Filing Programme grants nothing for this form —
  /// which is not the same as granting nothing this year.
  final DateTime? efilingDueDate;

  final int daysLeft;
  final bool isOverdue;
  final String? description;

  /// `not_started`, or `in_preparation` where somebody has begun it.
  /// `filed` and `not_applicable` never appear here — `0669` takes
  /// those off the list, which is the whole point of recording one.
  final String status;
  final String? filingId;

  final String? fiscalYearId;

  /// The working already opened for this period, where there is one.
  /// A deadline with nothing behind it is a deadline nobody has
  /// started.
  final String? computationId;
  final String? estimateId;

  /// Close enough to interrupt somebody about. A month is the point
  /// at which a Form C still has time to be prepared and a CP204 does
  /// not — so it is a warning rather than a countdown.
  bool get isImminent => !isOverdue && daysLeft <= 30;

  /// Whether the work behind it has been started at all.
  bool get hasWorking => computationId != null || estimateId != null;

  /// Somebody has said they are on it. NOT that it is done: a Form C
  /// in preparation is still on the list, and a screen that treated
  /// the two the same would clear a deadline on the intention to meet
  /// it.
  bool get isStarted => status == 'in_preparation';

  factory TaxFiling.fromMap(Map<String, dynamic> j) => TaxFiling(
    filingType: j['filing_type']?.toString() ?? '',
    name: j['filing_name']?.toString() ?? '',
    formLabel: j['form_label']?.toString() ?? '',
    statuteRef: j['statute_ref']?.toString(),
    periodFrom: Fmt.parseDate(j['period_from']),
    periodTo: Fmt.parseDate(j['period_to']),
    yearOfAssessment: Fmt.toInt(j['year_of_assessment']),
    dueDate: Fmt.parseDate(j['due_date']),
    efilingDueDate: Fmt.parseDate(j['efiling_due_date']),
    daysLeft: Fmt.toInt(j['days_left']),
    isOverdue: j['is_overdue'] == true,
    status: j['status']?.toString() ?? 'not_started',
    description: j['description']?.toString(),
    fiscalYearId: j['fiscal_year_id']?.toString(),
    computationId: j['computation_id']?.toString(),
    estimateId: j['estimate_id']?.toString(),
    filingId: j['filing_id']?.toString(),
  );
}

/// What somebody recorded against an obligation, after the fact.
///
/// The counterpart to [TaxFiling]: that is what is still owed, this is
/// what was done about one. Nothing disappears when a deadline comes
/// off the calendar — it moves here, including a dismissal and the
/// reason given for it.
class TaxFilingRecord {
  TaxFilingRecord({
    required this.id,
    required this.filingType,
    required this.name,
    required this.formLabel,
    required this.periodTo,
    required this.yearOfAssessment,
    required this.status,
    required this.wasLate,
    this.periodFrom,
    this.dueDate,
    this.filedOn,
    this.reference,
    this.notes,
  });

  final String id;
  final String filingType;
  final String name;
  final String formLabel;
  final DateTime? periodFrom;
  final DateTime? periodTo;
  final int yearOfAssessment;

  final DateTime? dueDate;
  final String status;
  final DateTime? filedOn;

  /// LHDN's acknowledgement, which is the only thing that proves any
  /// of this happened.
  final String? reference;
  final String? notes;

  /// Recorded as filed after the date it was due. Computed on the
  /// server rather than here, because the two dates sit in different
  /// columns of the same row and whether one is after the other is
  /// what a penalty is assessed on.
  final bool wasLate;

  /// Somebody said this obligation does not apply. It carries a reason
  /// and stays readable, because a CP58 clicked away has to be
  /// findable when LHDN asks about it.
  bool get isDismissed => status == 'not_applicable';
  bool get isFiled => status == 'filed';

  factory TaxFilingRecord.fromMap(Map<String, dynamic> j) => TaxFilingRecord(
    id: j['filing_id']?.toString() ?? '',
    filingType: j['filing_type']?.toString() ?? '',
    name: j['filing_name']?.toString() ?? '',
    formLabel: j['form_label']?.toString() ?? '',
    periodFrom: Fmt.parseDate(j['period_from']),
    periodTo: Fmt.parseDate(j['period_to']),
    yearOfAssessment: Fmt.toInt(j['year_of_assessment']),
    dueDate: Fmt.parseDate(j['due_date']),
    status: j['status']?.toString() ?? '',
    filedOn: Fmt.parseDate(j['filed_on']),
    reference: j['reference']?.toString(),
    notes: j['notes']?.toString(),
    wasLate: j['was_late'] == true,
  );
}

/// Whether an estimate is allowed, and whether it is high enough.
///
/// Two different questions with two different answers, and conflating
/// them is the mistake this exists to prevent. The FLOOR is about last
/// year — an estimate below the required share of it is not low, it is
/// invalid. The EXPOSURE is about this year, and an estimate can clear
/// the floor comfortably and still be penalised.
class TaxEstimateExposure {
  TaxEstimateExposure({
    required this.estimatedTax,
    required this.meetsFloor,
    required this.floorKnown,
    required this.actualKnown,
    required this.revisionOpen,
    required this.revisionMonths,
    this.priorEstimate,
    this.floorRequired,
    this.actualTax,
    this.shortfall,
    this.toleranceAmount,
    this.excessOverTolerance,
    this.penalty,
  });

  final double estimatedTax;

  /// Null means nobody has said what last year's estimate was.
  final double? priorEstimate;
  final double? floorRequired;

  /// False when the floor is unknown as well as when it is missed.
  /// Read it with [floorKnown]: a tick beside a figure nobody has
  /// checked is worse than an honest question mark.
  final bool meetsFloor;
  final bool floorKnown;

  /// All of these are null until there is a computation to measure
  /// against — which there is not, for most of the year.
  final double? actualTax;
  final bool actualKnown;
  final double? shortfall;
  final double? toleranceAmount;
  final double? excessOverTolerance;

  /// Null is "not yet known", which is NOT the same as zero. A penalty
  /// of nothing is a promise; a penalty of null is a question.
  final double? penalty;

  /// Whether today falls in a month a revision is allowed in.
  final bool revisionOpen;
  final List<int> revisionMonths;

  /// Under-estimated far enough to cost money. False while unknown,
  /// because the screen must not cry wolf in the second month.
  bool get isExposed => actualKnown && (penalty ?? 0) > 0;

  /// The one state worth interrupting somebody for: money is at stake
  /// AND there is still a month in which to fix it.
  bool get canStillFix => isExposed && revisionOpen;

  factory TaxEstimateExposure.fromMap(Map<String, dynamic> j) =>
      TaxEstimateExposure(
        estimatedTax: Fmt.toDouble(j['estimated_tax']),
        priorEstimate: j['prior_estimate'] == null
            ? null
            : Fmt.toDouble(j['prior_estimate']),
        floorRequired: j['floor_required'] == null
            ? null
            : Fmt.toDouble(j['floor_required']),
        meetsFloor: j['meets_floor'] == true,
        floorKnown: j['floor_known'] == true,
        actualTax:
            j['actual_tax'] == null ? null : Fmt.toDouble(j['actual_tax']),
        actualKnown: j['actual_known'] == true,
        shortfall:
            j['shortfall'] == null ? null : Fmt.toDouble(j['shortfall']),
        toleranceAmount: j['tolerance_amount'] == null
            ? null
            : Fmt.toDouble(j['tolerance_amount']),
        excessOverTolerance: j['excess_over_tolerance'] == null
            ? null
            : Fmt.toDouble(j['excess_over_tolerance']),
        penalty: j['penalty'] == null ? null : Fmt.toDouble(j['penalty']),
        revisionOpen: j['revision_open'] == true,
        revisionMonths: [
          for (final m in (j['revision_months'] as List? ?? const []))
            Fmt.toInt(m),
        ],
      );
}

/// The Form B working: a person with business income.
///
/// The business is ONE source. Employment, rent and a share of a
/// partnership join it at aggregate income, approved donations come
/// off, personal reliefs come off after that, and the resident
/// individual scale applies — the same scale PCB uses, so the monthly
/// estimate and the annual return cannot disagree.
class IndividualTaxComputation {
  IndividualTaxComputation({
    required this.yearOfAssessment,
    required this.periodFrom,
    required this.periodTo,
    required this.profitBeforeTax,
    required this.addBacks,
    required this.deductions,
    required this.balancingCharge,
    required this.adjustedIncome,
    required this.adjustedLoss,
    required this.caCurrent,
    required this.caUsed,
    required this.caCarriedForward,
    required this.statutoryBusiness,
    required this.otherIncome,
    required this.aggregateIncome,
    required this.approvedDonations,
    required this.donationsAllowed,
    required this.totalIncome,
    required this.reliefsClaimed,
    required this.chargeableIncome,
    required this.taxCharged,
    required this.rebate,
    required this.zakatRebate,
    required this.s110TaxDeducted,
    required this.instalmentsPaid,
    required this.taxPayable,
  });

  final int yearOfAssessment;
  final DateTime? periodFrom;
  final DateTime? periodTo;

  final double profitBeforeTax;
  final double addBacks;
  final double deductions;
  final double balancingCharge;
  final double adjustedIncome;
  final double adjustedLoss;
  final double caCurrent;
  final double caUsed;
  final double caCarriedForward;
  final double statutoryBusiness;

  final double otherIncome;
  final double aggregateIncome;

  /// What was claimed, which is not always what was allowed.
  final double approvedDonations;

  /// s.44(6) cannot take aggregate income below nothing, so a donation
  /// larger than the income is allowed only up to it and the excess is
  /// simply lost — not carried anywhere.
  final double donationsAllowed;

  final double totalIncome;
  final double reliefsClaimed;
  final double chargeableIncome;
  final double taxCharged;

  /// The flat rebate for a chargeable income at or under the
  /// threshold. A cliff, not a taper.
  final double rebate;

  final double zakatRebate;
  final double s110TaxDeducted;
  final double instalmentsPaid;
  final double taxPayable;

  bool get isRefund => taxPayable < 0;
  bool get hasLoss => adjustedLoss > 0;

  /// Whether a donation was cut down to fit the income. Worth saying on
  /// the screen: the claimed figure and the allowed one differ, and
  /// nobody expects that.
  bool get donationsRestricted => donationsAllowed < approvedDonations;

  factory IndividualTaxComputation.fromMap(Map<String, dynamic> j) =>
      IndividualTaxComputation(
        yearOfAssessment: Fmt.toInt(j['year_of_assessment']),
        periodFrom: Fmt.parseDate(j['period_from']),
        periodTo: Fmt.parseDate(j['period_to']),
        profitBeforeTax: Fmt.toDouble(j['profit_before_tax']),
        addBacks: Fmt.toDouble(j['add_backs']),
        deductions: Fmt.toDouble(j['deductions']),
        balancingCharge: Fmt.toDouble(j['balancing_charge']),
        adjustedIncome: Fmt.toDouble(j['adjusted_income']),
        adjustedLoss: Fmt.toDouble(j['adjusted_loss']),
        caCurrent: Fmt.toDouble(j['ca_current']),
        caUsed: Fmt.toDouble(j['ca_used']),
        caCarriedForward: Fmt.toDouble(j['ca_carried_forward']),
        statutoryBusiness: Fmt.toDouble(j['statutory_business']),
        otherIncome: Fmt.toDouble(j['other_income']),
        aggregateIncome: Fmt.toDouble(j['aggregate_income']),
        approvedDonations: Fmt.toDouble(j['approved_donations']),
        donationsAllowed: Fmt.toDouble(j['donations_allowed']),
        totalIncome: Fmt.toDouble(j['total_income']),
        reliefsClaimed: Fmt.toDouble(j['reliefs_claimed']),
        chargeableIncome: Fmt.toDouble(j['chargeable_income']),
        taxCharged: Fmt.toDouble(j['tax_charged']),
        rebate: Fmt.toDouble(j['rebate']),
        zakatRebate: Fmt.toDouble(j['zakat_rebate']),
        s110TaxDeducted: Fmt.toDouble(j['s110_tax_deducted']),
        instalmentsPaid: Fmt.toDouble(j['instalments_paid']),
        taxPayable: Fmt.toDouble(j['tax_payable']),
      );
}

/// What one partner carries into their own Form B.
class PartnerAllocation {
  PartnerAllocation({
    required this.partnerId,
    required this.name,
    required this.sharePercent,
    required this.salary,
    required this.interestOnCapital,
    required this.shareOfDivisible,
    required this.capitalAllowances,
    required this.statutoryIncome,
    this.taxReference,
  });

  final String partnerId;
  final String name;
  final String? taxReference;
  final double sharePercent;

  /// Appropriations, which belong to this partner alone. A salary to a
  /// partner is not an expense of the partnership — a partner cannot
  /// employ themselves — so it is added back and handed to them here.
  final double salary;
  final double interestOnCapital;

  final double shareOfDivisible;
  final double capitalAllowances;
  final double statutoryIncome;

  factory PartnerAllocation.fromMap(Map<String, dynamic> j) =>
      PartnerAllocation(
        partnerId: j['partner_id'] as String,
        name: j['name']?.toString() ?? '',
        taxReference: j['tax_reference'] as String?,
        sharePercent: Fmt.toDouble(j['share_percent']),
        salary: Fmt.toDouble(j['salary']),
        interestOnCapital: Fmt.toDouble(j['interest_on_capital']),
        shareOfDivisible: Fmt.toDouble(j['share_of_divisible']),
        capitalAllowances: Fmt.toDouble(j['capital_allowances']),
        statutoryIncome: Fmt.toDouble(j['statutory_income']),
      );
}

/// The head of a Form P, and the two figures that catch a half-entered
/// one.
class PartnershipSummary {
  PartnershipSummary({
    required this.adjustedIncome,
    required this.appropriations,
    required this.divisibleIncome,
    required this.partnershipAdjusted,
    required this.totalAllocated,
    required this.sharesTotal,
    required this.partnerCount,
  });

  final double adjustedIncome;
  final double appropriations;
  final double divisibleIncome;

  /// The partnership's real adjusted income: what the accounts showed
  /// plus the appropriations added back.
  final double partnershipAdjusted;

  final double totalAllocated;
  final double sharesTotal;
  final int partnerCount;

  /// A partnership whose ratios come to ninety allocates nine tenths of
  /// its income and the missing tenth appears nowhere — the allocation
  /// still adds up, down its own column, to the wrong number.
  ///
  /// A tolerance, not equality, and 0.05 rather than something
  /// tighter. A deed that splits three ways writes 33.33 and comes to
  /// 99.99; six ways at 16.67 comes to 100.02. Both are right and a
  /// stricter check would put a red warning on most partnerships in
  /// the country.
  ///
  /// Loose enough to admit the rounding, tight enough that a whole per
  /// cent missing — which is a partner somebody forgot — still shows.
  bool get sharesBalance =>
      partnerCount > 0 && (sharesTotal - 100).abs() <= 0.05;

  bool get isEmpty => partnerCount == 0;

  factory PartnershipSummary.fromMap(Map<String, dynamic> j) =>
      PartnershipSummary(
        adjustedIncome: Fmt.toDouble(j['adjusted_income']),
        appropriations: Fmt.toDouble(j['appropriations']),
        divisibleIncome: Fmt.toDouble(j['divisible_income']),
        partnershipAdjusted: Fmt.toDouble(j['partnership_adjusted']),
        totalAllocated: Fmt.toDouble(j['total_allocated']),
        sharesTotal: Fmt.toDouble(j['shares_total']),
        partnerCount: Fmt.toInt(j['partner_count']),
      );
}

/// One add-back or deduction, and where it came from.
class TaxComputationLine {
  TaxComputationLine({
    required this.kind,
    required this.label,
    required this.source,
    required this.gross,
    required this.fraction,
    required this.amount,
    this.code,
    this.reference,
  });

  /// 'add_back' or 'deduct'.
  final String kind;
  final String label;

  /// The account this came from, or the reason somebody typed.
  final String source;

  /// The account's whole balance, before the fraction.
  final double gross;

  /// How much of it the treatment applies to. Half, for entertainment.
  final double fraction;

  final double amount;
  final String? code;
  final String? reference;

  bool get isAddBack => kind == 'add_back';

  /// Whether only part of the balance was taken, which is worth showing
  /// beside the figure: "50% of 12,000" answers the question a bare
  /// 6,000 provokes.
  bool get isPartial => fraction < 1;

  factory TaxComputationLine.fromMap(Map<String, dynamic> j) =>
      TaxComputationLine(
        kind: j['kind']?.toString() ?? 'add_back',
        label: j['label']?.toString() ?? '',
        source: j['source']?.toString() ?? '',
        gross: Fmt.toDouble(j['gross']),
        fraction: Fmt.toDouble(j['fraction']),
        amount: Fmt.toDouble(j['amount']),
        code: j['code'] as String?,
        reference: j['reference'] as String?,
      );
}

/// A Schedule 3 class an asset can be put in.
///
/// Read from the database rather than listed in Dart: Budget speeches
/// move the rates, and a list here would be a second copy to forget.
class CapitalAllowanceClass {
  CapitalAllowanceClass({
    required this.code,
    required this.label,
    required this.initialRate,
    required this.annualRate,
    this.costCap,
    this.smallValueThreshold,
    this.notes,
    this.isVerified = false,
  });

  final String code;
  final String label;
  final double initialRate;
  final double annualRate;
  final double? costCap;
  final double? smallValueThreshold;
  final String? notes;

  /// False means the figures came from published percentages rather
  /// than from the Act. `0025` uses the same flag for the payroll
  /// schedules and means the same thing by it.
  final bool isVerified;

  /// "20% then 14%", which is what somebody choosing a class is
  /// actually comparing.
  ///
  /// `Fmt.qty` rather than `Fmt.rate`: the latter pads to two decimals,
  /// so every class in the dropdown would read "20.00% then 14.00%".
  /// This drops the zeros on a whole percentage and keeps them on a
  /// fractional one, which is what an industrial building's 3% and a
  /// hypothetical 2.5% both need.
  /// Rounded before it is formatted, because `0.14 * 100` is
  /// `14.000000000000002` in binary floating point -- and `Fmt.qty`
  /// faithfully prints every digit of it. Without this the dropdown
  /// offers "20% then 14.000000000000002%".
  static String _pct(double rate) =>
      Fmt.qty(double.parse((rate * 100).toStringAsFixed(4)));

  String get rates => '${_pct(initialRate)}% then ${_pct(annualRate)}%';

  factory CapitalAllowanceClass.fromMap(Map<String, dynamic> j) =>
      CapitalAllowanceClass(
        code: j['code'] as String,
        label: j['label']?.toString() ?? '',
        initialRate: Fmt.toDouble(j['initial_rate']),
        annualRate: Fmt.toDouble(j['annual_rate']),
        costCap: j['cost_cap'] == null ? null : Fmt.toDouble(j['cost_cap']),
        smallValueThreshold: j['small_value_threshold'] == null
            ? null
            : Fmt.toDouble(j['small_value_threshold']),
        notes: j['notes'] as String?,
        isVerified: j['is_verified'] == true,
      );
}

/// One line of the Schedule 3 working for a year of assessment.
///
/// Not a depreciation row. Accounting depreciation is added back in a
/// tax computation and replaced by these, so an asset appears in both
/// schedules with two entirely different figures against it — which is
/// the point of the exercise rather than a discrepancy.
class CapitalAllowanceLine {
  CapitalAllowanceLine({
    required this.assetId,
    required this.assetNo,
    required this.name,
    required this.classCode,
    required this.classLabel,
    required this.acquired,
    required this.cost,
    required this.qualifying,
    required this.initial,
    required this.annual,
    required this.priorClaimed,
    required this.balancingAllowance,
    required this.balancingCharge,
    required this.claimed,
    required this.residual,
  });

  final String assetId;
  final String assetNo;
  final String name;
  final String classCode;
  final String classLabel;
  final DateTime? acquired;

  /// What was paid, which is not always what the allowance is computed
  /// on — see [qualifying].
  final double cost;

  /// What the allowance is computed on. Lower than [cost] for a vehicle
  /// in a restricted class, and the difference is relief nobody gets.
  final double qualifying;

  final double initial;
  final double annual;
  final double priorClaimed;
  final double balancingAllowance;
  final double balancingCharge;

  /// The initial and annual allowances for this year, which is what a
  /// tax computation subtracts. The balancing figures are NOT in here:
  /// one is an extra deduction and the other is taxable, and adding
  /// them together would net off two things that go in different
  /// places on the return.
  final double claimed;

  final double residual;

  /// Whether the cost was restricted before any allowance was computed.
  bool get isRestricted => qualifying < cost;

  /// An asset filed in a small-value class that is not a small-value
  /// asset. It gets nothing at all rather than being written off in
  /// full, and its residual sits at the whole qualifying expenditure —
  /// which is what this spots, so the screen can say to reclassify it.
  /// `qualifying > 0` is stated rather than left to follow from
  /// `residual > 0`. An asset that cost nothing -- `fixed_assets`
  /// allows it, the check is `cost >= 0` -- has a qualifying sum of
  /// zero and a residual of zero, and every other condition here is
  /// trivially true of it. Without this line it reads as misfiled and
  /// the screen puts a red notice on a row there is nothing wrong with.
  bool get looksMisclassified =>
      qualifying > 0 &&
      initial == 0 &&
      annual == 0 &&
      priorClaimed == 0 &&
      // These two are EQUIVALENT today and are kept deliberately. A
      // row with a balancing figure was disposed of, and `0664` sets
      // its residual to zero -- so `residual == qualifying` already
      // excludes it unless the qualifying sum is zero, which the line
      // above now excludes. A mutant that deletes them survives, and
      // that is written down rather than left for somebody to discover
      // and mistake for a gap.
      //
      // They stay because they say what the predicate MEANS. If the
      // schedule ever leaves a residual on a disposed asset -- a part
      // disposal, say -- these are what stop it turning red.
      balancingAllowance == 0 &&
      balancingCharge == 0 &&
      residual == qualifying;

  factory CapitalAllowanceLine.fromMap(Map<String, dynamic> j) =>
      CapitalAllowanceLine(
        assetId: j['asset_id'] as String,
        assetNo: j['asset_no']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        classCode: j['class_code']?.toString() ?? '',
        classLabel: j['class_label']?.toString() ?? '',
        acquired: Fmt.parseDate(j['acquired']),
        cost: Fmt.toDouble(j['cost']),
        qualifying: Fmt.toDouble(j['qualifying']),
        initial: Fmt.toDouble(j['initial']),
        annual: Fmt.toDouble(j['annual']),
        priorClaimed: Fmt.toDouble(j['prior_claimed']),
        balancingAllowance: Fmt.toDouble(j['balancing_allowance']),
        balancingCharge: Fmt.toDouble(j['balancing_charge']),
        claimed: Fmt.toDouble(j['claimed']),
        residual: Fmt.toDouble(j['residual']),
      );
}

/// The cast down a capital allowance schedule.
///
/// An accountant totals a schedule before believing a line of it, and
/// these four totals are the ones that leave this screen: the
/// allowances claimed and the balancing allowance are deductions, the
/// balancing charge is taxable, and the residual is what carries
/// forward.
({
  double qualifying,
  double claimed,
  double balancingAllowance,
  double balancingCharge,
  double residual,
})
capitalAllowanceTotals(List<CapitalAllowanceLine> rows) => (
  qualifying: rows.fold(0.0, (s, r) => s + r.qualifying),
  claimed: rows.fold(0.0, (s, r) => s + r.claimed),
  balancingAllowance: rows.fold(0.0, (s, r) => s + r.balancingAllowance),
  balancingCharge: rows.fold(0.0, (s, r) => s + r.balancingCharge),
  residual: rows.fold(0.0, (s, r) => s + r.residual),
);

/// Somebody on the beta list, as the console shows them.
///
/// [addedBy] is a name and is NULLABLE, because `beta_testers.added_by`
/// is ON DELETE SET NULL: the person who added a tester may have left,
/// and the tester still has the button.
class BetaTester {
  BetaTester({
    required this.userId,
    this.fullName,
    this.email,
    this.note,
    this.addedBy,
    this.createdAt,
  });

  final String userId;
  final String? fullName;
  final String? email;
  final String? note;
  final String? addedBy;
  final DateTime? createdAt;

  /// What to call them on screen.
  ///
  /// A name, then an e-mail, then the uuid -- which is not pretty and
  /// is better than a blank row nobody can act on. A profile with
  /// neither exists: somebody invited who has not signed in yet.
  String get label => switch ((fullName?.trim(), email?.trim())) {
    (final n?, _) when n.isNotEmpty => n,
    (_, final e?) when e.isNotEmpty => e,
    _ => userId,
  };

  factory BetaTester.fromMap(Map<String, dynamic> j) => BetaTester(
    userId: j['user_id'] as String,
    fullName: j['full_name'] as String?,
    email: j['email'] as String?,
    note: j['note'] as String?,
    addedBy: j['added_by'] as String?,
    createdAt: Fmt.parseDate(j['created_at']),
  );
}

/// A person the platform console found, and whether they are already on
/// the beta list.
///
/// [isBeta] comes from the search itself rather than from comparing
/// against the list on this side: the console offers hundreds of people
/// and holds a dozen, and asking the server once is cheaper than every
/// row asking the list.
class PlatformUser {
  PlatformUser({
    required this.userId,
    this.fullName,
    this.email,
    this.isBeta = false,
  });

  final String userId;
  final String? fullName;
  final String? email;
  final bool isBeta;

  String get label => switch ((fullName?.trim(), email?.trim())) {
    (final n?, _) when n.isNotEmpty => n,
    (_, final e?) when e.isNotEmpty => e,
    _ => userId,
  };

  factory PlatformUser.fromMap(Map<String, dynamic> j) => PlatformUser(
    userId: j['user_id'] as String,
    fullName: j['full_name'] as String?,
    email: j['email'] as String?,
    isBeta: j['is_beta'] == true,
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
    this.opposingParty,
    this.feeEarner,
    this.agreedFee,
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

  /// Who is on the other side. The column a conflict check reads, and
  /// nothing wrote it before `0383` — so "do we act for the people this
  /// file is against" had no answer in the data.
  final String? opposingParty;

  /// Who does the work, as against the responsible solicitor who
  /// supervises it. An open file has one, because time is recorded by
  /// whoever is signed in.
  final String? feeEarner;

  /// What a fixed-fee client was told it would cost.
  final double? agreedFee;

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
      opposingParty: j['opposing_party'] as String?,
      feeEarner: j['fee_earner'] as String?,
      agreedFee:
          j['agreed_fee'] == null ? null : Fmt.toDouble(j['agreed_fee']),
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
    this.lastWorkingDate,
    this.basicSalary = 0,
    this.nric,
    this.epfNo,
    this.socsoNo,
    this.incomeTaxNo,
    this.cp38Monthly = 0,
    this.zakatMonthly = 0,
    this.epfVoluntaryEmployeeRate = 0,
    this.epfVoluntaryEmployerRate = 0,
    this.bankName,
    this.bankAccountNo,
    this.emergencyContactName,
    this.emergencyContactPhone,
    this.emergencyContactRelation,
    this.maritalStatus = 'single',
    this.residencyStatus = 'citizen',
    this.dateOfBirth,
    this.userId,
    this.customFields = const {},
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

  /// The day they last worked, and the only thing the payroll run reads
  /// when deciding whether to pay somebody. `employment_status` is not
  /// consulted by `calculate_payroll_run` at all, which is why `0371`
  /// refuses to let the two say different things.
  final DateTime? lastWorkingDate;
  final double basicSalary;
  final String? nric;
  final String? epfNo;
  final String? socsoNo;
  final String? incomeTaxNo;

  /// What LHDN has directed be deducted on top of the month's PCB.
  /// `calculate_payroll_run` deducts it and `post_payroll_run` remits
  /// `pcb + cp38` together, and until this reached the editor there was
  /// nowhere to put a CP38 direction when one arrived.
  final double cp38Monthly;

  /// Zakat deducted monthly, which is a rebate against PCB rather than
  /// another deduction: the engine passes it into the PCB calculation.
  /// Left at zero, a Muslim employee paying zakat over-pays PCB every
  /// month of the year.
  final double zakatMonthly;

  /// Contributions above the statutory rate, as percentages of the EPF
  /// wage. An employer contributing 15% rather than 13% enters 2 here,
  /// not 0.02 — `epf_voluntary_employer_rate` is divided by 100.
  final double epfVoluntaryEmployeeRate;
  final double epfVoluntaryEmployerRate;
  final String? bankName;
  final String? bankAccountNo;

  /// Who to call. Columns since `0025` that nothing wrote and nothing
  /// read, so the register an employer is expected to keep had a hole
  /// in it exactly where it is needed.
  final String? emergencyContactName;
  final String? emergencyContactPhone;
  final String? emergencyContactRelation;
  final String maritalStatus;
  final String residencyStatus;
  final DateTime? dateOfBirth;
  final String? userId;

  /// True when this row came from the directory function, which carries
  /// no pay data — used to hide salary rather than show a false zero.
  bool get isDirectoryOnly => basicSalary == 0 && nric == null;

  /// The fields this company added for itself.
  final Map<String, dynamic> customFields;

  factory Employee.fromJson(Map<String, dynamic> j) {
    final dept = j['departments'];
    final pos = j['positions'];
    return Employee(
      customFields: Map<String, dynamic>.from(
        (j['custom_fields'] as Map?) ?? const {},
      ),
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
      lastWorkingDate: Fmt.parseDate(j['last_working_date']),
      basicSalary: Fmt.toDouble(j['basic_salary']),
      nric: j['nric']?.toString(),
      epfNo: j['epf_no']?.toString(),
      socsoNo: j['socso_no']?.toString(),
      incomeTaxNo: j['income_tax_no']?.toString(),
      cp38Monthly: Fmt.toDouble(j['cp38_monthly']),
      zakatMonthly: Fmt.toDouble(j['zakat_monthly']),
      epfVoluntaryEmployeeRate:
          Fmt.toDouble(j['epf_voluntary_employee_rate']),
      epfVoluntaryEmployerRate:
          Fmt.toDouble(j['epf_voluntary_employer_rate']),
      bankName: j['bank_name']?.toString(),
      bankAccountNo: j['bank_account_no']?.toString(),
      emergencyContactName: j['emergency_contact_name']?.toString(),
      emergencyContactPhone: j['emergency_contact_phone']?.toString(),
      emergencyContactRelation:
          j['emergency_contact_relation']?.toString(),
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
    this.isAdjusted = false,
    this.adjustmentReason,
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

  /// Somebody in HR changed these times, and said why. 0363. The
  /// question anybody asks about a corrected timesheet is not what it
  /// says now.
  final bool isAdjusted;
  final String? adjustmentReason;

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
      isAdjusted: j['is_adjusted'] == true,
      adjustmentReason: j['adjustment_reason']?.toString(),
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
    this.allowHalfDay = true,
  });

  final String id;
  final String code;
  final String name;
  final bool isPaid;
  final double defaultDays;

  /// Whether this leave may be taken in half days. `0365` built the rule
  /// and `0397` measured that nothing had ever set the flag it guards,
  /// so the rule had never once been reached. Read here so the form can
  /// stop offering what the database would refuse.
  final bool allowHalfDay;

  factory LeaveType.fromJson(Map<String, dynamic> j) => LeaveType(
    id: j['id'] as String,
    code: j['code']?.toString() ?? '',
    name: j['name']?.toString() ?? '',
    isPaid: j['is_paid'] == true,
    defaultDays: Fmt.toDouble(j['default_days']),
    // Absent means allowed, matching the column's own default.
    allowHalfDay: j['allow_half_day'] != false,
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
    this.contactWhileAway,
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

  /// Where to reach this person while they are away. Unlike the dates,
  /// this can change after the request is approved — the number given a
  /// fortnight before departure is a hotel they have since left — so
  /// `0395` gives it its own update path rather than widening the RLS
  /// policy that rightly freezes everything else.
  final String? contactWhileAway;

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
      contactWhileAway: j['contact_while_away']?.toString(),
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
/// One line of the security log: a sign-in, a session ending, an export,
/// a sensitive read, or a refusal.
///
/// Deliberately a different thing from [AuditEntry]. That one says what
/// the data did; this one says what the people did, and neither can be
/// derived from the other.
class SecurityEvent {
  SecurityEvent({
    required this.id,
    required this.at,
    required this.actor,
    required this.kind,
    required this.outcome,
    this.target,
    this.detail,
    this.ipAddress,
    this.userAgent,
  });

  final int id;
  final DateTime at;
  final String actor;
  final String kind;
  final String outcome;
  final String? target;
  final String? detail;
  final String? ipAddress;
  final String? userAgent;

  bool get refused => outcome == 'refused';

  /// What to call it on a screen. The stored value is the enum, which is
  /// exact and not English.
  String get label => switch (kind) {
    'sign_in' => refused ? 'Sign-in refused' : 'Signed in',
    'session_ended' => 'Session ended',
    'export' => 'Exported',
    'sensitive_read' => 'Read',
    'denied' => 'Refused',
    _ => kind,
  };

  factory SecurityEvent.fromMap(Map<String, dynamic> j) => SecurityEvent(
    id: (j['id'] as num).toInt(),
    at: DateTime.parse(j['at'].toString()).toLocal(),
    actor: j['actor']?.toString() ?? 'unknown',
    kind: j['kind']?.toString() ?? '',
    outcome: j['outcome']?.toString() ?? 'ok',
    target: j['target']?.toString(),
    detail: j['detail']?.toString(),
    ipAddress: j['ip_address']?.toString(),
    userAgent: j['user_agent']?.toString(),
  );
}

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
    this.hrdfWage = 0,
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
  final double hrdfWage;
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
      hrdfWage: Fmt.toDouble(j['hrdf_wage']),
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
    this.raw = const {},
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

  /// The row as it came back.
  ///
  /// The editor needs the columns this class does not model —
  /// `hiring_manager_id`, `requirements`, `target_start_date`,
  /// `opened_date` — and adding a field for each would grow the model
  /// for one screen's benefit. Kept as the row so the editor reads what
  /// it needs and the list goes on using the named fields.
  final Map<String, dynamic> raw;

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
      raw: j,
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
    this.requisitionId,
    this.requisitionTitle,
    this.appliedAt,
    this.nric,
    this.currentEmployer,
    this.noticePeriodDays,
    this.referredBy,
    this.referrerName,
    this.hiredEmployeeId,
    this.notes,
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
  final String? requisitionId;
  final String? requisitionTitle;
  final DateTime? appliedAt;
  final String? nric;
  final String? currentEmployer;

  /// What they owe their current employer. A start date inside it is a
  /// date they cannot make, which `hire_applicant` refuses unless
  /// somebody says the notice has been waived.
  final int? noticePeriodDays;

  /// Who introduced them. A reference nothing wrote until `0381`, which
  /// made an employee referral scheme unpayable from the data.
  final String? referredBy;
  final String? referrerName;

  /// Set by `hire_applicant`, and the thing that stops the same person
  /// being typed into the employee editor from the record beside it.
  final String? hiredEmployeeId;
  final String? notes;

  bool get isHired => hiredEmployeeId != null;

  /// The earliest day they could start, given the notice they owe.
  DateTime? earliestStart(DateTime today) => noticePeriodDays == null ||
          noticePeriodDays! <= 0
      ? null
      : DateTime(today.year, today.month, today.day + noticePeriodDays!);

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
      requisitionId: j['requisition_id'] as String?,
      requisitionTitle: req is Map ? req['title'] as String? : null,
      appliedAt: Fmt.parseDate(j['applied_at']),
      nric: j['nric']?.toString(),
      currentEmployer: j['current_employer']?.toString(),
      noticePeriodDays: j['notice_period_days'] == null
          ? null
          : Fmt.toInt(j['notice_period_days']),
      referredBy: j['referred_by'] as String?,
      referrerName: j['referrer'] is Map
          ? j['referrer']['full_name']?.toString()
          : null,
      hiredEmployeeId: j['hired_employee_id'] as String?,
      notes: j['notes']?.toString(),
    );
  }
}

class Appraisal {
  Appraisal({
    required this.id,
    required this.status,
    required this.employeeId,
    this.reviewerId,
    this.cycleId,
    this.employeeName,
    this.reviewerName,
    this.cycleName,
    this.ratingScaleMax = 5,
    this.selfReviewDue,
    this.managerReviewDue,
    this.selfRating,
    this.selfComments,
    this.selfSubmittedAt,
    this.managerRating,
    this.managerComments,
    this.managerSubmittedAt,
    this.finalRating,
    this.calibrationNote,
    this.completedAt,
    this.recommendedIncrement,
    this.recommendedBonus,
    this.promotionRecommended = false,
    this.developmentPlan,
  });

  final String id;
  final String status;

  /// Who is being appraised, and who writes the manager half. Both are
  /// needed to work out which part the person reading this holds — see
  /// `features/hr/appraisal_part.dart`, and `0379` for the rule the
  /// database enforces.
  final String employeeId;
  final String? reviewerId;
  final String? cycleId;
  final String? employeeName;
  final String? reviewerName;
  final String? cycleName;

  /// The cycle's own scale. A 1-5 cycle and a 1-10 cycle coexist, and a
  /// rating outside its own scale means nothing to whoever reads it
  /// next year.
  final int ratingScaleMax;
  final DateTime? selfReviewDue;
  final DateTime? managerReviewDue;

  final double? selfRating;
  final String? selfComments;
  final DateTime? selfSubmittedAt;
  final double? managerRating;
  final String? managerComments;
  final DateTime? managerSubmittedAt;
  final double? finalRating;
  final String? calibrationNote;
  final DateTime? completedAt;

  final double? recommendedIncrement;
  final double? recommendedBonus;
  final bool promotionRecommended;
  final String? developmentPlan;

  bool get selfSubmitted => selfSubmittedAt != null;
  bool get managerSubmitted => managerSubmittedAt != null;
  bool get isComplete => completedAt != null;

  factory Appraisal.fromJson(Map<String, dynamic> j) {
    final emp = j['employees'];
    final rev = j['reviewer'];
    final cyc = j['appraisal_cycles'];
    double? num_(String key) =>
        j[key] == null ? null : Fmt.toDouble(j[key]);
    DateTime? when(Map? m, String key) {
      final raw = (m ?? j)[key];
      return raw == null ? null : DateTime.tryParse(raw.toString());
    }

    return Appraisal(
      id: j['id'] as String,
      status: j['status']?.toString() ?? 'draft',
      employeeId: j['employee_id'] as String,
      reviewerId: j['reviewer_id'] as String?,
      cycleId: j['cycle_id'] as String?,
      employeeName: emp is Map ? emp['full_name'] as String? : null,
      reviewerName: rev is Map ? rev['full_name'] as String? : null,
      cycleName: cyc is Map ? cyc['name'] as String? : null,
      ratingScaleMax:
          cyc is Map ? (cyc['rating_scale_max'] as num?)?.toInt() ?? 5 : 5,
      selfReviewDue: cyc is Map ? when(cyc, 'self_review_due') : null,
      managerReviewDue: cyc is Map ? when(cyc, 'manager_review_due') : null,
      selfRating: num_('self_rating'),
      selfComments: j['self_comments'] as String?,
      selfSubmittedAt: when(null, 'self_submitted_at'),
      managerRating: num_('manager_rating'),
      managerComments: j['manager_comments'] as String?,
      managerSubmittedAt: when(null, 'manager_submitted_at'),
      finalRating: num_('final_rating'),
      calibrationNote: j['calibration_note'] as String?,
      completedAt: when(null, 'completed_at'),
      recommendedIncrement: num_('recommended_increment_percent'),
      recommendedBonus: num_('recommended_bonus'),
      promotionRecommended: j['promotion_recommended'] == true,
      developmentPlan: j['development_plan'] as String?,
    );
  }
}

/// A round of appraisals: the period reviewed, the scale it is scored
/// out of, and the two days the halves are due.
class AppraisalCycle {
  AppraisalCycle({
    required this.id,
    required this.name,
    required this.periodStart,
    required this.periodEnd,
    required this.status,
    required this.ratingScaleMax,
    this.selfReviewDue,
    this.managerReviewDue,
    this.opened = 0,
  });

  final String id;
  final String name;
  final DateTime periodStart;
  final DateTime periodEnd;
  final String status;
  final int ratingScaleMax;
  final DateTime? selfReviewDue;
  final DateTime? managerReviewDue;

  /// How many appraisals the cycle has open, so the button can say
  /// whether opening it would do anything.
  final int opened;

  factory AppraisalCycle.fromJson(Map<String, dynamic> j) {
    DateTime? when(String key) =>
        j[key] == null ? null : DateTime.tryParse(j[key].toString());
    final counted = j['appraisals'];
    return AppraisalCycle(
      id: j['id'] as String,
      name: j['name']?.toString() ?? '',
      periodStart: when('period_start') ?? DateTime.now(),
      periodEnd: when('period_end') ?? DateTime.now(),
      status: j['status']?.toString() ?? 'draft',
      ratingScaleMax: (j['rating_scale_max'] as num?)?.toInt() ?? 5,
      selfReviewDue: when('self_review_due'),
      managerReviewDue: when('manager_review_due'),
      opened: counted is List && counted.isNotEmpty
          ? (counted.first['count'] as num?)?.toInt() ?? 0
          : 0,
    );
  }
}

/// A row of `report_appraisals_due`: who is late, on which half.
class AppraisalDue {
  AppraisalDue({
    required this.appraisalId,
    required this.cycleName,
    required this.employeeName,
    required this.waitingOn,
    required this.dueOn,
    required this.daysLate,
    this.reviewerName,
  });

  final String appraisalId;
  final String cycleName;
  final String employeeName;
  final String? reviewerName;
  final String waitingOn;
  final DateTime dueOn;
  final int daysLate;

  factory AppraisalDue.fromJson(Map<String, dynamic> j) => AppraisalDue(
        appraisalId: j['appraisal_id'] as String,
        cycleName: j['cycle_name']?.toString() ?? '',
        employeeName: j['employee_name']?.toString() ?? '',
        reviewerName: j['reviewer_name'] as String?,
        waitingOn: j['waiting_on']?.toString() ?? '',
        dueOn: DateTime.parse(j['due_on'].toString()),
        daysLate: (j['days_late'] as num?)?.toInt() ?? 0,
      );
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


/// The short lists `Repo.createQuickRow` may add a row to.
///
/// An enum rather than a table name, so a typo is a compile error and
/// not a 404 at the moment somebody is mid-invoice. Every one of these
/// tables requires exactly `org_id`, `code` and `name` — `pipelines`
/// requires no code — and nothing else, which is what makes one writer
/// honest for all of them.
enum QuickAddList {
  project,
  department,
  priceLevel,
  leaveType,
  claimType,
  ticketCategory,
  outlet,
  pipeline,
}

const quickAddTables = <QuickAddList, String>{
  QuickAddList.project: 'projects',
  QuickAddList.department: 'departments',
  QuickAddList.priceLevel: 'price_levels',
  QuickAddList.leaveType: 'leave_types',
  QuickAddList.claimType: 'claim_types',
  QuickAddList.ticketCategory: 'ticket_categories',
  QuickAddList.outlet: 'pos_outlets',
  QuickAddList.pipeline: 'pipelines',
};

/// Which of them have a code column. `pipelines` does not.
const quickAddHasCode = <QuickAddList, bool>{
  QuickAddList.project: true,
  QuickAddList.department: true,
  QuickAddList.priceLevel: true,
  QuickAddList.leaveType: true,
  QuickAddList.claimType: true,
  QuickAddList.ticketCategory: true,
  QuickAddList.outlet: true,
  QuickAddList.pipeline: false,
};

/// One of a company's own payment methods.
///
/// `0635`. Not to be confused with `ref_payment_modes`, which holds
/// LHDN's eight codes and is platform-wide. This is "Maybank cheque",
/// "Stripe", "Cash at the counter" — several of which report as the
/// same LHDN code, and which differ in the two things LHDN does not
/// ask about and the ledger does: where the money lands, and what the
/// provider keeps.
class PaymentMethod {
  PaymentMethod({
    required this.id,
    required this.name,
    this.paymentModeCode,
    this.bankAccountId,
    this.chargeAccountId,
    this.chargePercent = 0,
    this.chargeFixed = 0,
    this.isDefault = false,
    this.isActive = true,
    this.sortOrder = 0,
    this.notes,
  });

  final String id;
  final String name;

  /// The `ref_payment_modes` code an e-Invoice reports this as. Null
  /// for a company not yet on e-Invoice, which has no reason to be
  /// asked.
  final String? paymentModeCode;

  final String? bankAccountId;

  /// Where this method's bank charge is debited. Null is not a gap to
  /// be filled: it means "use the company's", and the database
  /// resolves it to the default method's account and then to 6300.
  final String? chargeAccountId;

  final double chargePercent;
  final double chargeFixed;
  final bool isDefault;
  final bool isActive;
  final int sortOrder;
  final String? notes;

  factory PaymentMethod.fromJson(Map<String, dynamic> j) => PaymentMethod(
    id: j['id'] as String,
    name: j['name']?.toString() ?? '',
    paymentModeCode: j['payment_mode_code'] as String?,
    bankAccountId: j['bank_account_id'] as String?,
    chargeAccountId: j['charge_account_id'] as String?,
    chargePercent: Fmt.toDouble(j['charge_percent']),
    chargeFixed: Fmt.toDouble(j['charge_fixed']),
    isDefault: j['is_default'] == true,
    isActive: j['is_active'] != false,
    sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
    notes: j['notes'] as String?,
  );
}

/// A company's own layout for a P&L or a Balance Sheet.
///
/// `0637`. Which sections a report has, in what order, and what each
/// one selects — data rather than a hardcoded opinion, because
/// "Revenue / Cost of Sales / Gross profit / Expenses / Net profit" is
/// one reasonable view of a P&L and wrong for plenty of real sets of
/// accounts.
class ReportLayout {
  ReportLayout({
    required this.id,
    required this.kind,
    required this.name,
    this.isActive = false,
    this.isBuiltin = false,
  });

  final String id;

  /// `profit_loss` or `balance_sheet`.
  final String kind;
  final String name;

  /// The one this company's report uses. At most one per kind, which
  /// the database enforces with a partial unique index rather than
  /// trusting whoever wrote last.
  final bool isActive;

  /// Seeded from the standard layout. Editable like any other — the
  /// flag is so a screen can offer to start again from it.
  final bool isBuiltin;

  factory ReportLayout.fromJson(Map<String, dynamic> j) => ReportLayout(
    id: j['id'] as String,
    kind: j['kind']?.toString() ?? 'profit_loss',
    name: j['name']?.toString() ?? '',
    isActive: j['is_active'] == true,
    isBuiltin: j['is_builtin'] == true,
  );
}

/// One row of a layout: a section, a computed figure, or a heading.
class LayoutRow {
  LayoutRow({
    required this.rowKey,
    required this.kind,
    required this.label,
    this.depth = 0,
    this.emphasise = false,
    this.showAccounts = true,
    this.accountTypes = const [],
    this.accountSubtypes = const [],
    this.accountIds = const [],
    this.formula = const [],
  });

  /// What a formula refers to. Stable across a rename of the label,
  /// which is the whole reason it is separate from one.
  final String rowKey;

  /// `section`, `formula` or `heading`.
  final String kind;
  final String label;
  final int depth;
  final bool emphasise;

  /// False for an accountant's one-line block with the detail in a
  /// note. The section still has a total; it just does not list what
  /// is under it.
  final bool showAccounts;

  final List<String> accountTypes;
  final List<String> accountSubtypes;
  final List<String> accountIds;

  /// Signed references to rows ABOVE this one, as
  /// `[{'row': key, 'sign': 1 or -1}]`.
  ///
  /// Not an expression. There is no parser and no precedence, because
  /// a precedence bug in a figure somebody signs is the worst kind to
  /// find late — and addition and subtraction of rows already computed
  /// is what every real layout actually needs.
  final List<Map<String, dynamic>> formula;

  static List<String> _strings(dynamic v) => [
    for (final x in (v as List? ?? const [])) x.toString(),
  ];

  factory LayoutRow.fromJson(Map<String, dynamic> j) => LayoutRow(
    rowKey: j['row_key']?.toString() ?? '',
    kind: j['kind']?.toString() ?? 'section',
    label: j['label']?.toString() ?? '',
    depth: (j['depth'] as num?)?.toInt() ?? 0,
    emphasise: j['emphasise'] == true,
    showAccounts: j['show_accounts'] != false,
    accountTypes: _strings(j['account_types']),
    accountSubtypes: _strings(j['account_subtypes']),
    accountIds: _strings(j['account_ids']),
    formula: [
      for (final f in (j['formula'] as List? ?? const []))
        Map<String, dynamic>.from(f as Map),
    ],
  );

  /// What `save_layout_rows` expects.
  ///
  /// Empty selectors are omitted rather than sent as `[]`: the
  /// database's shape constraint reads an empty array as "a section
  /// that selects nothing", which it refuses, and a builder that sent
  /// one would be refused for a reason nobody typed.
  Map<String, dynamic> toJson() => {
    'row_key': rowKey,
    'kind': kind,
    'label': label,
    'depth': depth,
    'emphasise': emphasise,
    'show_accounts': showAccounts,
    if (accountTypes.isNotEmpty) 'account_types': accountTypes,
    if (accountSubtypes.isNotEmpty) 'account_subtypes': accountSubtypes,
    if (accountIds.isNotEmpty) 'account_ids': accountIds,
    if (kind == 'formula') 'formula': formula,
  };

  LayoutRow copyWith({
    String? rowKey,
    String? kind,
    String? label,
    int? depth,
    bool? emphasise,
    bool? showAccounts,
    List<String>? accountTypes,
    List<String>? accountSubtypes,
    List<String>? accountIds,
    List<Map<String, dynamic>>? formula,
  }) => LayoutRow(
    rowKey: rowKey ?? this.rowKey,
    kind: kind ?? this.kind,
    label: label ?? this.label,
    depth: depth ?? this.depth,
    emphasise: emphasise ?? this.emphasise,
    showAccounts: showAccounts ?? this.showAccounts,
    accountTypes: accountTypes ?? this.accountTypes,
    accountSubtypes: accountSubtypes ?? this.accountSubtypes,
    accountIds: accountIds ?? this.accountIds,
    formula: formula ?? this.formula,
  );
}
