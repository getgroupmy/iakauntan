import '../data/models.dart';
import 'searchable_picker.dart';

/// The rows the pickers offer for the lists that have no "add one"
/// dialog of their own.
///
/// A contact, an item and a warehouse each keep their options helper
/// beside the dialog that creates them, because the two belong together.
/// These three do not: an account, a bank account and an employee are
/// set up on their own screens, with more asked for than a picker can
/// reasonably ask, so the picker searches and does not offer.

/// The chart of accounts.
///
/// THE LONGEST LIST IN THE PRODUCT and the one people know by NUMBER
/// rather than by name. The code is first in the label so a typed
/// "6100" lands on 6100 rather than on whatever merely mentions it —
/// `matchingOptions` sorts a label that STARTS with the query above one
/// that only contains it, and that only helps if the code leads.
///
/// [postableOnly] drops the group headings. A journal line cannot be
/// posted to a group account, so offering one is offering a refusal.
List<PickerOption<String>> accountPickerOptions(
  List<Account> accounts, {
  bool postableOnly = true,
}) => [
  for (final a in accounts)
    if (!postableOnly || !a.isGroup)
      PickerOption<String>(
        value: a.id,
        label: '${a.code} — ${a.name}',
        keywords: [a.code, a.name],
      ),
];

/// The company's own bank accounts, as `banks()` returns them.
///
/// A map rather than a model because that is what the repository hands
/// back, and inventing a class to carry two strings between a query and
/// a picker would be ceremony.
List<PickerOption<String>> bankPickerOptions(
  List<Map<String, dynamic>> banks,
) => [
  for (final b in banks)
    PickerOption<String>(
      value: '${b['id']}',
      label: '${b['name']}',
      sublabel: '${b['bank_name'] ?? ''}'.isEmpty
          ? null
          : '${b['bank_name']}',
      keywords: [
        '${b['account_number'] ?? ''}',
        '${b['bank_name'] ?? ''}',
      ],
    ),
];

/// Staff.
///
/// Findable by STAFF NUMBER as well as name, because a payroll clerk
/// works from a number and a manager works from a name. The department
/// is the second line where the query brought one back — two people
/// called Ahmad are told apart by the department far more often than by
/// the staff number.
List<PickerOption<String>> employeePickerOptions(List<Employee> staff) => [
  for (final e in staff)
    PickerOption<String>(
      value: e.id,
      label: e.fullName,
      sublabel: [
        e.employeeNo,
        if ((e.departmentName ?? '').isNotEmpty) e.departmentName!,
      ].where((p) => p.isNotEmpty).join(' · '),
      keywords: [e.employeeNo, e.departmentName ?? ''],
    ),
];
