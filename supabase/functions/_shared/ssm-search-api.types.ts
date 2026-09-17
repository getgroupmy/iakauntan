// Generated from SSM SEARCH API OpenAPI 3.0.3, version 1.0.1 (https://cidp.ssmsearch.com/documentation/json), 16 Sep 2026.
// Every scalar in the upstream spec is a string; no field is declared required, so all are optional here.
// Servers: https://cidp.ssmsearch.com/ (dev, free) · https://apigw.ssmsearch.com/gateway/CIDP/V1.1/ (prod, charged)
// Headers: x-Gateway-APIKey, x-Gateway-APISecret (both required), x-Client-Ref-No (optional).

export const SSM_SEARCH_API_VERSION = "1.0.1" as const;
export const SSM_DEV_BASE_URL = "https://cidp.ssmsearch.com/" as const;
export const SSM_PROD_BASE_URL = "https://apigw.ssmsearch.com/gateway/CIDP/V1.1/" as const;

/** Gateway auth/quota error body (observed live). */
export interface SsmGatewayError { error_code: number; error: string; client_ref_no: string; }
/** Framework routing error body (observed live). */
export interface SsmRouteError { message: string; error: string; statusCode: number; }

/** entityType values documented for the search request. */
export type SsmEntityType = "company" | "business" | "audit_firm" | "limited_liability_partnerships" | (string & {});

// ---- request bodies ------------------------------------------------------
/** POST /get-search-entity — Search Entity */
export interface GetSearchEntityRequest {
  /** SSM Registration No (Old or New). Available sample(s) for Development Key: 1940010XXXXX 1940123XXXXX 19401453XXXXX 19401789XXXXX 19401955XXXXX 19401111XXXXX 19401223XXXXX 19401789XXXX 19401744XXXX 19401633XXXX SP0503XXX SP0503XXX-L 00306XXXX 00306XXXX-V 001122XXX-A 001223XXX-F 001987XXX-J 001987XXX-T 002456XXX-P 004567XXX-N 004567XXX-P 004567XXX-Z 004881XXX-N 19931215XXXX 19130619XXXX 19510628XXXX 19900808XXXX 19900810XXXX 19921015XXXX 20210929XXXX 20240808XXXX 20240812XXXX 20240991XXXX 001122XXX-W 1559XXX-U 001987XXX-T 2021-D 002456XXX-V 004512XXX-K 004567XXX-K 004567XXX-M 004567XXX-U 004567XXX-X 001122XXX 2021 */
  regNo?: string;
  /** Entity Name. Available sample(s) for Development Key: BOSS MAJU TERBAIK BANGSA EMPIRE PEMBUATAN */
  name?: string;
  /** Pagination Page Number. Available sample(s) for Development Key: 1 2 3 */
  page?: string;
  /** SSM Entity Type.Available sample(s) for Development Key: company business audit_firm limited_liability_partnerships */
  entityType?: string;
}

/** POST /get-bizprofile-document — Business Profile */
export interface GetBizprofileDocumentRequest {
  /** SSM Registration No (Old or New). Available sample(s) for Development Key: 1940010XXXXX 1940123XXXXX 19401453XXXXX 19401789XXXXX 19401955XXXXX 19401111XXXXX 19401223XXXXX 19401789XXXX 19401744XXXX 19401633XXXX SP0503XXX-L SP0503XXX 00306XXXX-V 00306XXXX */
  regNo?: string;
}

/** POST /get-company-profile-document — Company Profile */
export interface GetCompanyProfileDocumentRequest {
  /** SSM Registration No (Old or New). Available sample(s) for Development Key: 19931215XXXX 19130619XXXX 19510628XXXX 19900808XXXX 19900810XXXX 19921015XXXX 20210929XXXX 20240808XXXX 20240812XXXX 20240991XXXX 001122XXX 001122XXX-W 2021 2021-D */
  regNo?: string;
}

/** POST /get-company-roc-business-officers — Particulars of Directors/Officers */
export interface GetCompanyRocBusinessOfficersRequest {
  /** SSM Registration No (Old or New). Available sample(s) for Development Key: 200701042XXX */
  regNo?: string;
}

/** POST /get-company-sharecapital-particular — Particular of Share Capital */
export interface GetCompanySharecapitalParticularRequest {
  /** SSM Registration No (Old or New). Available sample(s) for Development Key: 200701042XXX */
  regNo?: string;
}

/** POST /get-company-shareholder-particular — Particular of Shareholders */
export interface GetCompanyShareholderParticularRequest {
  /** SSM Registration No (Old or New). Available sample(s) for Development Key: 200701042XXX */
  regNo?: string;
}

/** POST /get-company-roc-changes-registered-address — Particulars of Registered Address */
export interface GetCompanyRocChangesRegisteredAddressRequest {
  /** SSM Registration No (Old or New). Available sample(s) for Development Key: 200701042XXX */
  regNo?: string;
}

/** POST /get-company-cosec-particular — Particular of Company Secretary */
export interface GetCompanyCosecParticularRequest {
  /** SSM Registration No (Old or New). Available sample(s) for Development Key: 200701042XXX */
  regNo?: string;
}

/** POST /get-company-charges — Company Charges */
export interface GetCompanyChargesRequest {
  /** SSM Registration No (Old or New). Available sample(s) for Development Key: 200701042XXX */
  regNo?: string;
}

/** POST /get-auditfirm-particular — Audit Firm Profile */
export interface GetAuditfirmParticularRequest {
  /** SSM Registration No (Old or New). Available sample(s) for Development Key: AF03XX */
  adtFirmNo?: string;
}

/** POST /get-llp-current-profile — LLP Current Profile */
export interface GetLlpCurrentProfileRequest {
  /** SSM Registration No (Old). Available sample(s) for Development Key: LLP00XXXXX-LGN */
  entityNoOldFormat?: string;
}

/** POST /get-image-view — Image View */
export interface GetImageViewRequest {
  /** SSM Registration No (Old or New). Available sample(s) for Development Key: 200701022XXX */
  regNo?: string;
}

/** POST /get-image — Image */
export interface GetImageRequest {
  /** SSM Registration No (Old or New). Available sample(s) for Development Key: 200701022XXX */
  regNo?: string;
  /** Version ID for selected document. Available sample(s) for Development Key: 2026737 */
  verId?: string;
}

// ---- response schemas (components.schemas) -------------------------------
export interface getSearchEntity {
  clientRefNo?: string;
  requestRefNo?: string;
  errorMsg?: string;
  infoId?: string;
  successCode?: string;
  searchEntity?: {
    currentPage?: string;
    nextPage?: string;
    data?: Array<{
      companyName?: string;
      companyNo?: string;
      oldCompanyNo?: string;
      entityType?: string;
    }>;
  };
}

export interface getBizProfile {
  clientRefNo?: string;
  requestRefNo?: string;
  errorMsg?: string;
  infoId?: string;
  successCode?: string;
  robBusinessInfo?: {
    errorMsg?: string;
    infoId?: string;
    successCode?: string;
    ammendmentDate?: string;
    checkDigit?: string;
    description?: string;
    endBusinessDate?: string;
    llpName?: string;
    llpNo?: string;
    llpconvertDate?: string;
    mainAddress1?: string;
    mainAddress2?: string;
    mainAddress3?: string;
    mainPostcode?: string;
    mainState?: string;
    mainTown?: string;
    nameType?: string;
    ownerCount?: string;
    postAddress1?: string;
    postAddress2?: string;
    postAddress3?: string;
    postPostcode?: string;
    postState?: string;
    postTown?: string;
    referenceNo?: string;
    registrationDate?: string;
    registrationName?: string;
    registrationNo?: string;
    revokeReasonType?: string;
    startBusinessDate?: string;
    status?: string;
    terminationDate?: string;
  };
  robOwnershipListInfo?: {
    errorMsg?: string;
    infoId?: string;
    successCode?: string;
    robOwnerShipInfos?: {
      robOwnerShipInfos?: Array<{
        address1?: string;
        address2?: string;
        address3?: string;
        ammendmentType?: string;
        checkDigit?: string;
        color?: string;
        createDate?: string;
        dob?: string;
        entryDate?: string;
        gender?: string;
        idCardNumber?: string;
        idCardType?: string;
        nationality?: string;
        newIcNo?: string;
        othColor?: string;
        othRace?: string;
        ownerName?: string;
        ownershipLink?: string;
        postcode?: string;
        race?: string;
        registrationName?: string;
        registrationNo?: string;
        state?: string;
        status?: string;
        town?: string;
        updateDate?: string;
      }>;
    };
  };
  robBusinessCodeListInfo?: {
    errorMsg?: string;
    infoId?: string;
    successCode?: string;
    robBusinessCodeInfos?: {
      robBusinessCodeInfos?: Array<{
        businessCode?: string;
        checkDigit?: string;
        description?: string;
        descriptionEnglish?: string;
        registrationName?: string;
        registrationNo?: string;
      }>;
    };
  };
  robBranchListInfo?: {
    errorMsg?: string;
    infoId?: string;
    successCode?: string;
    robBranchInfos?: {
      robBranchInfos?: Array<{
        address1?: string;
        address2?: string;
        address3?: string;
        checkDigit?: string;
        postcode?: string;
        registrationName?: string;
        registrationNo?: string;
        state?: string;
        status?: string;
        town?: string;
      }>;
    };
  };
}

export interface getCompProfile {
  clientRefNo?: string;
  requestRefNo?: string;
  errorMsg?: string;
  infoId?: string;
  successCode?: string;
  rocBalanceSheetInfo?: {
    accrualAccType?: string;
    auditFirmAddress1?: string;
    auditFirmAddress2?: string;
    auditFirmAddress3?: string;
    auditFirmName?: string;
    auditFirmNo?: string;
    auditFirmPostcode?: string;
    auditFirmState?: string;
    auditFirmTown?: string;
    auditfirmFlag?: string;
    branchkeycode?: string;
    companyNo?: string;
    contigentLiability?: string;
    currentAsset?: string;
    dateOfTabling?: string;
    financialReportType?: string;
    financialYearEndDate?: string;
    fixedAsset?: string;
    fundAndReserve?: string;
    headOfficeAccount?: string;
    inappropriateProfit?: string;
    liability?: string;
    longTermLiability?: string;
    minorityInterest?: string;
    nonCurrAsset?: string;
    nonCurrentLiability?: string;
    otherAsset?: string;
    paidUpCapital?: string;
    reserves?: string;
    shareAppAccount?: string;
    sharePremium?: string;
    totalInvestment?: string;
  };
  rocBalanceSheetListInfo?: {
    errorMsg?: string;
    infoId?: string;
    successCode?: string;
    rocBalanceSheetInfos?: {
      rocBalanceSheetInfos?: Array<{
        errorMsg?: string;
        infoId?: string;
        successCode?: string;
        accrualAccType?: string;
        auditFirmAddress1?: string;
        auditFirmAddress2?: string;
        auditFirmAddress3?: string;
        auditFirmName?: string;
        auditFirmNo?: string;
        auditFirmPostcode?: string;
        auditFirmState?: string;
        auditFirmTown?: string;
        auditfirmFlag?: string;
        branchkeycode?: string;
        companyNo?: string;
        contigentLiability?: string;
        currentAsset?: string;
        dateOfTabling?: string;
        financialReportType?: string;
        financialYearEndDate?: string;
        fixedAsset?: string;
        fundAndReserve?: string;
        fundReserve?: string;
        headOfficeAccount?: string;
        inappropriateProfit?: string;
        liability?: string;
        longTermLiability?: string;
        minorityInterest?: string;
        nonCurrAsset?: string;
        nonCurrentLiability?: string;
        otherAsset?: string;
        paidUpCapital?: string;
        reserves?: string;
        shareAppAccount?: string;
        sharePremium?: string;
        totalInvestment?: string;
      }>;
    };
  };
  rocBusinessAddressInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    address1?: string;
    address2?: string;
    address3?: string;
    companyNo?: string;
    postcode?: string;
    state?: string;
    town?: string;
  };
  rocBusinessCodeInfo?: {
    businessCode?: string;
    companyNo?: string;
    priority?: string;
  };
  rocBusinessCodeListInfo?: {
    errorMsg?: string;
    infoId?: string;
    successCode?: string;
    rocBusinessCodeInfos?: {
      rocBusinessCodeInfos?: Array<{
        businessCode?: string;
        companyNo?: string;
        priority?: string;
      }>;
    };
  };
  rocChargesInfo?: {
    ammendNo?: string;
    chargeAmount?: string;
    chargeCreateDate?: string;
    chargeCreateDate1?: string;
    chargeMortgageType?: string;
    chargeNo?: string;
    chargeStatus?: string;
    chargeeId?: string;
    chargeeName?: string;
    companyNo?: string;
    form40Date?: string;
    totalOfCharge?: string;
  };
  rocChargesListInfo?: {
    errorMsg?: string;
    infoId?: string;
    successCode?: string;
    rocChargesInfos?: {
      rocChargesInfos?: Array<{
        ammendNo?: string;
        chargeAmount?: string;
        chargeCreateDate?: string;
        chargeCreateDate1?: string;
        chargeMortgageType?: string;
        chargeNo?: string;
        chargeStatus?: string;
        chargeeId?: string;
        chargeeName?: string;
        companyNo?: string;
        form40Date?: string;
        totalOfCharge?: string;
      }>;
    };
  };
  rocCompanyInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    balaceSheetInfo?: string;
    balaceSheetInfoDesc?: string;
    businessDescription?: string;
    checkDigit?: string;
    companyCountry?: string;
    companyName?: string;
    companyNo?: string;
    companyOldName?: string;
    companyStatus?: string;
    companyType?: string;
    currency?: string;
    dateOfChange?: string;
    incomeStatInfo?: string;
    incomeStatInfoDesc?: string;
    incorpDate?: string;
    infoColon?: string;
    latestDocUpdateDate?: string;
    llpInfo?: string;
    llpInfoDesc?: string;
    llpName?: string;
    llpNo?: string;
    llpconvertDate?: string;
    localforeignCompany?: string;
    naBal?: string;
    naProf?: string;
    registrationDate?: string;
    statusOfCompany?: string;
    wupType?: string;
  };
  rocCompanyOfficerInfo?: {
    address1?: string;
    address2?: string;
    address3?: string;
    appointmentDate?: string;
    companyNo?: string;
    designationCode?: string;
    dob?: string;
    idNo?: string;
    idType?: string;
    name?: string;
    officerInfo?: string;
    postcode?: string;
    resignDate?: string;
    startDate?: string;
    state?: string;
    town?: string;
  };
  rocCompanyOfficerListInfo?: {
    errorMsg?: string;
    infoId?: string;
    successCode?: string;
    rocCompanyOfficerInfos?: {
      rocCompanyOfficerInfos?: Array<{
        address1?: string;
        address2?: string;
        address3?: string;
        appointmentDate?: string;
        companyNo?: string;
        designationCode?: string;
        dob?: string;
        idNo?: string;
        idType?: string;
        name?: string;
        officerInfo?: string;
        postcode?: string;
        startDate?: string;
        state?: string;
        town?: string;
      }>;
    };
  };
  rocDocumentLodgeInfo?: {
    companyNo?: string;
    documentDate?: string;
    formTrx?: string;
    updateDate?: string;
  };
  rocDocumentLodgeListInfo?: {
    errorMsg?: string;
    infoId?: string;
    successCode?: string;
    rocDocumentLodgeInfos?: {
      rocDocumentLodgeInfos?: Array<{
        companyNo?: string;
        documentDate?: string;
        formTrx?: string;
      }>;
    };
  };
  rocProfitLossInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    accrualAccount?: string;
    companyNo?: string;
    extraOrdinaryItem?: string;
    financialReportType?: string;
    financialYearEndDate?: string;
    grossDividendRate?: string;
    inappropriateProfitBf?: string;
    inappropriateProfitCf?: string;
    minorityInterest?: string;
    netDividend?: string;
    others?: string;
    priorAdjustment?: string;
    profitAfterTax?: string;
    profitBeforeTax?: string;
    profitShareholder?: string;
    revenue?: string;
    surplusAfterTax?: string;
    surplusBeforeTax?: string;
    surplusDeficitAfterTax?: string;
    surplusDeficitBeforeTax?: string;
    totalExpenditure?: string;
    totalIncome?: string;
    totalRevenue?: string;
    transferred?: string;
    turnover?: string;
  };
  rocProfitLossListInfo?: {
    errorMsg?: string;
    infoId?: string;
    successCode?: string;
    rocProfitLossInfos?: {
      rocProfitLossInfos?: Array<{
        errorMsg?: string;
        infoId?: string;
        successCode?: string;
        accrualAccount?: string;
        companyNo?: string;
        extraOrdinaryItem?: string;
        financialReportType?: string;
        financialYearEndDate?: string;
        grossDividendRate?: string;
        inappropriateProfitBf?: string;
        inappropriateProfitCf?: string;
        minorityInterest?: string;
        netDividend?: string;
        others?: string;
        priorAdjustment?: string;
        profitAfterTax?: string;
        profitBeforeTax?: string;
        profitShareholder?: string;
        revenue?: string;
        surplusAfterTax?: string;
        surplusBeforeTax?: string;
        surplusDeficitAfterTax?: string;
        surplusDeficitBeforeTax?: string;
        totalExpenditure?: string;
        totalIncome?: string;
        totalRevenue?: string;
        transferred?: string;
        turnover?: string;
      }>;
    };
  };
  rocRegAddressInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    address1?: string;
    address2?: string;
    address3?: string;
    companyNo?: string;
    postcode?: string;
    state?: string;
    town?: string;
  };
  rocShareCapitalInfo?: {
    errorMsg?: string;
    infoId?: string;
    successCode?: string;
    authorisedCapital?: string;
    companyNo?: string;
    currency?: string;
    currenyNominal?: string;
    ordAIssuedCash?: string;
    ordAIssuedNominal?: string;
    ordAIssuedNonCash?: string;
    ordANominalValue?: string;
    ordANumberOfShares?: string;
    ordAmountAValue?: string;
    ordAmountBValue?: string;
    ordAmountValue?: string;
    ordBIssuedCash?: string;
    ordBIssuedNominal?: string;
    ordBIssuedNonCash?: string;
    ordBNominalValue?: string;
    ordBNumberOfShares?: string;
    ordIssuedCash?: string;
    ordIssuedNominal?: string;
    ordIssuedNonCash?: string;
    ordNominalValue?: string;
    ordNumberOfShares?: string;
    othAIssuedCash?: string;
    othAIssuedNonCash?: string;
    othAmountValue?: string;
    othBIssuedCash?: string;
    othBIssuedNonCash?: string;
    othIssuedCash?: string;
    othIssuedNominal?: string;
    othIssuedNonCash?: string;
    othNominalValue?: string;
    othNumberOfShares?: string;
    prefAIssuedCash?: string;
    prefAIssuedNominal?: string;
    prefAIssuedNonCash?: string;
    prefANominalValue?: string;
    prefANumberOfShares?: string;
    prefAmountAValue?: string;
    prefAmountBValue?: string;
    prefAmountValue?: string;
    prefBIssuedCash?: string;
    prefBIssuedNominal?: string;
    prefBIssuedNonCash?: string;
    prefBNominalValue?: string;
    prefBNumberOfShares?: string;
    prefIssuedCash?: string;
    prefIssuedNominal?: string;
    prefIssuedNonCash?: string;
    prefNominalValue?: string;
    prefNumberOfShares?: string;
    totalIssued?: string;
  };
  rocShareholderInfo?: {
    companyNo?: string;
    dob?: string;
    idNo?: string;
    idType?: string;
    name?: string;
    share?: string;
    shareVol?: string;
  };
  rocShareholderListInfo?: {
    errorMsg?: string;
    infoId?: string;
    successCode?: string;
    rocShareholderInfos?: {
      rocShareholderInfos?: Array<{
        companyNo?: string;
        dob?: string;
        idNo?: string;
        idType?: string;
        name?: string;
        share?: string;
        shareVol?: string;
      }>;
    };
  };
}

export interface getDetailsOfShareCapital {
  clientRefNo?: string;
  requestRefNo?: string;
  errorMsg?: string;
  infoId?: string;
  successCode?: string;
  allotmentOfShare?: {
    allotmentShareList?: {
      allotmentShareList?: Array<{
        dtAllot?: string;
        dtFrom?: Record<string, unknown>;
        dtTo?: Record<string, unknown>;
        issuedShare?: string;
        particularAlloteesList?: {
          particularAlloteesList?: Array<{
            address?: {
              address1?: string;
              address2?: string;
              address3?: string;
              postcode?: string;
              state?: string;
              town?: string;
            };
            alloteeId?: string;
            alloteeName?: string;
            noOfShares?: string;
          }>;
        };
        pricePerShare?: string;
        shareDtl?: string;
        shareType?: string;
        totalIssuedShare?: string;
      }>;
    };
  };
  rocBusinessAddressInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    address1?: string;
    address2?: string;
    address3?: string;
    companyNo?: string;
    postcode?: string;
    state?: string;
    town?: string;
  };
  rocCompanyInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    balaceSheetInfo?: string;
    balaceSheetInfoDesc?: string;
    businessDescription?: string;
    checkDigit?: string;
    companyCountry?: string;
    companyName?: string;
    companyNo?: string;
    companyOldName?: string;
    companyStatus?: string;
    companyType?: string;
    currency?: string;
    incomeStatInfo?: string;
    incomeStatInfoDesc?: string;
    incorpDate?: string;
    infoColon?: string;
    latestDocUpdateDate?: string;
    llpInfo?: string;
    llpInfoDesc?: string;
    llpName?: string;
    llpNo?: string;
    localforeignCompany?: string;
    naBal?: string;
    naProf?: string;
    registrationDate?: string;
    statusOfCompany?: string;
    wupType?: string;
  };
  rocRegAddressInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    address1?: string;
    address2?: string;
    address3?: string;
    companyNo?: string;
    postcode?: string;
    state?: string;
    town?: string;
  };
  shareCapitalSummary?: {
    ordinaryACash?: string;
    ordinaryAIssued?: string;
    ordinaryAOtherwise?: string;
    ordinaryBCash?: string;
    ordinaryBIssued?: string;
    ordinaryBOtherwise?: string;
    ordinaryCash?: string;
    ordinaryIssued?: string;
    ordinaryOtherwise?: string;
    othersCash?: string;
    othersIssued?: string;
    othersOtherwise?: string;
    preferenceACash?: string;
    preferenceAIssued?: string;
    preferenceAOtherwise?: string;
    preferenceBCash?: string;
    preferenceBIssued?: string;
    preferenceBOtherwise?: string;
    preferenceCash?: string;
    preferenceIssued?: string;
    preferenceOtherwise?: string;
    totalIssued?: string;
  };
}

export interface getDetailsOfShareholders {
  clientRefNo?: string;
  requestRefNo?: string;
  errorMsg?: string;
  infoId?: string;
  successCode?: string;
  currShareholderList?: {
    shareholders?: {
      shareholders?: Array<{
        address?: {
          address1?: string;
          address2?: string;
          address3?: string;
          postcode?: string;
          state?: string;
          town?: string;
        };
        idNo?: string;
        idType?: string;
        name?: string;
        totalShare?: string;
      }>;
    };
  };
  rocBusinessAddressInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    address1?: string;
    address2?: string;
    address3?: string;
    companyNo?: string;
    postcode?: string;
    state?: string;
    town?: string;
  };
  rocCompanyInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    balaceSheetInfo?: string;
    balaceSheetInfoDesc?: string;
    businessDescription?: string;
    checkDigit?: string;
    companyCountry?: string;
    companyName?: string;
    companyNo?: string;
    companyOldName?: string;
    companyStatus?: string;
    companyType?: string;
    currency?: string;
    incomeStatInfo?: string;
    incomeStatInfoDesc?: string;
    incorpDate?: string;
    infoColon?: string;
    latestDocUpdateDate?: string;
    llpInfo?: string;
    llpInfoDesc?: string;
    llpName?: string;
    llpNo?: string;
    localforeignCompany?: string;
    naBal?: string;
    naProf?: string;
    statusOfCompany?: string;
    wupType?: string;
  };
  rocRegAddressInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    address1?: string;
    address2?: string;
    address3?: string;
    companyNo?: string;
    postcode?: string;
    state?: string;
    town?: string;
  };
  rocShareholderChgListInfo?: {
    rocShareholderCghInfos?: {
      rocShareholderCghInfos?: Array<{
        address?: {
          address1?: string;
          address2?: string;
          address3?: string;
          postcode?: string;
          state?: string;
          town?: string;
        };
        dtTransfer?: string;
        idType?: string;
        shareIn?: string;
        shareOut?: string;
        shareholderId?: string;
        shareholderName?: string;
        totalShare?: string;
      }>;
    };
  };
}

export interface getInfoCharges {
  clientRefNo?: string;
  requestRefNo?: string;
  errorMsg?: string;
  infoId?: string;
  successCode?: string;
  SSMRegistrationChargesInfos?: {
    SSMRegistrationChargesInfos?: Array<{
      ammendNo?: string;
      chargeAmount?: string;
      chargeCreateDate?: string;
      chargeCreateDate1?: string;
      chargeMortgageType?: string;
      chargeNo?: string;
      chargeStatus?: string;
      chargeeId?: string;
      chargeeName?: string;
      companyNo?: string;
      form40Date?: string;
      totalOfCharge?: string;
      chargeType?: string;
      chargeeAddr1?: string;
      chargeeAddr2?: string;
      chargeeAddr3?: string;
      checkDigit?: string;
      companyName?: string;
      currency?: string;
      propertiesAffected?: string;
      releaseDate?: string;
      typeOfInstrument?: string;
    }>;
  };
}

export interface getParticularsOfAdtFirm {
  clientRefNo?: string;
  requestRefNo?: string;
  errorMsg?: string;
  successCode?: string;
  adtFirmProf?: {
    adtFirmName?: string;
    adtFirmNo?: string;
    commenceDt?: string;
    faxNo?: string;
    prinAddr1?: string;
    prinAddr2?: string;
    prinAddr3?: string;
    prinCountry?: string;
    prinPostcode?: string;
    prinState?: string;
    prinTown?: string;
    regDt?: string;
    telNo?: string;
  };
  adtPartners?: {
    adtPartners?: Array<{
      adtName?: string;
      adtNewIcNo?: string;
      adtOldIcNo?: string;
      adtPassportNo?: string;
      entryDt?: string;
      licenceNo?: string;
      partnerStatus?: string;
      resAddr1?: string;
      resAddr2?: string;
      resAddr3?: string;
      resCountry?: string;
      resPostcode?: string;
      resState?: string;
      resTown?: string;
    }>;
  };
  branchOffices?: {
    branchOffices?: Array<{
      branchAddr1?: string;
      branchAddr2?: string;
      branchAddr3?: string;
      branchCountry?: string;
      branchPostcode?: string;
      branchState?: string;
      branchTelNo?: string;
      branchTown?: string;
    }>;
  };
}

export interface getParticularsOfCosec {
  clientRefNo?: string;
  requestRefNo?: string;
  errorMsg?: string;
  infoId?: string;
  successCode?: string;
  compInfo?: {
    busAddr1?: string;
    busAddr2?: string;
    busAddr3?: string;
    busCountry?: string;
    busNature?: string;
    busPostcode?: string;
    busState?: string;
    busTown?: string;
    compName?: string;
    compCategory?: string;
    compNo?: string;
    compOldName?: string;
    compStatus?: string;
    compType?: string;
    incorpDt?: string;
    origin?: string;
    regAddr1?: string;
    regAddr2?: string;
    regAddr3?: string;
    regCountry?: string;
    regPostcode?: string;
    regState?: string;
    regTown?: string;
    checkDigit?: string;
    currency?: string;
    compCountry?: string;
    lastUpdateDt?: string;
    llpName?: string;
    llpNo?: string;
    wupType?: string;
  };
  cosecs?: {
    cosecs?: Array<{
      apptDt?: string;
      cosecName?: string;
      gender?: string;
      idNo?: string;
      idType?: string;
      lsExpiryDt?: string;
      memberNo?: string;
      nationality?: string;
      profBodyCode?: string;
      race?: string;
      recordStatus?: string;
      resAddr1?: string;
      resAddr2?: string;
      resAddr3?: string;
      resCountry?: string;
      resPostcode?: string;
      resState?: string;
      resTown?: string;
    }>;
  };
}

export interface getRocBusinessOfficers {
  clientRefNo?: string;
  requestRefNo?: string;
  errorMsg?: string;
  infoId?: string;
  successCode?: string;
  rocBusinessAddressInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    address1?: string;
    address2?: string;
    address3?: string;
    companyNo?: string;
    postcode?: string;
    state?: string;
    town?: string;
  };
  rocChangeCompanyOfficerListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocCompanyOfficerChgsInfos?: {
      rocCompanyOfficerChgsInfos?: Array<{
        address1?: string;
        address2?: string;
        address3?: string;
        appointmentDate?: string;
        companyNo?: string;
        designationCode?: string;
        dob?: string;
        idNo?: string;
        idType?: string;
        name?: string;
        officerInfo?: string;
        postcode?: string;
        removalDate?: string;
        resignDate?: string;
        startDate?: string;
        state?: string;
        town?: string;
      }>;
    };
  };
  rocCompanyInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    balaceSheetInfo?: string;
    balaceSheetInfoDesc?: string;
    businessDescription?: string;
    checkDigit?: string;
    companyCountry?: string;
    companyName?: string;
    companyNo?: string;
    companyOldName?: string;
    companyStatus?: string;
    companyType?: string;
    currency?: string;
    dateOfChange?: string;
    incomeStatInfo?: string;
    incomeStatInfoDesc?: string;
    incorpDate?: string;
    infoColon?: string;
    latestDocUpdateDate?: string;
    llpInfo?: string;
    llpInfoDesc?: string;
    llpName?: string;
    llpNo?: string;
    llpconvertDate?: string;
    localforeignCompany?: string;
    naBal?: string;
    naProf?: string;
    registrationDate?: string;
    statusOfCompany?: string;
    wupType?: string;
  };
  rocRegAddressInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    address1?: string;
    address2?: string;
    address3?: string;
    companyNo?: string;
    postcode?: string;
    state?: string;
    town?: string;
  };
  rocCompanyOfficerListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocCompanyOfficerInfos?: {
      rocCompanyOfficerInfos?: Array<{
        address1?: string;
        address2?: string;
        address3?: string;
        appointmentDate?: string;
        companyNo?: string;
        designationCode?: string;
        dob?: string;
        idNo?: string;
        idType?: string;
        name?: string;
        officerInfo?: string;
        postcode?: string;
        resignDate?: string;
        startDate?: string;
        state?: string;
        town?: string;
      }>;
    };
  };
}

export interface getRocChangesRegisteredAddress {
  clientRefNo?: string;
  requestRefNo?: string;
  errorMsg?: string;
  infoId?: string;
  successCode?: string;
  rocBusinessAddressInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    address1?: string;
    address2?: string;
    address3?: string;
    companyNo?: string;
    postcode?: string;
    state?: string;
    town?: string;
  };
  rocChangesRegAddressListInfo?: {
    rocChangesRegAddressInfo?: {
      rocChangesRegAddressInfo?: Array<{
        address1?: string;
        address2?: string;
        address3?: string;
        changeOfDate?: string;
        companyNo?: string;
        lastUpdateDate?: string;
        postcode?: string;
        recordStatus?: string;
        state?: string;
        town?: string;
      }>;
    };
  };
  rocCompanyInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    balaceSheetInfo?: string;
    balaceSheetInfoDesc?: string;
    businessDescription?: string;
    checkDigit?: string;
    companyCountry?: string;
    companyName?: string;
    companyNo?: string;
    companyOldName?: string;
    companyStatus?: string;
    companyType?: string;
    currency?: string;
    dateOfChange?: string;
    incomeStatInfo?: string;
    incomeStatInfoDesc?: string;
    incorpDate?: string;
    infoColon?: string;
    latestDocUpdateDate?: string;
    llpInfo?: string;
    llpInfoDesc?: string;
    llpName?: string;
    llpNo?: string;
    llpconvertDate?: string;
    localforeignCompany?: string;
    naBal?: string;
    naProf?: string;
    registrationDate?: string;
    statusOfCompany?: string;
    wupType?: string;
  };
  rocRegAddressInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    address1?: string;
    address2?: string;
    address3?: string;
    companyNo?: string;
    postcode?: string;
    state?: string;
    town?: string;
  };
}

export interface rocBalanceSheetInfo {
  rocBalanceSheetInfos?: Array<{
    errorMsg?: string;
    infoId?: string;
    successCode?: string;
    accrualAccType?: string;
    auditFirmAddress1?: string;
    auditFirmAddress2?: string;
    auditFirmAddress3?: string;
    auditFirmName?: string;
    auditFirmNo?: string;
    auditFirmPostcode?: string;
    auditFirmState?: string;
    auditFirmTown?: string;
    auditfirmFlag?: string;
    branchkeycode?: string;
    companyNo?: string;
    contigentLiability?: string;
    currentAsset?: string;
    dateOfTabling?: string;
    financialReportType?: string;
    financialYearEndDate?: string;
    fixedAsset?: string;
    fundAndReserve?: string;
    fundReserve?: string;
    headOfficeAccount?: string;
    inappropriateProfit?: string;
    liability?: string;
    longTermLiability?: string;
    minorityInterest?: string;
    nonCurrAsset?: string;
    nonCurrentLiability?: string;
    otherAsset?: string;
    paidUpCapital?: string;
    reserves?: string;
    shareAppAccount?: string;
    sharePremium?: string;
    totalInvestment?: string;
  }>;
}

export interface rocBusinessAddressInfo {
  errorMsg?: string;
  infoId?: string;
  lastUpdateDate?: string;
  successCode?: string;
  address1?: string;
  address2?: string;
  address3?: string;
  companyNo?: string;
  postcode?: string;
  state?: string;
  town?: string;
}

export interface rocBusinessCodeListInfo {
  businessCode?: string;
  companyNo?: string;
  priority?: string;
}

export interface getLlpCurrentProfile {
  clientRefNo?: string;
  requestRefNo?: string;
  errorMsg?: string;
  infoId?: string;
  successCode?: string;
  llpCurrentProfile?: {
    successCode?: string;
    errorMsg?: string;
    llpBasicProfile?: {
      successCode?: string;
      errorMsg?: string;
      entityName?: string;
      entityNo?: string;
      entityNoNewFormat?: string;
      entityStatus?: string;
      entityStatusDt?: string;
      entityStatusDesc?: string;
      entityType?: string;
      entityTypeDesc?: string;
      entityRegDt?: string;
      entityEmail?: string;
      entityUpdateDt?: string;
      lastReturnDt?: string;
      nextReturnDt?: string;
      dueReturnDt?: string;
      regNatureOfBiz?: string;
      oldName?: string;
      nameChangeDt?: string;
      origin?: string;
      originDesc?: string;
      initialEntityName?: string;
      env?: string;
      llpConversion?: {
        entityConvEntityType?: string;
        entityConvEntityNo?: string;
        entityConvEntityName?: string;
        entityConvEntityRegDt?: string;
      };
    };
    regOfficeAdd?: {
      address1?: string;
      address2?: string;
      address3?: string;
      postcode?: string;
      city?: string;
      state?: string;
      stateDesc?: string;
      country?: string;
      countryDesc?: string;
      principalInd?: string;
      principalIndDesc?: string;
    };
    regBizAddresses?: Array<{
      address1?: string;
      address2?: string;
      address3?: string;
      postcode?: string;
      city?: string;
      state?: string;
      stateDesc?: string;
      country?: string;
      countryDesc?: string;
      principalInd?: string;
      principalIndDesc?: string;
    }>;
    involvements?: Array<{
      involveType?: string;
      involveTypeDesc?: string;
      involveName?: string;
      involveIdType?: string;
      involveIdTypeDesc?: string;
      involveId?: string;
      involveEffectiveFromDt?: string;
      involveEffectiveToDt?: string;
      involvePbType?: string;
      involveLicenseNo?: string;
      involveCertNo?: string;
      entityNo?: string;
      entityName?: string;
      entityNoNewFormat?: string;
      entityStatus?: string;
      entityStatusDesc?: string;
      address?: {
        address1?: string;
        address2?: string;
        address3?: string;
        postcode?: string;
        city?: string;
        state?: string;
        stateDesc?: string;
        country?: string;
        countryDesc?: string;
        principalInd?: string;
        principalIndDesc?: string;
      };
    }>;
    bizCodes?: Array<{
      entityBizCode?: string;
      entityBizCodeDesc?: string;
    }>;
    urlAddresses?: string[];
  };
}

export interface getImageView {
  clientRefNo?: string;
  requestRefNo?: string;
  errorMsg?: string;
  infoId?: string;
  successCode?: string;
  documentInfos?: {
    documentInfos?: Array<{
      batchId?: string;
      comments?: string;
      companyNo?: string;
      dateFiler?: string;
      documentDate?: string;
      formType?: string;
      imageName?: string;
      receivedDate?: string;
      sourceData?: string;
      stateCode?: string;
      totalPage?: string;
      verId?: string;
    }>;
  };
}

export interface getImage {
  clientRefNo?: string;
  requestRefNo?: string;
  errorMsg?: string;
  infoId?: string;
  successCode?: string;
  docContent?: string;
}

export interface createCompanyProfileOrder {
  orderRefNo?: string;
  clientRefNo?: string;
  requestRefNo?: string;
  rawData?: {
    errorMsg?: string;
    infoId?: string;
    successCode?: string;
    rocBalanceSheetInfo?: {
      accrualAccType?: string;
      auditFirmAddress1?: string;
      auditFirmAddress2?: string;
      auditFirmAddress3?: string;
      auditFirmName?: string;
      auditFirmNo?: string;
      auditFirmPostcode?: string;
      auditFirmState?: string;
      auditFirmTown?: string;
      auditfirmFlag?: string;
      branchkeycode?: string;
      companyNo?: string;
      contigentLiability?: string;
      currentAsset?: string;
      dateOfTabling?: string;
      financialReportType?: string;
      financialYearEndDate?: string;
      fixedAsset?: string;
      fundAndReserve?: string;
      headOfficeAccount?: string;
      inappropriateProfit?: string;
      liability?: string;
      longTermLiability?: string;
      minorityInterest?: string;
      nonCurrAsset?: string;
      nonCurrentLiability?: string;
      otherAsset?: string;
      paidUpCapital?: string;
      reserves?: string;
      shareAppAccount?: string;
      sharePremium?: string;
      totalInvestment?: string;
    };
    rocBalanceSheetListInfo?: {
      errorMsg?: string;
      infoId?: string;
      successCode?: string;
      rocBalanceSheetInfos?: {
        rocBalanceSheetInfos?: Array<{
          errorMsg?: string;
          infoId?: string;
          successCode?: string;
          accrualAccType?: string;
          auditFirmAddress1?: string;
          auditFirmAddress2?: string;
          auditFirmAddress3?: string;
          auditFirmName?: string;
          auditFirmNo?: string;
          auditFirmPostcode?: string;
          auditFirmState?: string;
          auditFirmTown?: string;
          auditfirmFlag?: string;
          branchkeycode?: string;
          companyNo?: string;
          contigentLiability?: string;
          currentAsset?: string;
          dateOfTabling?: string;
          financialReportType?: string;
          financialYearEndDate?: string;
          fixedAsset?: string;
          fundAndReserve?: string;
          fundReserve?: string;
          headOfficeAccount?: string;
          inappropriateProfit?: string;
          liability?: string;
          longTermLiability?: string;
          minorityInterest?: string;
          nonCurrAsset?: string;
          nonCurrentLiability?: string;
          otherAsset?: string;
          paidUpCapital?: string;
          reserves?: string;
          shareAppAccount?: string;
          sharePremium?: string;
          totalInvestment?: string;
        }>;
      };
    };
    rocBusinessAddressInfo?: {
      errorMsg?: string;
      infoId?: string;
      lastUpdateDate?: string;
      successCode?: string;
      address1?: string;
      address2?: string;
      address3?: string;
      companyNo?: string;
      postcode?: string;
      state?: string;
      town?: string;
    };
    rocBusinessCodeInfo?: {
      businessCode?: string;
      companyNo?: string;
      priority?: string;
    };
    rocBusinessCodeListInfo?: {
      errorMsg?: string;
      infoId?: string;
      successCode?: string;
      rocBusinessCodeInfos?: {
        rocBusinessCodeInfos?: Array<{
          businessCode?: string;
          companyNo?: string;
          priority?: string;
        }>;
      };
    };
    rocChargesInfo?: {
      ammendNo?: string;
      chargeAmount?: string;
      chargeCreateDate?: string;
      chargeCreateDate1?: string;
      chargeMortgageType?: string;
      chargeNo?: string;
      chargeStatus?: string;
      chargeeId?: string;
      chargeeName?: string;
      companyNo?: string;
      form40Date?: string;
      totalOfCharge?: string;
    };
    rocChargesListInfo?: {
      errorMsg?: string;
      infoId?: string;
      successCode?: string;
      rocChargesInfos?: {
        rocChargesInfos?: Array<{
          ammendNo?: string;
          chargeAmount?: string;
          chargeCreateDate?: string;
          chargeCreateDate1?: string;
          chargeMortgageType?: string;
          chargeNo?: string;
          chargeStatus?: string;
          chargeeId?: string;
          chargeeName?: string;
          companyNo?: string;
          form40Date?: string;
          totalOfCharge?: string;
        }>;
      };
    };
    rocCompanyInfo?: {
      errorMsg?: string;
      infoId?: string;
      lastUpdateDate?: string;
      successCode?: string;
      balaceSheetInfo?: string;
      balaceSheetInfoDesc?: string;
      businessDescription?: string;
      checkDigit?: string;
      companyCountry?: string;
      companyName?: string;
      companyNo?: string;
      companyOldName?: string;
      companyStatus?: string;
      companyType?: string;
      currency?: string;
      dateOfChange?: string;
      incomeStatInfo?: string;
      incomeStatInfoDesc?: string;
      incorpDate?: string;
      infoColon?: string;
      latestDocUpdateDate?: string;
      llpInfo?: string;
      llpInfoDesc?: string;
      llpName?: string;
      llpNo?: string;
      localforeignCompany?: string;
      naBal?: string;
      naProf?: string;
      statusOfCompany?: string;
      wupType?: string;
    };
    rocCompanyOfficerInfo?: {
      address1?: string;
      address2?: string;
      address3?: string;
      appointmentDate?: string;
      companyNo?: string;
      designationCode?: string;
      dob?: string;
      idNo?: string;
      idType?: string;
      name?: string;
      officerInfo?: string;
      postcode?: string;
      resignDate?: string;
      startDate?: string;
      state?: string;
      town?: string;
    };
    rocCompanyOfficerListInfo?: {
      errorMsg?: string;
      infoId?: string;
      successCode?: string;
      rocCompanyOfficerInfos?: {
        rocCompanyOfficerInfos?: Array<{
          address1?: string;
          address2?: string;
          address3?: string;
          appointmentDate?: string;
          companyNo?: string;
          designationCode?: string;
          dob?: string;
          idNo?: string;
          idType?: string;
          name?: string;
          officerInfo?: string;
          postcode?: string;
          startDate?: string;
          state?: string;
          town?: string;
        }>;
      };
    };
    rocDocumentLodgeInfo?: {
      companyNo?: string;
      documentDate?: string;
      formTrx?: string;
      updateDate?: string;
    };
    rocDocumentLodgeListInfo?: {
      errorMsg?: string;
      infoId?: string;
      successCode?: string;
      rocDocumentLodgeInfos?: {
        rocDocumentLodgeInfos?: Array<{
          companyNo?: string;
          documentDate?: string;
          formTrx?: string;
        }>;
      };
    };
    rocProfitLossInfo?: {
      errorMsg?: string;
      infoId?: string;
      lastUpdateDate?: string;
      successCode?: string;
      accrualAccount?: string;
      companyNo?: string;
      extraOrdinaryItem?: string;
      financialReportType?: string;
      financialYearEndDate?: string;
      grossDividendRate?: string;
      inappropriateProfitBf?: string;
      inappropriateProfitCf?: string;
      minorityInterest?: string;
      netDividend?: string;
      others?: string;
      priorAdjustment?: string;
      profitAfterTax?: string;
      profitBeforeTax?: string;
      profitShareholder?: string;
      revenue?: string;
      surplusAfterTax?: string;
      surplusBeforeTax?: string;
      surplusDeficitAfterTax?: string;
      surplusDeficitBeforeTax?: string;
      totalExpenditure?: string;
      totalIncome?: string;
      totalRevenue?: string;
      transferred?: string;
      turnover?: string;
    };
    rocProfitLossListInfo?: {
      errorMsg?: string;
      infoId?: string;
      successCode?: string;
      rocProfitLossInfos?: {
        rocProfitLossInfos?: Array<{
          errorMsg?: string;
          infoId?: string;
          successCode?: string;
          accrualAccount?: string;
          companyNo?: string;
          extraOrdinaryItem?: string;
          financialReportType?: string;
          financialYearEndDate?: string;
          grossDividendRate?: string;
          inappropriateProfitBf?: string;
          inappropriateProfitCf?: string;
          minorityInterest?: string;
          netDividend?: string;
          others?: string;
          priorAdjustment?: string;
          profitAfterTax?: string;
          profitBeforeTax?: string;
          profitShareholder?: string;
          revenue?: string;
          surplusAfterTax?: string;
          surplusBeforeTax?: string;
          surplusDeficitAfterTax?: string;
          surplusDeficitBeforeTax?: string;
          totalExpenditure?: string;
          totalIncome?: string;
          totalRevenue?: string;
          transferred?: string;
          turnover?: string;
        }>;
      };
    };
    rocRegAddressInfo?: {
      errorMsg?: string;
      infoId?: string;
      lastUpdateDate?: string;
      successCode?: string;
      address1?: string;
      address2?: string;
      address3?: string;
      companyNo?: string;
      postcode?: string;
      state?: string;
      town?: string;
    };
    rocShareCapitalInfo?: {
      errorMsg?: string;
      infoId?: string;
      successCode?: string;
      authorisedCapital?: string;
      companyNo?: string;
      currency?: string;
      currenyNominal?: string;
      ordAIssuedCash?: string;
      ordAIssuedNominal?: string;
      ordAIssuedNonCash?: string;
      ordANominalValue?: string;
      ordANumberOfShares?: string;
      ordAmountAValue?: string;
      ordAmountBValue?: string;
      ordAmountValue?: string;
      ordBIssuedCash?: string;
      ordBIssuedNominal?: string;
      ordBIssuedNonCash?: string;
      ordBNominalValue?: string;
      ordBNumberOfShares?: string;
      ordIssuedCash?: string;
      ordIssuedNominal?: string;
      ordIssuedNonCash?: string;
      ordNominalValue?: string;
      ordNumberOfShares?: string;
      othAIssuedCash?: string;
      othAIssuedNonCash?: string;
      othAmountValue?: string;
      othBIssuedCash?: string;
      othBIssuedNonCash?: string;
      othIssuedCash?: string;
      othIssuedNominal?: string;
      othIssuedNonCash?: string;
      othNominalValue?: string;
      othNumberOfShares?: string;
      prefAIssuedCash?: string;
      prefAIssuedNominal?: string;
      prefAIssuedNonCash?: string;
      prefANominalValue?: string;
      prefANumberOfShares?: string;
      prefAmountAValue?: string;
      prefAmountBValue?: string;
      prefAmountValue?: string;
      prefBIssuedCash?: string;
      prefBIssuedNominal?: string;
      prefBIssuedNonCash?: string;
      prefBNominalValue?: string;
      prefBNumberOfShares?: string;
      prefIssuedCash?: string;
      prefIssuedNominal?: string;
      prefIssuedNonCash?: string;
      prefNominalValue?: string;
      prefNumberOfShares?: string;
      totalIssued?: string;
    };
    rocShareholderInfo?: {
      companyNo?: string;
      dob?: string;
      idNo?: string;
      idType?: string;
      name?: string;
      share?: string;
      shareVol?: string;
    };
    rocShareholderListInfo?: {
      errorMsg?: string;
      infoId?: string;
      successCode?: string;
      rocShareholderInfos?: {
        rocShareholderInfos?: Array<{
          companyNo?: string;
          dob?: string;
          idNo?: string;
          idType?: string;
          name?: string;
          share?: string;
          shareVol?: string;
        }>;
      };
    };
  };
  pdfUrl?: string;
  errorGeneral?: string;
}

export interface createBusinessProfileOrder {
  clientRefNo?: string;
  requestRefNo?: string;
  orderRefNo?: string;
  rawData?: {
    errorMsg?: string;
    infoId?: string;
    successCode?: string;
    robBusinessInfo?: {
      errorMsg?: string;
      infoId?: string;
      successCode?: string;
      ammendmentDate?: string;
      checkDigit?: string;
      description?: string;
      endBusinessDate?: string;
      llpName?: string;
      llpNo?: string;
      mainAddress1?: string;
      mainAddress2?: string;
      mainAddress3?: string;
      mainPostcode?: string;
      mainState?: string;
      mainTown?: string;
      nameType?: string;
      ownerCount?: string;
      postAddress1?: string;
      postAddress2?: string;
      postAddress3?: string;
      postPostcode?: string;
      postState?: string;
      postTown?: string;
      referenceNo?: string;
      registrationDate?: string;
      registrationName?: string;
      registrationNo?: string;
      revokeReasonType?: string;
      startBusinessDate?: string;
      status?: string;
    };
    robOwnershipListInfo?: {
      errorMsg?: string;
      infoId?: string;
      successCode?: string;
      robOwnerShipInfos?: {
        robOwnerShipInfos?: Array<{
          address1?: string;
          address2?: string;
          address3?: string;
          ammendmentType?: string;
          checkDigit?: string;
          color?: string;
          createDate?: string;
          dob?: string;
          entryDate?: string;
          gender?: string;
          idCardNumber?: string;
          idCardType?: string;
          nationality?: string;
          newIcNo?: string;
          othColor?: string;
          othRace?: string;
          ownerName?: string;
          ownershipLink?: string;
          postcode?: string;
          race?: string;
          registrationName?: string;
          registrationNo?: string;
          state?: string;
          status?: string;
          town?: string;
          updateDate?: string;
        }>;
      };
    };
    robBusinessCodeListInfo?: {
      errorMsg?: string;
      infoId?: string;
      successCode?: string;
      robBusinessCodeInfos?: {
        robBusinessCodeInfos?: Array<{
          businessCode?: string;
          checkDigit?: string;
          description?: string;
          descriptionEnglish?: string;
          registrationName?: string;
          registrationNo?: string;
        }>;
      };
    };
    robBranchListInfo?: {
      errorMsg?: string;
      infoId?: string;
      successCode?: string;
      robBranchInfos?: {
        robBranchInfos?: Array<{
          address1?: string;
          address2?: string;
          address3?: string;
          checkDigit?: string;
          postcode?: string;
          registrationName?: string;
          registrationNo?: string;
          state?: string;
          status?: string;
          town?: string;
        }>;
      };
    };
  };
  pdfUrl?: string;
  errorGeneral?: string;
}

export interface getCompanyProfilePhaseTwoV2 {
  clientRefNo?: string;
  requestRefNo?: string;
  orderRefNo?: string;
  generatedDate?: string;
  errorMsg?: string;
  infoId?: string;
  successCode?: string;
  rocBalanceSheetInfo?: {
    accrualAccType?: string;
    auditFirmAddress1?: string;
    auditFirmAddress2?: string;
    auditFirmAddress3?: string;
    auditFirmName?: string;
    auditFirmNo?: string;
    auditFirmPostcode?: string;
    auditFirmState?: string;
    auditFirmTown?: string;
    auditfirmFlag?: string;
    branchkeycode?: string;
    companyNo?: string;
    contigentLiability?: string;
    currentAsset?: string;
    dateOfTabling?: string;
    financialReportType?: string;
    financialYearEndDate?: string;
    fixedAsset?: string;
    fundAndReserve?: string;
    headOfficeAccount?: string;
    inappropriateProfit?: string;
    liability?: string;
    longTermLiability?: string;
    minorityInterest?: string;
    nonCurrAsset?: string;
    nonCurrentLiability?: string;
    otherAsset?: string;
    paidUpCapital?: string;
    reserves?: string;
    shareAppAccount?: string;
    sharePremium?: string;
    totalInvestment?: string;
  };
  rocBalanceSheetListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocBalanceSheetInfos?: {
      rocBalanceSheetInfos?: Array<{
        errorMsg?: string;
        infoId?: string;
        successCode?: string;
        accrualAccType?: string;
        auditFirmAddress1?: string;
        auditFirmAddress2?: string;
        auditFirmAddress3?: string;
        auditFirmName?: string;
        auditFirmNo?: string;
        auditFirmPostcode?: string;
        auditFirmState?: string;
        auditFirmTown?: string;
        auditfirmFlag?: string;
        branchkeycode?: string;
        companyNo?: string;
        contigentLiability?: string;
        currentAsset?: string;
        dateOfTabling?: string;
        financialReportType?: string;
        financialYearEndDate?: string;
        fixedAsset?: string;
        fundAndReserve?: string;
        fundReserve?: string;
        headOfficeAccount?: string;
        inappropriateProfit?: string;
        liability?: string;
        longTermLiability?: string;
        minorityInterest?: string;
        nonCurrAsset?: string;
        nonCurrentLiability?: string;
        otherAsset?: string;
        paidUpCapital?: string;
        reserves?: string;
        shareAppAccount?: string;
        sharePremium?: string;
        totalInvestment?: string;
      }>;
    };
  };
  rocBusinessAddressInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    address1?: string;
    address2?: string;
    address3?: string;
    companyNo?: string;
    postcode?: string;
    state?: string;
    town?: string;
  };
  rocBusinessCodeInfo?: {
    businessCode?: string;
    companyNo?: string;
    priority?: string;
  };
  rocBusinessCodeListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocBusinessCodeInfos?: {
      rocBusinessCodeInfos?: Array<{
        businessCode?: string;
        companyNo?: string;
        priority?: string;
      }>;
    };
  };
  rocChargesInfo?: {
    ammendNo?: string;
    chargeAmount?: string;
    chargeCreateDate?: string;
    chargeCreateDate1?: string;
    chargeMortgageType?: string;
    chargeNo?: string;
    chargeStatus?: string;
    chargeeId?: string;
    chargeeName?: string;
    companyNo?: string;
    form40Date?: string;
    totalOfCharge?: string;
  };
  rocChargesListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocChargesInfos?: {
      rocChargesInfos?: Array<{
        ammendNo?: string;
        chargeAmount?: string;
        chargeCreateDate?: string;
        chargeCreateDate1?: string;
        chargeMortgageType?: string;
        chargeNo?: string;
        chargeStatus?: string;
        chargeeId?: string;
        chargeeName?: string;
        companyNo?: string;
        form40Date?: string;
        totalOfCharge?: string;
      }>;
    };
  };
  rocCompanyInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    balaceSheetInfo?: string;
    balaceSheetInfoDesc?: string;
    businessDescription?: string;
    checkDigit?: string;
    companyCountry?: string;
    companyName?: string;
    companyNo?: string;
    companyOldName?: string;
    companyStatus?: string;
    companyType?: string;
    currency?: string;
    dateOfChange?: string;
    incomeStatInfo?: string;
    incomeStatInfoDesc?: string;
    incorpDate?: string;
    infoColon?: string;
    latestDocUpdateDate?: string;
    llpInfo?: string;
    llpInfoDesc?: string;
    llpName?: string;
    llpNo?: string;
    llpconvertDate?: string;
    localforeignCompany?: string;
    naBal?: string;
    naProf?: string;
    registrationDate?: string;
    statusOfCompany?: string;
    wupType?: string;
    newFormatRegNo?: string;
  };
  rocCompanyOfficerInfo?: {
    address1?: string;
    address2?: string;
    address3?: string;
    appointmentDate?: string;
    companyNo?: string;
    designationCode?: string;
    dob?: string;
    idNo?: string;
    idType?: string;
    name?: string;
    officerInfo?: string;
    postcode?: string;
    resignDate?: string;
    startDate?: string;
    state?: string;
    town?: string;
  };
  rocCompanyOfficerListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocCompanyOfficerInfos?: {
      rocCompanyOfficerInfos?: Array<{
        address1?: string;
        address2?: string;
        address3?: string;
        appointmentDate?: string;
        companyNo?: string;
        designationCode?: string;
        dob?: string;
        idNo?: string;
        idType?: string;
        name?: string;
        officerInfo?: string;
        postcode?: string;
        resignDate?: string;
        startDate?: string;
        state?: string;
        town?: string;
      }>;
    };
  };
  rocDocumentLodgeInfo?: {
    companyNo?: string;
    documentDate?: string;
    formTrx?: string;
    updateDate?: string;
  };
  rocDocumentLodgeListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocDocumentLodgeInfos?: {
      rocDocumentLodgeInfos?: Array<{
        companyNo?: string;
        documentDate?: string;
        formTrx?: string;
        updateDate?: string;
      }>;
    };
  };
  rocProfitLossInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    accrualAccount?: string;
    companyNo?: string;
    extraOrdinaryItem?: string;
    financialReportType?: string;
    financialYearEndDate?: string;
    grossDividendRate?: string;
    inappropriateProfitBf?: string;
    inappropriateProfitCf?: string;
    minorityInterest?: string;
    netDividend?: string;
    others?: string;
    priorAdjustment?: string;
    profitAfterTax?: string;
    profitBeforeTax?: string;
    profitShareholder?: string;
    revenue?: string;
    surplusAfterTax?: string;
    surplusBeforeTax?: string;
    surplusDeficitAfterTax?: string;
    surplusDeficitBeforeTax?: string;
    totalExpenditure?: string;
    totalIncome?: string;
    totalRevenue?: string;
    transferred?: string;
    turnover?: string;
  };
  rocProfitLossListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocProfitLossInfos?: {
      rocProfitLossInfos?: Array<{
        errorMsg?: string;
        infoId?: string;
        lastUpdateDate?: string;
        successCode?: string;
        accrualAccount?: string;
        companyNo?: string;
        extraOrdinaryItem?: string;
        financialReportType?: string;
        financialYearEndDate?: string;
        grossDividendRate?: string;
        inappropriateProfitBf?: string;
        inappropriateProfitCf?: string;
        minorityInterest?: string;
        netDividend?: string;
        others?: string;
        priorAdjustment?: string;
        profitAfterTax?: string;
        profitBeforeTax?: string;
        profitShareholder?: string;
        revenue?: string;
        surplusAfterTax?: string;
        surplusBeforeTax?: string;
        surplusDeficitAfterTax?: string;
        surplusDeficitBeforeTax?: string;
        totalExpenditure?: string;
        totalIncome?: string;
        totalRevenue?: string;
        transferred?: string;
        turnover?: string;
      }>;
    };
  };
  rocRegAddressInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    address1?: string;
    address2?: string;
    address3?: string;
    companyNo?: string;
    postcode?: string;
    state?: string;
    town?: string;
  };
  rocShareCapitalInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    authorisedCapital?: string;
    companyNo?: string;
    currency?: string;
    currenyNominal?: string;
    ordAIssuedCash?: string;
    ordAIssuedNominal?: string;
    ordAIssuedNonCash?: string;
    ordANominalValue?: string;
    ordANumberOfShares?: string;
    ordAmountAValue?: string;
    ordAmountBValue?: string;
    ordAmountValue?: string;
    ordBIssuedCash?: string;
    ordBIssuedNominal?: string;
    ordBIssuedNonCash?: string;
    ordBNominalValue?: string;
    ordBNumberOfShares?: string;
    ordIssuedCash?: string;
    ordIssuedNominal?: string;
    ordIssuedNonCash?: string;
    ordNominalValue?: string;
    ordNumberOfShares?: string;
    othAIssuedCash?: string;
    othAIssuedNonCash?: string;
    othAmountValue?: string;
    othBIssuedCash?: string;
    othBIssuedNonCash?: string;
    othIssuedCash?: string;
    othIssuedNominal?: string;
    othIssuedNonCash?: string;
    othNominalValue?: string;
    othNumberOfShares?: string;
    prefAIssuedCash?: string;
    prefAIssuedNominal?: string;
    prefAIssuedNonCash?: string;
    prefANominalValue?: string;
    prefANumberOfShares?: string;
    prefAmountAValue?: string;
    prefAmountBValue?: string;
    prefAmountValue?: string;
    prefBIssuedCash?: string;
    prefBIssuedNominal?: string;
    prefBIssuedNonCash?: string;
    prefBNominalValue?: string;
    prefBNumberOfShares?: string;
    prefIssuedCash?: string;
    prefIssuedNominal?: string;
    prefIssuedNonCash?: string;
    prefNominalValue?: string;
    prefNumberOfShares?: string;
    totalIssued?: string;
  };
  rocShareholderInfo?: {
    companyNo?: string;
    dob?: string;
    idNo?: string;
    idType?: string;
    name?: string;
    share?: string;
    shareVol?: string;
    newFormatRegNo?: string;
  };
  rocShareholderListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocShareholderInfos?: {
      rocShareholderInfos?: Array<{
        companyNo?: string;
        dob?: string;
        idNo?: string;
        idType?: string;
        name?: string;
        share?: string;
        shareVol?: string;
        newFormatRegNo?: string;
      }>;
    };
  };
}

export interface getBizProfilePhaseTwoV2 {
  clientRefNo?: string;
  requestRefNo?: string;
  orderRefNo?: string;
  generatedDate?: string;
  errorMsg?: string;
  infoId?: string;
  successCode?: string;
  robBusinessInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    ammendmentDate?: string;
    checkDigit?: string;
    description?: string;
    endBusinessDate?: string;
    llpName?: string;
    llpNo?: string;
    llpconvertDate?: string;
    mainAddress1?: string;
    mainAddress2?: string;
    mainAddress3?: string;
    mainPostcode?: string;
    mainState?: string;
    mainTown?: string;
    nameType?: string;
    ownerCount?: string;
    postAddress1?: string;
    postAddress2?: string;
    postAddress3?: string;
    postPostcode?: string;
    postState?: string;
    postTown?: string;
    referenceNo?: string;
    registrationDate?: string;
    registrationName?: string;
    registrationNo?: string;
    revokeReasonType?: string;
    startBusinessDate?: string;
    status?: string;
    terminationDate?: string;
    newFormatRegNo?: string;
  };
  robOwnershipListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    robOwnerShipInfos?: {
      robOwnerShipInfos?: Array<{
        address1?: string;
        address2?: string;
        address3?: string;
        ammendmentType?: string;
        checkDigit?: string;
        color?: string;
        createDate?: string;
        dob?: string;
        entryDate?: string;
        gender?: string;
        idCardNumber?: string;
        idCardType?: string;
        nationality?: string;
        newIcNo?: string;
        othColor?: string;
        othRace?: string;
        ownerName?: string;
        ownershipLink?: string;
        postcode?: string;
        race?: string;
        registrationName?: string;
        registrationNo?: string;
        state?: string;
        status?: string;
        town?: string;
        updateDate?: string;
      }>;
    };
  };
  robBusinessCodeListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    robBusinessCodeInfos?: {
      robBusinessCodeInfos?: Array<{
        businessCode?: string;
        checkDigit?: string;
        description?: string;
        descriptionEnglish?: string;
        registrationName?: string;
        registrationNo?: string;
      }>;
    };
  };
  robBranchListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    robBranchInfos?: {
      robBranchInfos?: Array<{
        address1?: string;
        address2?: string;
        address3?: string;
        checkDigit?: string;
        postcode?: string;
        registrationName?: string;
        registrationNo?: string;
        state?: string;
        status?: string;
        town?: string;
      }>;
    };
  };
}

export interface getOrderDocument {
  clientRefNo?: string;
  requestRefNo?: string;
  data?: {
    orderNumber?: string;
    requestRefNo?: string;
    status?: string;
    documentUrl?: string;
  };
}

export interface getValidation {
  clientRefNo?: string;
  requestRefNo?: string;
  data?: {
    companyName?: string;
    companyNo?: string;
    oldCompanyNo?: string;
    productType?: string;
    lastUpdatedTimestamp?: string;
    isAvailable?: string;
    availableYears?: unknown[];
  };
}

export interface getLlpCurrentProfileV2 {
  clientRefNo?: string;
  requestRefNo?: string;
  orderRefNo?: string;
  generatedDate?: string;
  errorMsg?: string;
  infoId?: string;
  successCode?: string;
  llpCurrentProfile?: {
    successCode?: string;
    errorMsg?: string;
    llpBasicProfile?: {
      successCode?: string;
      errorMsg?: string;
      entityName?: string;
      entityNo?: string;
      entityNoNewFormat?: string;
      entityStatus?: string;
      entityStatusDt?: string;
      entityStatusDesc?: string;
      entityType?: string;
      entityTypeDesc?: string;
      entityRegDt?: string;
      entityEmail?: string;
      entityUpdateDt?: string;
      lastReturnDt?: string;
      nextReturnDt?: string;
      dueReturnDt?: string;
      regNatureOfBiz?: string;
      oldName?: string;
      nameChangeDt?: string;
      origin?: string;
      originDesc?: string;
      initialEntityName?: string;
      env?: string;
      llpConversion?: {
        entityConvEntityType?: string;
        entityConvEntityNo?: string;
        entityConvEntityName?: string;
        entityConvEntityRegDt?: string;
      };
    };
    regOfficeAdd?: {
      address1?: string;
      address2?: string;
      address3?: string;
      postcode?: string;
      city?: string;
      state?: string;
      stateDesc?: string;
      country?: string;
      countryDesc?: string;
      principalInd?: string;
      principalIndDesc?: string;
    };
    regBizAddresses?: Array<{
      address1?: string;
      address2?: string;
      address3?: string;
      postcode?: string;
      city?: string;
      state?: string;
      stateDesc?: string;
      country?: string;
      countryDesc?: string;
      principalInd?: string;
      principalIndDesc?: string;
    }>;
    involvements?: Array<{
      involveType?: string;
      involveTypeDesc?: string;
      involveName?: string;
      involveIdType?: string;
      involveIdTypeDesc?: string;
      involveId?: string;
      involveEffectiveFromDt?: string;
      involveEffectiveToDt?: string;
      involvePbType?: string;
      involveLicenseNo?: string;
      involveCertNo?: string;
      entityNo?: string;
      entityName?: string;
      entityNoNewFormat?: string;
      entityStatus?: string;
      entityStatusDesc?: string;
      address?: {
        address1?: string;
        address2?: string;
        address3?: string;
        postcode?: string;
        city?: string;
        state?: string;
        stateDesc?: string;
        country?: string;
        countryDesc?: string;
        principalInd?: string;
        principalIndDesc?: string;
      };
    }>;
    bizCodes?: Array<{
      entityBizCode?: string;
      entityBizCodeDesc?: string;
    }>;
    urlAddresses?: string[];
  };
}

export interface getCertIncorpPhaseTwoV2 {
  clientRefNo?: string;
  requestRefNo?: string;
  orderRefNo?: string;
  generatedDate?: string;
  branchCode?: string;
  checkDigit?: string;
  companyCountry?: string;
  companyName?: string;
  companyNo?: string;
  companyOldName?: string;
  companyStatus?: string;
  companyType?: string;
  dateOfChange?: string;
  errorMsg?: string;
  incorpDate?: string;
  infoId?: string;
  localforeignCompany?: string;
  newCompanyStatus?: string;
  oldCompanyStatus?: string;
  newFormatRegNo?: string;
  successCode?: string;
}

export interface getInfoFin2PhaseTwoV2 {
  clientRefNo?: string;
  requestRefNo?: string;
  orderRefNo?: string;
  generatedDate?: string;
  errorMsg?: string;
  infoId?: string;
  successCode?: string;
  rocBalanceSheetListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocBalanceSheetInfos?: {
      rocBalanceSheetInfos?: Array<{
        errorMsg?: string;
        infoId?: string;
        lastUpdateDate?: string;
        successCode?: string;
        accrualAccType?: string;
        auditFirmAddress1?: string;
        auditFirmAddress2?: string;
        auditFirmAddress3?: string;
        auditFirmName?: string;
        auditFirmNo?: string;
        auditFirmPostcode?: string;
        auditFirmState?: string;
        auditFirmTown?: string;
        auditfirmFlag?: string;
        branchkeycode?: string;
        companyNo?: string;
        contigentLiability?: string;
        currentAsset?: string;
        dateOfTabling?: string;
        financialReportType?: string;
        financialYearEndDate?: string;
        fixedAsset?: string;
        fundAndReserve?: string;
        fundReserve?: string;
        headOfficeAccount?: string;
        inappropriateProfit?: string;
        liability?: string;
        longTermLiability?: string;
        minorityInterest?: string;
        nonCurrAsset?: string;
        nonCurrentLiability?: string;
        otherAsset?: string;
        paidUpCapital?: string;
        reserves?: string;
        shareAppAccount?: string;
        sharePremium?: string;
        totalInvestment?: string;
      }>;
    };
  };
  rocBusinessAddressInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    address1?: string;
    address2?: string;
    address3?: string;
    companyNo?: string;
    postcode?: string;
    state?: string;
    town?: string;
  };
  rocCompanyInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    balaceSheetInfo?: string;
    balaceSheetInfoDesc?: string;
    businessDescription?: string;
    checkDigit?: string;
    companyCountry?: string;
    companyName?: string;
    companyNo?: string;
    companyOldName?: string;
    companyStatus?: string;
    companyType?: string;
    newFormatRegNo?: string;
    currency?: string;
    dateOfChange?: string;
    incomeStatInfo?: string;
    incomeStatInfoDesc?: string;
    incorpDate?: string;
    infoColon?: string;
    latestDocUpdateDate?: string;
    llpInfo?: string;
    llpInfoDesc?: string;
    llpName?: string;
    llpNo?: string;
    llpconvertDate?: string;
    localforeignCompany?: string;
    naBal?: string;
    naProf?: string;
    statusOfCompany?: string;
    wupType?: string;
  };
  rocDocumentLodgeListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocDocumentLodgeInfos?: {
      rocDocumentLodgeInfos?: Array<{
        companyNo?: string;
        documentDate?: string;
        formTrx?: string;
      }>;
    };
  };
  rocProfitLossListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocProfitLossInfos?: {
      rocProfitLossInfos?: Array<{
        errorMsg?: string;
        infoId?: string;
        lastUpdateDate?: string;
        successCode?: string;
        accrualAccount?: string;
        companyNo?: string;
        extraOrdinaryItem?: string;
        financialReportType?: string;
        financialYearEndDate?: string;
        grossDividendRate?: string;
        inappropriateProfitBf?: string;
        inappropriateProfitCf?: string;
        minorityInterest?: string;
        netDividend?: string;
        others?: string;
        priorAdjustment?: string;
        profitAfterTax?: string;
        profitBeforeTax?: string;
        profitShareholder?: string;
        revenue?: string;
        surplusAfterTax?: string;
        surplusBeforeTax?: string;
        surplusDeficitAfterTax?: string;
        surplusDeficitBeforeTax?: string;
        totalExpenditure?: string;
        totalIncome?: string;
        totalRevenue?: string;
        transferred?: string;
        turnover?: string;
      }>;
    };
  };
  rocRegAddressInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    address1?: string;
    address2?: string;
    address3?: string;
    companyNo?: string;
    postcode?: string;
    state?: string;
    town?: string;
  };
}

export interface getInfoFin3PhaseTwoV2 {
  clientRefNo?: string;
  requestRefNo?: string;
  orderRefNo?: string;
  generatedDate?: string;
  errorMsg?: string;
  infoId?: string;
  successCode?: string;
  rocBalanceSheetListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocBalanceSheetInfos?: {
      rocBalanceSheetInfos?: Array<{
        errorMsg?: string;
        infoId?: string;
        lastUpdateDate?: string;
        successCode?: string;
        accrualAccType?: string;
        auditFirmAddress1?: string;
        auditFirmAddress2?: string;
        auditFirmAddress3?: string;
        auditFirmName?: string;
        auditFirmNo?: string;
        auditFirmPostcode?: string;
        auditFirmState?: string;
        auditFirmTown?: string;
        auditfirmFlag?: string;
        branchkeycode?: string;
        companyNo?: string;
        contigentLiability?: string;
        currentAsset?: string;
        dateOfTabling?: string;
        financialReportType?: string;
        financialYearEndDate?: string;
        fixedAsset?: string;
        fundAndReserve?: string;
        fundReserve?: string;
        headOfficeAccount?: string;
        inappropriateProfit?: string;
        liability?: string;
        longTermLiability?: string;
        minorityInterest?: string;
        nonCurrAsset?: string;
        nonCurrentLiability?: string;
        otherAsset?: string;
        paidUpCapital?: string;
        reserves?: string;
        shareAppAccount?: string;
        sharePremium?: string;
        totalInvestment?: string;
      }>;
    };
  };
  rocBusinessAddressInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    address1?: string;
    address2?: string;
    address3?: string;
    companyNo?: string;
    postcode?: string;
    state?: string;
    town?: string;
  };
  rocCompanyInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    balaceSheetInfo?: string;
    balaceSheetInfoDesc?: string;
    businessDescription?: string;
    checkDigit?: string;
    companyCountry?: string;
    companyName?: string;
    companyNo?: string;
    companyOldName?: string;
    companyStatus?: string;
    companyType?: string;
    newFormatRegNo?: string;
    currency?: string;
    dateOfChange?: string;
    incomeStatInfo?: string;
    incomeStatInfoDesc?: string;
    incorpDate?: string;
    infoColon?: string;
    latestDocUpdateDate?: string;
    llpInfo?: string;
    llpInfoDesc?: string;
    llpName?: string;
    llpNo?: string;
    llpconvertDate?: string;
    localforeignCompany?: string;
    naBal?: string;
    naProf?: string;
    statusOfCompany?: string;
    wupType?: string;
  };
  rocDocumentLodgeListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocDocumentLodgeInfos?: {
      rocDocumentLodgeInfos?: Array<{
        companyNo?: string;
        documentDate?: string;
        formTrx?: string;
      }>;
    };
  };
  rocProfitLossListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocProfitLossInfos?: {
      rocProfitLossInfos?: Array<{
        errorMsg?: string;
        infoId?: string;
        lastUpdateDate?: string;
        successCode?: string;
        accrualAccount?: string;
        companyNo?: string;
        extraOrdinaryItem?: string;
        financialReportType?: string;
        financialYearEndDate?: string;
        grossDividendRate?: string;
        inappropriateProfitBf?: string;
        inappropriateProfitCf?: string;
        minorityInterest?: string;
        netDividend?: string;
        others?: string;
        priorAdjustment?: string;
        profitAfterTax?: string;
        profitBeforeTax?: string;
        profitShareholder?: string;
        revenue?: string;
        surplusAfterTax?: string;
        surplusBeforeTax?: string;
        surplusDeficitAfterTax?: string;
        surplusDeficitBeforeTax?: string;
        totalExpenditure?: string;
        totalIncome?: string;
        totalRevenue?: string;
        transferred?: string;
        turnover?: string;
      }>;
    };
  };
  rocRegAddressInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    address1?: string;
    address2?: string;
    address3?: string;
    companyNo?: string;
    postcode?: string;
    state?: string;
    town?: string;
  };
}

export interface getInfoFin5PhaseTwoV2 {
  clientRefNo?: string;
  requestRefNo?: string;
  orderRefNo?: string;
  generatedDate?: string;
  errorMsg?: string;
  infoId?: string;
  successCode?: string;
  rocBalanceSheetListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocBalanceSheetInfos?: {
      rocBalanceSheetInfos?: Array<{
        errorMsg?: string;
        infoId?: string;
        lastUpdateDate?: string;
        successCode?: string;
        accrualAccType?: string;
        auditFirmAddress1?: string;
        auditFirmAddress2?: string;
        auditFirmAddress3?: string;
        auditFirmName?: string;
        auditFirmNo?: string;
        auditFirmPostcode?: string;
        auditFirmState?: string;
        auditFirmTown?: string;
        auditfirmFlag?: string;
        branchkeycode?: string;
        companyNo?: string;
        contigentLiability?: string;
        currentAsset?: string;
        dateOfTabling?: string;
        financialReportType?: string;
        financialYearEndDate?: string;
        fixedAsset?: string;
        fundAndReserve?: string;
        fundReserve?: string;
        headOfficeAccount?: string;
        inappropriateProfit?: string;
        liability?: string;
        longTermLiability?: string;
        minorityInterest?: string;
        nonCurrAsset?: string;
        nonCurrentLiability?: string;
        otherAsset?: string;
        paidUpCapital?: string;
        reserves?: string;
        shareAppAccount?: string;
        sharePremium?: string;
        totalInvestment?: string;
      }>;
    };
  };
  rocBusinessAddressInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    address1?: string;
    address2?: string;
    address3?: string;
    companyNo?: string;
    postcode?: string;
    state?: string;
    town?: string;
  };
  rocCompanyInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    balaceSheetInfo?: string;
    balaceSheetInfoDesc?: string;
    businessDescription?: string;
    checkDigit?: string;
    companyCountry?: string;
    companyName?: string;
    companyNo?: string;
    companyOldName?: string;
    companyStatus?: string;
    companyType?: string;
    newFormatRegNo?: string;
    currency?: string;
    dateOfChange?: string;
    incomeStatInfo?: string;
    incomeStatInfoDesc?: string;
    incorpDate?: string;
    infoColon?: string;
    latestDocUpdateDate?: string;
    llpInfo?: string;
    llpInfoDesc?: string;
    llpName?: string;
    llpNo?: string;
    llpconvertDate?: string;
    localforeignCompany?: string;
    naBal?: string;
    naProf?: string;
    statusOfCompany?: string;
    wupType?: string;
  };
  rocDocumentLodgeListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocDocumentLodgeInfos?: {
      rocDocumentLodgeInfos?: Array<{
        companyNo?: string;
        documentDate?: string;
        formTrx?: string;
      }>;
    };
  };
  rocProfitLossListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocProfitLossInfos?: {
      rocProfitLossInfos?: Array<{
        errorMsg?: string;
        infoId?: string;
        lastUpdateDate?: string;
        successCode?: string;
        accrualAccount?: string;
        companyNo?: string;
        extraOrdinaryItem?: string;
        financialReportType?: string;
        financialYearEndDate?: string;
        grossDividendRate?: string;
        inappropriateProfitBf?: string;
        inappropriateProfitCf?: string;
        minorityInterest?: string;
        netDividend?: string;
        others?: string;
        priorAdjustment?: string;
        profitAfterTax?: string;
        profitBeforeTax?: string;
        profitShareholder?: string;
        revenue?: string;
        surplusAfterTax?: string;
        surplusBeforeTax?: string;
        surplusDeficitAfterTax?: string;
        surplusDeficitBeforeTax?: string;
        totalExpenditure?: string;
        totalIncome?: string;
        totalRevenue?: string;
        transferred?: string;
        turnover?: string;
      }>;
    };
  };
  rocRegAddressInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    address1?: string;
    address2?: string;
    address3?: string;
    companyNo?: string;
    postcode?: string;
    state?: string;
    town?: string;
  };
}

export interface getInfoFin10PhaseTwoV2 {
  clientRefNo?: string;
  requestRefNo?: string;
  orderRefNo?: string;
  generatedDate?: string;
  errorMsg?: string;
  infoId?: string;
  successCode?: string;
  rocBalanceSheetListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocBalanceSheetInfos?: {
      rocBalanceSheetInfos?: Array<{
        errorMsg?: string;
        infoId?: string;
        lastUpdateDate?: string;
        successCode?: string;
        accrualAccType?: string;
        auditFirmAddress1?: string;
        auditFirmAddress2?: string;
        auditFirmAddress3?: string;
        auditFirmName?: string;
        auditFirmNo?: string;
        auditFirmPostcode?: string;
        auditFirmState?: string;
        auditFirmTown?: string;
        auditfirmFlag?: string;
        branchkeycode?: string;
        companyNo?: string;
        contigentLiability?: string;
        currentAsset?: string;
        dateOfTabling?: string;
        financialReportType?: string;
        financialYearEndDate?: string;
        fixedAsset?: string;
        fundAndReserve?: string;
        fundReserve?: string;
        headOfficeAccount?: string;
        inappropriateProfit?: string;
        liability?: string;
        longTermLiability?: string;
        minorityInterest?: string;
        nonCurrAsset?: string;
        nonCurrentLiability?: string;
        otherAsset?: string;
        paidUpCapital?: string;
        reserves?: string;
        shareAppAccount?: string;
        sharePremium?: string;
        totalInvestment?: string;
      }>;
    };
  };
  rocBusinessAddressInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    address1?: string;
    address2?: string;
    address3?: string;
    companyNo?: string;
    postcode?: string;
    state?: string;
    town?: string;
  };
  rocCompanyInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    balaceSheetInfo?: string;
    balaceSheetInfoDesc?: string;
    businessDescription?: string;
    checkDigit?: string;
    companyCountry?: string;
    companyName?: string;
    companyNo?: string;
    companyOldName?: string;
    companyStatus?: string;
    companyType?: string;
    newFormatRegNo?: string;
    currency?: string;
    dateOfChange?: string;
    incomeStatInfo?: string;
    incomeStatInfoDesc?: string;
    incorpDate?: string;
    infoColon?: string;
    latestDocUpdateDate?: string;
    llpInfo?: string;
    llpInfoDesc?: string;
    llpName?: string;
    llpNo?: string;
    llpconvertDate?: string;
    localforeignCompany?: string;
    naBal?: string;
    naProf?: string;
    statusOfCompany?: string;
    wupType?: string;
  };
  rocDocumentLodgeListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocDocumentLodgeInfos?: {
      rocDocumentLodgeInfos?: Array<{
        companyNo?: string;
        documentDate?: string;
        formTrx?: string;
      }>;
    };
  };
  rocProfitLossListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocProfitLossInfos?: {
      rocProfitLossInfos?: Array<{
        errorMsg?: string;
        infoId?: string;
        lastUpdateDate?: string;
        successCode?: string;
        accrualAccount?: string;
        companyNo?: string;
        extraOrdinaryItem?: string;
        financialReportType?: string;
        financialYearEndDate?: string;
        grossDividendRate?: string;
        inappropriateProfitBf?: string;
        inappropriateProfitCf?: string;
        minorityInterest?: string;
        netDividend?: string;
        others?: string;
        priorAdjustment?: string;
        profitAfterTax?: string;
        profitBeforeTax?: string;
        profitShareholder?: string;
        revenue?: string;
        surplusAfterTax?: string;
        surplusBeforeTax?: string;
        surplusDeficitAfterTax?: string;
        surplusDeficitBeforeTax?: string;
        totalExpenditure?: string;
        totalIncome?: string;
        totalRevenue?: string;
        transferred?: string;
        turnover?: string;
      }>;
    };
  };
  rocRegAddressInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    address1?: string;
    address2?: string;
    address3?: string;
    companyNo?: string;
    postcode?: string;
    state?: string;
    town?: string;
  };
}

export interface getInfoFinComparisonPhaseTwoV2 {
  clientRefNo?: string;
  requestRefNo?: string;
  orderRefNo?: string;
  generatedDate?: string;
  errorMsg?: string;
  infoId?: string;
  successCode?: string;
  rocBalanceSheetListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocBalanceSheetInfos?: {
      rocBalanceSheetInfos?: Array<{
        errorMsg?: string;
        infoId?: string;
        lastUpdateDate?: string;
        successCode?: string;
        accrualAccType?: string;
        auditFirmAddress1?: string;
        auditFirmAddress2?: string;
        auditFirmAddress3?: string;
        auditFirmName?: string;
        auditFirmNo?: string;
        auditFirmPostcode?: string;
        auditFirmState?: string;
        auditFirmTown?: string;
        auditfirmFlag?: string;
        branchkeycode?: string;
        companyNo?: string;
        contigentLiability?: string;
        currentAsset?: string;
        dateOfTabling?: string;
        financialReportType?: string;
        financialYearEndDate?: string;
        fixedAsset?: string;
        fundAndReserve?: string;
        fundReserve?: string;
        headOfficeAccount?: string;
        inappropriateProfit?: string;
        liability?: string;
        longTermLiability?: string;
        minorityInterest?: string;
        nonCurrAsset?: string;
        nonCurrentLiability?: string;
        otherAsset?: string;
        paidUpCapital?: string;
        reserves?: string;
        shareAppAccount?: string;
        sharePremium?: string;
        totalInvestment?: string;
      }>;
    };
  };
  rocBusinessAddressInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    address1?: string;
    address2?: string;
    address3?: string;
    companyNo?: string;
    postcode?: string;
    state?: string;
    town?: string;
  };
  rocCompanyInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    balaceSheetInfo?: string;
    balaceSheetInfoDesc?: string;
    businessDescription?: string;
    checkDigit?: string;
    companyCountry?: string;
    companyName?: string;
    companyNo?: string;
    companyOldName?: string;
    companyStatus?: string;
    companyType?: string;
    newFormatRegNo?: string;
    currency?: string;
    dateOfChange?: string;
    incomeStatInfo?: string;
    incomeStatInfoDesc?: string;
    incorpDate?: string;
    infoColon?: string;
    latestDocUpdateDate?: string;
    llpInfo?: string;
    llpInfoDesc?: string;
    llpName?: string;
    llpNo?: string;
    llpconvertDate?: string;
    localforeignCompany?: string;
    naBal?: string;
    naProf?: string;
    statusOfCompany?: string;
    wupType?: string;
  };
  rocDocumentLodgeListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocDocumentLodgeInfos?: {
      rocDocumentLodgeInfos?: Array<{
        companyNo?: string;
        documentDate?: string;
        formTrx?: string;
      }>;
    };
  };
  rocProfitLossListInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    rocProfitLossInfos?: {
      rocProfitLossInfos?: Array<{
        errorMsg?: string;
        infoId?: string;
        lastUpdateDate?: string;
        successCode?: string;
        accrualAccount?: string;
        companyNo?: string;
        extraOrdinaryItem?: string;
        financialReportType?: string;
        financialYearEndDate?: string;
        grossDividendRate?: string;
        inappropriateProfitBf?: string;
        inappropriateProfitCf?: string;
        minorityInterest?: string;
        netDividend?: string;
        others?: string;
        priorAdjustment?: string;
        profitAfterTax?: string;
        profitBeforeTax?: string;
        profitShareholder?: string;
        revenue?: string;
        surplusAfterTax?: string;
        surplusBeforeTax?: string;
        surplusDeficitAfterTax?: string;
        surplusDeficitBeforeTax?: string;
        totalExpenditure?: string;
        totalIncome?: string;
        totalRevenue?: string;
        transferred?: string;
        turnover?: string;
      }>;
    };
  };
  rocRegAddressInfo?: {
    errorMsg?: string;
    infoId?: string;
    lastUpdateDate?: string;
    successCode?: string;
    address1?: string;
    address2?: string;
    address3?: string;
    companyNo?: string;
    postcode?: string;
    state?: string;
    town?: string;
  };
}

export interface getImageListPhaseTwo {
  clientRefNo?: string;
  requestRefNo?: string;
  orderRefNo?: string;
  generatedDate?: string;
  errorMsg?: string;
  infoId?: string;
  successCode?: string;
  documentInfos?: {
    documentInfos?: Array<{
      batchId?: string;
      comments?: string;
      companyNo?: string;
      dateFiler?: string;
      documentDate?: string;
      formType?: string;
      imageName?: string;
      receivedDate?: string;
      sourceData?: string;
      stateCode?: string;
      totalPage?: string;
      verId?: string;
    }>;
  };
}

export interface getImageDocumentPhaseTwo {
  clientRefNo?: string;
  requestRefNo?: string;
  orderRefNo?: string;
  generatedDate?: string;
  errorMsg?: string;
  infoId?: string;
  successCode?: string;
  docContent?: string;
}

export interface getStatusEntity {
  clientRefNo?: string;
  requestRefNo?: string;
  statusEntity?: {
    data?: {
      companyName?: string;
      companyNo?: string;
      oldCompanyNo?: string;
      entityType?: string;
      companyStatus?: string;
    };
  };
}

export interface getParticularsOfAdtFirmV2 {
  clientRefNo?: string;
  requestRefNo?: string;
  errorMsg?: string;
  successCode?: string;
  adtFirmProf?: {
    adtFirmName?: string;
    adtFirmNo?: string;
    commenceDt?: string;
    faxNo?: string;
    prinAddr1?: string;
    prinAddr2?: string;
    prinAddr3?: string;
    prinCountry?: string;
    prinPostcode?: string;
    prinState?: string;
    prinTown?: string;
    regDt?: string;
    telNo?: string;
  };
  adtPartners?: {
    adtPartners?: Array<{
      adtName?: string;
      adtNewIcNo?: string;
      adtOldIcNo?: string;
      adtPassportNo?: string;
      entryDt?: string;
      licenceNo?: string;
      partnerStatus?: string;
      resAddr1?: string;
      resAddr2?: string;
      resAddr3?: string;
      resCountry?: string;
      resPostcode?: string;
      resState?: string;
      resTown?: string;
    }>;
  };
  branchOffices?: {
    branchOffices?: Array<{
      branchAddr1?: string;
      branchAddr2?: string;
      branchAddr3?: string;
      branchCountry?: string;
      branchPostcode?: string;
      branchState?: string;
      branchTelNo?: string;
      branchTown?: string;
    }>;
  };
}

// ---- 200 response wrappers (one key named after the schema) --------------
/** POST /get-search-entity */
export interface GetSearchEntityResponse { getSearchEntity?: getSearchEntity; message?: string; }
/** POST /get-bizprofile-document */
export interface GetBizprofileDocumentResponse { getBizProfile?: getBizProfile; message?: string; }
/** POST /get-company-profile-document */
export interface GetCompanyProfileDocumentResponse { getCompProfile?: getCompProfile; message?: string; }
/** POST /get-company-roc-business-officers */
export interface GetCompanyRocBusinessOfficersResponse { getRocBusinessOfficers?: getRocBusinessOfficers; message?: string; }
/** POST /get-company-sharecapital-particular */
export interface GetCompanySharecapitalParticularResponse { getDetailsOfShareCapital?: getDetailsOfShareCapital; message?: string; }
/** POST /get-company-shareholder-particular */
export interface GetCompanyShareholderParticularResponse { getDetailsOfShareholders?: getDetailsOfShareholders; message?: string; }
/** POST /get-company-roc-changes-registered-address */
export interface GetCompanyRocChangesRegisteredAddressResponse { getRocChangesRegisteredAddress?: getRocChangesRegisteredAddress; message?: string; }
/** POST /get-company-cosec-particular */
export interface GetCompanyCosecParticularResponse { getParticularsOfCosec?: getParticularsOfCosec; message?: string; }
/** POST /get-company-charges */
export interface GetCompanyChargesResponse { getInfoCharges?: getInfoCharges; message?: string; }
/** POST /get-auditfirm-particular */
export interface GetAuditfirmParticularResponse { getParticularsOfAdtFirm?: getParticularsOfAdtFirm; message?: string; }
/** POST /get-llp-current-profile */
export interface GetLlpCurrentProfileResponse { getLlpCurrentProfile?: getLlpCurrentProfile; message?: string; }
/** POST /get-image-view */
export interface GetImageViewResponse { getImageView?: getImageView; message?: string; }
/** POST /get-image */
export interface GetImageResponse { getImage?: getImage; message?: string; }

/** Path → request/response types, for a typed client: `call<'/get-search-entity'>(...)`. */
export interface SsmEndpointMap {
  "/get-search-entity": { request: GetSearchEntityRequest; response: GetSearchEntityResponse };
  "/get-bizprofile-document": { request: GetBizprofileDocumentRequest; response: GetBizprofileDocumentResponse };
  "/get-company-profile-document": { request: GetCompanyProfileDocumentRequest; response: GetCompanyProfileDocumentResponse };
  "/get-company-roc-business-officers": { request: GetCompanyRocBusinessOfficersRequest; response: GetCompanyRocBusinessOfficersResponse };
  "/get-company-sharecapital-particular": { request: GetCompanySharecapitalParticularRequest; response: GetCompanySharecapitalParticularResponse };
  "/get-company-shareholder-particular": { request: GetCompanyShareholderParticularRequest; response: GetCompanyShareholderParticularResponse };
  "/get-company-roc-changes-registered-address": { request: GetCompanyRocChangesRegisteredAddressRequest; response: GetCompanyRocChangesRegisteredAddressResponse };
  "/get-company-cosec-particular": { request: GetCompanyCosecParticularRequest; response: GetCompanyCosecParticularResponse };
  "/get-company-charges": { request: GetCompanyChargesRequest; response: GetCompanyChargesResponse };
  "/get-auditfirm-particular": { request: GetAuditfirmParticularRequest; response: GetAuditfirmParticularResponse };
  "/get-llp-current-profile": { request: GetLlpCurrentProfileRequest; response: GetLlpCurrentProfileResponse };
  "/get-image-view": { request: GetImageViewRequest; response: GetImageViewResponse };
  "/get-image": { request: GetImageRequest; response: GetImageResponse };
}
