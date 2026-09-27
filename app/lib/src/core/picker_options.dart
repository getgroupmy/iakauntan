import '../data/corp_models.dart';
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

/// The matters a firm is working on.
///
/// `0687`/`0688` put the matter on `gl_lines`, so a bill, an expense or
/// a journal line can now say which matter it belongs to. This is the
/// list that says it.
///
/// Findable by MATTER NUMBER as well as by name, for the same reason
/// the chart of accounts leads with its code: a file is referred to by
/// its number on every letter and every attendance note, and somebody
/// typing "M-1042" means that matter and not whichever one merely
/// mentions it. The number leads the label so `matchingOptions` ranks a
/// label that STARTS with the query above one that only contains it.
///
/// The client is the second line, because two matters called "Sale of
/// a house" are ordinary and the client is what tells them apart.
List<PickerOption<String>> matterPickerOptions(List<Matter> matters) => [
  for (final m in matters)
    PickerOption<String>(
      value: m.id,
      label: '${m.matterNo} — ${m.name}',
      sublabel: (m.clientName ?? '').isEmpty ? null : m.clientName,
      keywords: [m.matterNo, m.name, m.clientName ?? ''],
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

/// The people on a company's corporate registers.
///
/// `corp_persons` is one record used as officer, member and beneficial
/// owner alike, so one options helper serves all three registers.
/// The IDENTIFIER — an NRIC, a passport number, a company registration
/// number — is the second line and a search key, because that is what
/// tells two people with the same name apart, and telling them apart is
/// the whole point of a statutory register.
List<PickerOption<String>> corpPersonPickerOptions(
  List<CorpPerson> people,
) => [
  for (final p in people)
    PickerOption<String>(
      value: p.id,
      label: p.fullName,
      sublabel: p.identifier,
      keywords: [p.identifier ?? ''],
    ),
];
