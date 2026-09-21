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
  // The four shapes a promotion can take (0548): a trial period, a
  // giveaway, a percentage off, a fixed price. The set is the check
  // constraint on `module_promotions.kind` -- it cannot grow without a
  // migration, and a migration that added a fifth would have to come
  // here anyway. The module and the company beside it are pickers:
  // both of those lists grow.
  'features/admin/promotions_admin.dart': 1,
  // 0614. Where a kind of scanned document goes. The list is a `const`
  // in `scan_kinds_repository.dart` -- six screens this app knows how
  // to open -- so it cannot grow without somebody editing Dart, and a
  // seventh would arrive beside a screen to open.
  'features/admin/scan_kinds_admin.dart': 1,
  // Four since the paste path. The fourth is which amount column comes
  // first in a pasted contribution table — two options, and the whole
  // difference between them has to be readable at a glance, because
  // getting it wrong deducts the employer's share from every employee.
  // A list of two is not a list that grows.
  'features/admin/statutory_rates_admin.dart': 4,
  'features/approvals/rule_editor.dart': 4,
  // The entity type a business chooses at REGISTRATION. This was
  // frozen here on the grounds that `app.entity_type` was an enum and
  // a ninth member would arrive by migration -- which stopped being
  // true at `0605`, when the list became a table a platform
  // administrator adds to, and stopped being true for COMPANIES at
  // `0607`, which is when this comment was rewritten.
  //
  // It stays a dropdown, and the reason is now about the list rather
  // than about the schema: there are ten kinds of business in Malaysia
  // that anybody registers under, an eleventh is a rare event handled
  // by one person in a console, and nobody has ever needed to SEARCH
  // for "Sdn Bhd". If that list ever reaches the size where somebody
  // would, this entry comes off and a `SearchablePicker` goes in.
  'features/auth/sign_in_screen.dart': 1,
  // Two on Form B, and both are fixed sets rather than growing ones.
  //
  // The KIND of other income is the Act's list -- employment, rent,
  // interest, a share of a partnership -- eight of them, closed, and
  // shown all at once so somebody can see there is no ninth.
  //
  // The RELIEF is `0025`'s catalogue, a dozen rows that move with a
  // Budget and not with anything a user does. It also carries a
  // "Something else" entry, because a Form B can claim reliefs PCB
  // does not model -- so the list is fixed and the escape hatch is a
  // text field rather than a search.
  'features/financials/form_b_screen.dart': 2,
  // The Schedule 3 class on a fixed asset. A statutory set of eight,
  // fixed by the Act and moved by a Budget rather than by anybody
  // using this app -- there is no "add a class" and there must not be,
  // since a company that could invent a capital allowance class could
  // invent a rate. It shows all eight at once with their rates beside
  // them, which is exactly the comparison somebody choosing one is
  // making, and there is nothing to search.
  'features/assets/asset_editor.dart': 1,
  'features/banking/new_bank_account_dialog.dart': 1,
  'features/collections/log_attempt_sheet.dart': 2,
  'features/contacts/contact_editor.dart': 4,
  'features/contacts/contact_extras.dart': 1,
  // 0626. The public tax-details form, and both of its lists are fixed
  // by somebody other than us: LHDN's four identification types, which
  // are the check constraint on `contacts.id_type`, and the sixteen
  // Malaysian state codes -- which this screen does not even hold, it
  // draws them from `open_tax_detail_request` so there is one copy of
  // the statutory list and it is in the database. Neither grows without
  // a migration.
  'features/contacts/tax_details_page.dart': 2,
  'features/crm/leads_screen.dart': 1,
  'features/crm/pipeline_screen.dart': 1,
  'features/documents/repeat_dialog.dart': 1,
  // Two, since 0635: LHDN's eight modes for a company with no payment
  // methods of its own, and the company's own methods where it has
  // any. Both are fixed sets a person chooses from — a company has a
  // handful of methods, not a list it searches — and only one of the
  // two is ever built.
  'features/documents/settlement_dialog.dart': 2,
  'features/documents/share_dialog.dart': 1,
  'features/documents/withholding_dialog.dart': 1,
  // The eight MyInvois payment modes, fixed by LHDN. The bank account
  // and the charge account beside it are SearchablePickers, because a
  // chart of accounts grows and this one offers every expense account
  // in it.
  'features/settings/payment_methods_card.dart': 1,
  'features/expenses/expenses_screen.dart': 1,
  'features/feedback/feedback_screen.dart': 3,
  'features/financials/filing_details.dart': 3,
  'features/firms/practice_screen.dart': 2,
  'features/forecasting/forecast_settings_dialog.dart': 2,
  'features/hr/departure_dialog.dart': 1,
  'features/hr/employee_editor.dart': 1,
  'features/hr/employee_records.dart': 2,
  'features/hr/holidays_tab.dart': 1,
  // Three since 0608. The third is which box on the EA form a salary
  // component is reported in, and the list cannot grow without a
  // migration: it is `ea_categories`, which is the printed layout of
  // C.P.8A -- thirteen boxes, and a fourteenth would mean LHDN had
  // reissued the form. Twelve of them fit on a screen at once, and
  // nobody has ever wanted to SEARCH for "benefits in kind".
  'features/hr/hr_setup_screen.dart': 3,
  'features/hr/interviews_dialog.dart': 2,
  'features/hr/payroll_screen.dart': 2,
  'features/hr/tax_year_section.dart': 1,
  'features/items/items_screen.dart': 2,
  'features/ledger/recurring_screen.dart': 1,
  'features/legal/matter_detail_screen.dart': 3,
  'features/legal/matters_screen.dart': 1,
  // Two, and both are TRI-STATE on purpose. A practising certificate
  // and a firm's audit/non-audit classification each have a third
  // answer -- "the register did not say" -- which is not the same as
  // "no", and a row pasted without that column must not assert one.
  // Three fixed options is exactly what a dropdown is for; neither list
  // can grow without MIA changing its own register.
  'features/mia/mia_verify_dialog.dart': 2,
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
  // Three now: the account's kind, where it sits, and -- added with
  // `0665` -- how a tax computation treats it. The third is a fixed
  // statutory set read from `tax_treatments`, moved by a Budget rather
  // than by anybody using this app, and it is shown only on an expense
  // or revenue account because it can mean nothing on the others.
  // There is nothing to search: ten rows, each already a sentence.
  'features/settings/chart_of_accounts_card.dart': 3,
  'features/settings/company_card.dart': 2,
  'features/settings/document_numbering_card.dart': 1,
  'features/settings/landing_settings.dart': 1,
  'features/settings/new_account_dialog.dart': 2,
  // Two since 0615. The second is the e-Invoice VERSION — 1.0 or 1.1,
  // which is LHDN's list and not ours, and a third member would arrive
  // by gazette. The choice is between two things whose whole
  // difference has to be readable at a glance, which is what a
  // dropdown of two labelled options is for.
  'features/settings/settings_screen.dart': 2,
  // `0655`. One: which subtype a sub-account is filed as. A FIXED set
  // -- the subtypes of its parent's type, at most eight, straight out
  // of `accountSubtypes` -- and it cannot grow, because a new subtype
  // is an enum value in a migration. The TYPE itself is not asked at
  // all: a sub-account is always the same kind as its parent.
  'features/settings/sub_account_dialog.dart': 1,
  'features/settings/tax_code_dialog.dart': 2,
  // The four kinds of entity SSM registers: Company, Business, Audit
  // Firm, Limited Liability Partnership. Not a list that grows -- it is
  // `ssm_entity_types`, whose four rows are seeded by 0589 and are the
  // register's own classification, not ours. A fifth would arrive by
  // Act of Parliament and by migration, and a migration that added one
  // would have to come here anyway.
  // 0614. What AI SmartScan thinks the paper is. The same argument as
  // the kinds of business above, and for the same reason: the list is
  // a table a platform administrator adds to, there are nine of them,
  // and nobody has ever wanted to SEARCH for "Bank statement". If it
  // ever reaches the size where somebody would, this entry comes off
  // and a `SearchablePicker` goes in.
  'features/shared/scan_result_dialog.dart': 1,
  'features/shared/ssm_entity_picker.dart': 1,
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

  test('and every one of them ellipsises rather than overflowing', () {
    // `isExpanded` decides what a dropdown does when its widest item is
    // wider than the room it has. False -- the default -- lays the item
    // out at its natural width and the row overflows; true constrains
    // it and the text ellipsises.
    //
    // A debug build draws an overflow as a striped bar. A RELEASE WEB
    // build draws it as text running off the edge of the card, which
    // reads as a rendering fault rather than as a long word, and which
    // no test on a 1600px surface will ever see.
    //
    // Found on the entity-type dropdown: "Limited Liability
    // Partnership" ran 92 pixels past the sign-up column. Nineteen
    // others were one narrow screen away from the same thing, so this
    // is a rule now rather than a fix.
    final missing = <String>[];
    for (final entity in Directory('lib/src').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      for (final call in _dropdownCalls(source)) {
        if (RegExp(r'(^|[^\w.])isExpanded\s*:').hasMatch(call)) continue;
        final at =
            source.substring(0, source.indexOf(call)).split('\n').length;
        missing.add('${entity.path}:$at');
      }
    }

    expect(
      missing,
      isEmpty,
      reason:
          'These DropdownButtonFormFields do not set isExpanded: true, so '
          'a long item overflows instead of ellipsising:\n'
          '${missing.join('\n')}',
    );
  });
}

/// The text of each `DropdownButtonFormField(...)` call, balanced
/// parentheses and all.
///
/// Balanced rather than "the next few lines", because the argument
/// being looked for can be anywhere in the call and a nested widget's
/// own `isExpanded` must not be mistaken for it. Quotes are skipped so
/// a bracket inside a label does not unbalance the count.
List<String> _dropdownCalls(String source) {
  final out = <String>[];
  for (final m in RegExp(r'DropdownButtonFormField\s*(<[^>]*>)?\s*\(')
      .allMatches(source)) {
    var depth = 0;
    var i = m.end - 1;
    final start = i;
    while (i < source.length) {
      final c = source[i];
      if (c == '(' || c == '[' || c == '{') {
        depth++;
      } else if (c == ')' || c == ']' || c == '}') {
        depth--;
        if (depth == 0) break;
      } else if (c == "'" || c == '"') {
        final quote = c;
        i++;
        while (i < source.length && source[i] != quote) {
          if (source[i] == r'\') i++;
          i++;
        }
      }
      i++;
    }
    out.add(source.substring(start, i < source.length ? i + 1 : source.length));
  }
  return out;
}
