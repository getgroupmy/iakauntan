import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every growing list is a search box, and every dropdown that is left
/// is a decision somebody made.
///
/// `SearchablePicker` replaces `DropdownButtonFormField` only where the
/// list GROWS — contacts, accounts, tax codes, projects, warehouses,
/// employees, categories. A dropdown of four statuses is the right
/// control for four statuses: it shows all of them at once, needs no
/// keystroke, and cannot be typed into wrongly.
///
/// The judgement is the whole of the work, and judgement does not
/// survive on its own. So the dropdowns that remain are FROZEN here, by
/// file and by count. Adding one fails this test by name; converting
/// one fails it too. Either way somebody has to come back to this list
/// and say which kind it is — which is the only thing that stops the
/// next screen quietly going back to a scrollbar of four hundred
/// customers.
///
/// This is a census, not a ban. To add a dropdown: satisfy yourself the
/// list is fixed — an enum, a statutory set, twelve months, five
/// approval steps — and put it on the list. If the list grows, use
/// `SearchablePicker` instead and take the entry off.
const dropdownCensus = <String, int>{
  'features/admin/landing_cms.dart': 2,
  'features/admin/payment_gateways_admin.dart': 1,
  'features/admin/reservations_admin.dart': 2,
  'features/admin/statutory_rates_admin.dart': 3,
  'features/approvals/rule_editor.dart': 4,
  'features/banking/new_bank_account_dialog.dart': 1,
  'features/collections/log_attempt_sheet.dart': 2,
  'features/contacts/contact_editor.dart': 4,
  'features/contacts/contact_extras.dart': 1,
  'features/crm/leads_screen.dart': 1,
  'features/crm/pipeline_screen.dart': 1,
  'features/documents/repeat_dialog.dart': 1,
  'features/documents/settlement_dialog.dart': 1,
  'features/documents/share_dialog.dart': 1,
  'features/documents/withholding_dialog.dart': 1,
  'features/expenses/expenses_screen.dart': 1,
  'features/feedback/feedback_screen.dart': 3,
  'features/financials/filing_details.dart': 3,
  'features/firms/practice_screen.dart': 2,
  'features/forecasting/forecast_settings_dialog.dart': 2,
  'features/hr/departure_dialog.dart': 1,
  'features/hr/employee_editor.dart': 1,
  'features/hr/employee_records.dart': 2,
  'features/hr/holidays_tab.dart': 1,
  'features/hr/hr_setup_screen.dart': 2,
  'features/hr/interviews_dialog.dart': 2,
  'features/hr/payroll_screen.dart': 2,
  'features/hr/tax_year_section.dart': 1,
  'features/items/items_screen.dart': 2,
  'features/ledger/recurring_screen.dart': 1,
  'features/legal/matter_detail_screen.dart': 3,
  'features/legal/matters_screen.dart': 1,
  'features/onboarding/create_org_screen.dart': 3,
  'features/pos/pos_reports_screen.dart': 1,
  'features/pos/scales_screen.dart': 1,
  'features/property/site_editor.dart': 1,
  'features/property/statutory_charge_sheet.dart': 2,
  'features/property/strata_sheet.dart': 1,
  'features/property/tenancy_sheet.dart': 1,
  'features/property/unit_sheet.dart': 1,
  'features/reports/budget_line_editor.dart': 1,
  'features/reports/budgets_screen.dart': 2,
  'features/reports/cash_forecast_screen.dart': 1,
  'features/secretarial/charge_sheet.dart': 1,
  'features/secretarial/entity_editor.dart': 1,
  'features/secretarial/officer_sheet.dart': 1,
  'features/secretarial/person_editor.dart': 2,
  'features/secretarial/resolution_sheet.dart': 1,
  'features/secretarial/share_event_sheet.dart': 1,
  'features/settings/chart_of_accounts_card.dart': 2,
  'features/settings/company_card.dart': 2,
  'features/settings/document_numbering_card.dart': 1,
  'features/settings/landing_settings.dart': 1,
  'features/settings/new_account_dialog.dart': 2,
  'features/settings/settings_screen.dart': 1,
  'features/settings/tax_code_dialog.dart': 2,
  'features/stock/landed_cost_screen.dart': 1,
  'features/team/team_screen.dart': 1,
  'features/ticketing/ticket_editor.dart': 1,
  'features/ticketing/ticket_routing_sheet.dart': 1,
  'features/ticketing/ticket_share_dialog.dart': 1,
  'features/timesheets/time_entry_sheet.dart': 1,
};

/// Counts real uses of the widget, not the word.
///
/// A line-comment mention does not build anything, and
/// `core/searchable_picker.dart` names the control it replaces in its
/// own doc comment — counting that would put the replacement on the
/// list of things to replace.
int dropdownsIn(String source) {
  final pattern = RegExp(r'DropdownButtonFormField\s*[<(]');
  var found = 0;
  for (final line in source.split('\n')) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('//')) continue;
    found += pattern.allMatches(line).length;
  }
  return found;
}

void main() {
  test('the word alone is not a dropdown', () {
    expect(dropdownsIn('/// replaces DropdownButtonFormField, and'), 0);
    expect(dropdownsIn('  // DropdownButtonFormField<String>('), 0);
    expect(dropdownsIn('  child: DropdownButtonFormField<String>('), 1);
    expect(dropdownsIn('  child: DropdownButtonFormField('), 1);
  });

  test('the dropdowns that are left are the ones on the list', () {
    final root = Directory('lib/src');
    final actual = <String, int>{};
    for (final entity in root.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final found = dropdownsIn(entity.readAsStringSync());
      if (found == 0) continue;
      actual[entity.path.substring('lib/src/'.length)] = found;
    }

    final added = <String>[];
    final gone = <String>[];
    for (final entry in actual.entries) {
      final expected = dropdownCensus[entry.key];
      if (expected == null) {
        added.add('${entry.key}: ${entry.value} new');
      } else if (expected != entry.value) {
        added.add('${entry.key}: $expected on the list, ${entry.value} found');
      }
    }
    for (final key in dropdownCensus.keys) {
      if (!actual.containsKey(key)) gone.add(key);
    }

    expect(
      [...added, ...gone],
      isEmpty,
      reason:
          'A dropdown appeared or disappeared without the census moving.\n'
          'Added or changed: ${added.join(', ')}\n'
          'Gone from the file: ${gone.join(', ')}\n'
          'If the list behind it GROWS — contacts, accounts, tax codes, '
          'projects, warehouses, employees, categories — it should be a '
          'SearchablePicker with an offer to add what is missing. If it '
          'is a fixed set, put it on the census in '
          'test/dropdown_census_test.dart and say so.',
    );
  });
}
