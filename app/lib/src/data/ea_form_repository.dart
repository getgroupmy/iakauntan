import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/providers.dart';
import 'repository.dart';

double _num(Object? v) =>
    v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;

/// One box on the EA form, with what landed in it.
///
/// `0608` made the boxes a table: the C.P.8A has been renumbered before
/// and a `case` expression over its section numbers would need a
/// migration the next time it is.
class EaBox {
  const EaBox({
    required this.code,
    required this.part,
    required this.box,
    required this.label,
    required this.amount,
    this.isExempt = false,
  });

  final String code;

  /// 'B' remuneration, 'C' pension and others, 'F' the exempt list.
  final String part;

  /// The number printed beside the box, as printed: `1(a)`, `2`, `5`.
  final String box;
  final String label;
  final double amount;
  final bool isExempt;

  /// What to print at the left of the row.
  String get heading => '$part $box  $label';

  factory EaBox.fromJson(Map<String, dynamic> j) => EaBox(
    code: '${j['code'] ?? ''}',
    part: '${j['part'] ?? ''}',
    box: '${j['box'] ?? ''}',
    label: '${j['label'] ?? ''}',
    amount: _num(j['amount']),
    isExempt: j['is_exempt'] == true,
  );
}

/// What a previous employer paid somebody who joined part-way through
/// the year.
///
/// On the statement and in none of its totals. That employer issues
/// their own EA form for the same year; an employee handed two that
/// both include the first job declares that salary twice. Carried here
/// so the screen can say it was left out on purpose.
class EaPreviousEmployer {
  const EaPreviousEmployer({
    required this.grossPay,
    required this.epfEmployee,
    required this.pcbPaid,
    required this.zakatPaid,
    required this.benefitsInKind,
    this.notes,
  });

  final double grossPay;
  final double epfEmployee;
  final double pcbPaid;
  final double zakatPaid;
  final double benefitsInKind;
  final String? notes;

  factory EaPreviousEmployer.fromJson(Map<String, dynamic> j) =>
      EaPreviousEmployer(
        grossPay: _num(j['gross_pay']),
        epfEmployee: _num(j['epf_employee']),
        pcbPaid: _num(j['pcb_paid']),
        zakatPaid: _num(j['zakat_paid']),
        benefitsInKind: _num(j['benefits_in_kind']),
        notes: (j['notes'] as String?)?.trim().isEmpty ?? true
            ? null
            : '${j['notes']}'.trim(),
      );
}

/// One employee's EA form (C.P.8A) for one year of assessment.
class EaStatement {
  const EaStatement({
    required this.taxYear,
    required this.employerName,
    required this.employeeName,
    required this.boxes,
    required this.grossPay,
    required this.mtd,
    required this.cp38,
    required this.zakat,
    required this.epfEmployee,
    required this.epfEmployer,
    required this.socsoEmployee,
    required this.eisEmployee,
    required this.monthsPaid,
    this.employerTaxNo,
    this.employerEpfNo,
    this.employerSocsoNo,
    this.employerAddress,
    this.employeeNo,
    this.nric,
    this.passportNo,
    this.incomeTaxNo,
    this.employeeEpfNo,
    this.employeeSocsoNo,
    this.employedFrom,
    this.employedTo,
    this.previousEmployer,
  });

  final int taxYear;

  final String employerName;
  final String? employerTaxNo;
  final String? employerEpfNo;
  final String? employerSocsoNo;
  final String? employerAddress;

  final String employeeName;
  final String? employeeNo;
  final String? nric;
  final String? passportNo;
  final String? incomeTaxNo;
  final String? employeeEpfNo;
  final String? employeeSocsoNo;
  final DateTime? employedFrom;
  final DateTime? employedTo;

  final List<EaBox> boxes;
  final double grossPay;

  final double mtd;
  final double cp38;
  final double zakat;

  final double epfEmployee;
  final double epfEmployer;
  final double socsoEmployee;
  final double eisEmployee;

  final int monthsPaid;

  /// Null where they had no earlier job this year — not a block of
  /// zeroes, which on a printed form reads as "declared, nil" rather
  /// than "not applicable".
  final EaPreviousEmployer? previousEmployer;

  /// The boxes that are remuneration, which is Part B and Part C.
  List<EaBox> get chargeable =>
      [for (final b in boxes) if (!b.isExempt) b];

  /// The exempt allowances, reported separately because they are not
  /// taxed and an employee who adds them into their income pays tax on
  /// money the law says they should not.
  List<EaBox> get exempt => [for (final b in boxes) if (b.isExempt) b];

  double get totalChargeable =>
      chargeable.fold<double>(0, (sum, b) => sum + b.amount);

  double get totalDeductions => mtd + cp38 + zakat;

  /// What the form is missing to be worth handing out. The same three
  /// `ea_statements` names, said again here so a single statement
  /// opened on its own can say them too.
  List<String> get missing => [
    if ((incomeTaxNo ?? '').trim().isEmpty) 'income tax number',
    if ((nric ?? '').trim().isEmpty && (passportNo ?? '').trim().isEmpty)
      'NRIC or passport',
    if ((employeeEpfNo ?? '').trim().isEmpty && epfEmployee > 0) 'EPF number',
  ];

  static DateTime? _date(Object? v) =>
      v == null ? null : DateTime.tryParse('$v');

  factory EaStatement.fromJson(Map<String, dynamic> j) {
    final employer = Map<String, dynamic>.from(
      (j['employer'] as Map?) ?? const {},
    );
    final employee = Map<String, dynamic>.from(
      (j['employee'] as Map?) ?? const {},
    );
    final deductions = Map<String, dynamic>.from(
      (j['deductions'] as Map?) ?? const {},
    );
    final contributions = Map<String, dynamic>.from(
      (j['contributions'] as Map?) ?? const {},
    );
    final previous = j['previous_employer'];

    String? text(Object? v) =>
        v == null || '$v'.trim().isEmpty ? null : '$v'.trim();

    return EaStatement(
      taxYear: (j['tax_year'] as num?)?.toInt() ?? 0,
      employerName: '${employer['name'] ?? ''}',
      employerTaxNo: text(employer['employer_tax_no']),
      employerEpfNo: text(employer['epf_no']),
      employerSocsoNo: text(employer['socso_no']),
      employerAddress: text(employer['address']),
      employeeName: '${employee['name'] ?? ''}',
      employeeNo: text(employee['employee_no']),
      nric: text(employee['nric']),
      passportNo: text(employee['passport_no']),
      incomeTaxNo: text(employee['income_tax_no']),
      employeeEpfNo: text(employee['epf_no']),
      employeeSocsoNo: text(employee['socso_no']),
      employedFrom: _date(employee['employed_from']),
      employedTo: _date(employee['employed_to']),
      boxes: [
        for (final b in (j['boxes'] as List? ?? const []))
          EaBox.fromJson(Map<String, dynamic>.from(b as Map)),
      ],
      grossPay: _num(j['gross_pay']),
      mtd: _num(deductions['mtd']),
      cp38: _num(deductions['cp38']),
      zakat: _num(deductions['zakat']),
      epfEmployee: _num(contributions['epf_employee']),
      epfEmployer: _num(contributions['epf_employer']),
      socsoEmployee: _num(contributions['socso_employee']),
      eisEmployee: _num(contributions['eis_employee']),
      monthsPaid: (j['months_paid'] as num?)?.toInt() ?? 0,
      previousEmployer: previous == null
          ? null
          : EaPreviousEmployer.fromJson(
              Map<String, dynamic>.from(previous as Map),
            ),
    );
  }
}

/// One line on the list of who is owed a form.
class EaSummary {
  const EaSummary({
    required this.employeeId,
    required this.name,
    required this.monthsPaid,
    required this.grossPay,
    required this.mtd,
    required this.cp38,
    required this.missing,
    this.employeeNo,
    this.incomeTaxNo,
    this.employmentStatus,
    this.hasPreviousEmployer = false,
  });

  final String employeeId;
  final String? employeeNo;
  final String name;
  final String? incomeTaxNo;
  final String? employmentStatus;
  final int monthsPaid;
  final double grossPay;
  final double mtd;
  final double cp38;
  final bool hasPreviousEmployer;

  /// What would make the form wrong to hand out, named by the database
  /// rather than found by LHDN.
  final List<String> missing;

  bool get isReady => missing.isEmpty;

  factory EaSummary.fromJson(Map<String, dynamic> j) => EaSummary(
    employeeId: '${j['employee_id'] ?? ''}',
    employeeNo: (j['employee_no'] as String?)?.trim(),
    name: '${j['name'] ?? ''}',
    incomeTaxNo: (j['income_tax_no'] as String?)?.trim(),
    employmentStatus: (j['employment_status'] as String?)?.trim(),
    monthsPaid: (j['months_paid'] as num?)?.toInt() ?? 0,
    grossPay: _num(j['gross_pay']),
    mtd: _num(j['mtd']),
    cp38: _num(j['cp38']),
    hasPreviousEmployer: j['has_previous_employer'] == true,
    missing: [
      for (final m in (j['missing'] as List? ?? const [])) '$m',
    ],
  );
}

/// The EA forms an employer owes for a year of assessment.
class EaFormsRepo {
  const EaFormsRepo(this.client, this.orgId);

  final SupabaseClient client;
  final String orgId;

  Future<List<EaSummary>> forYear(int taxYear) async => Repo.rows(
    await client.rpc(
      'ea_statements',
      params: {'p_org_id': orgId, 'p_tax_year': taxYear},
    ),
  ).map(EaSummary.fromJson).toList();

  Future<EaStatement> statement(String employeeId, int taxYear) async {
    final data = await client.rpc(
      'ea_statement',
      params: {'p_employee_id': employeeId, 'p_tax_year': taxYear},
    );
    return EaStatement.fromJson(Map<String, dynamic>.from(data as Map));
  }
}

final eaFormsRepoProvider = Provider<EaFormsRepo?>((ref) {
  final org = ref.watch(orgIdProvider);
  if (org == null) return null;
  return EaFormsRepo(ref.watch(supabaseProvider), org);
});

/// Who is owed an EA form for a year, and what each comes to.
final eaFormsProvider = FutureProvider.family<List<EaSummary>, int>((
  ref,
  taxYear,
) async {
  final repo = ref.watch(eaFormsRepoProvider);
  if (repo == null) return const [];
  return repo.forYear(taxYear);
});

// There is no provider for a single statement, deliberately. Both
// callers -- the employer's list and the employee's own card -- want
// bytes on disk rather than a widget bound to a figure, so they call
// `EaFormsRepo.statement` and hand the result straight to the PDF. A
// provider would be a cache nobody reads twice.

/// The boxes themselves, for the screen that lets an employer say which
/// one a salary component belongs in.
final eaCategoriesProvider = FutureProvider<List<EaBox>>((ref) async {
  final rows = Repo.rows(
    await ref
        .watch(supabaseProvider)
        .from('ea_categories')
        .select('code, part, box, label, is_exempt, sort_order')
        .eq('is_active', true)
        // Said out loud, because supabase-js defaults ascending to true
        // and postgrest-dart defaults it to false.
        .order('sort_order', ascending: true),
  );
  return rows.map(EaBox.fromJson).toList();
});
