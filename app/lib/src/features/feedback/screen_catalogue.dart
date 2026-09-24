/// Where in the app something happened.
///
/// The report form used to ask for "the address in the bar, if you have
/// it", which is a question about the product's plumbing put to somebody
/// who has just hit a fault. On a phone there is no address bar at all.
/// Most reports arrived with the field empty, and a report with no
/// screen on it is one somebody has to write back about before anything
/// can be done.
///
/// So the form picks instead: module, then the part of it, then the
/// screen. Three short lists beat one blank box, and the answer that
/// comes back is a route we can open.
///
/// ## Keeping it true
///
/// Every route here is checked against `core/router.dart` by
/// `test/screen_catalogue_test.dart`. A screen that is renamed or
/// removed breaks that test rather than sitting in this list offering
/// people somewhere that no longer exists — which is the failure a
/// hand-written catalogue has, and the only reason it is tolerable to
/// have one.
///
/// The list is deliberately **not** filtered by what a company has
/// bought. Somebody reporting that a module they are *not* subscribed to
/// looked wrong on the pricing page is making a legitimate report, and a
/// picker that hid it would turn that into "Somewhere else".
library;

import '../../data/models.dart';
import '../documents/doc_types.dart';

class AppScreen {
  const AppScreen(this.label, this.route);

  final String label;
  final String route;

  @override
  String toString() => '$label ($route)';
}

class ScreenArea {
  const ScreenArea(this.label, this.screens);

  final String label;
  final List<AppScreen> screens;
}

class ScreenModule {
  const ScreenModule(this.label, this.areas);

  final String label;
  final List<ScreenArea> areas;
}

/// What a report can say it happened on, when it is none of these.
/// Always offered, and offered last: a form that cannot be finished
/// because the screen is missing from a list is worse than the blank box
/// it replaced.
const String kSomewhereElse = 'Somewhere else';

/// The document list screens, read out of `docTypes` rather than typed
/// out again. There are fourteen of them and they change; the router
/// builds their addresses from the same table, so this cannot drift
/// from what the app has even in principle.
///
/// `/sales` and `/purchases` on their own are not addresses — the route
/// is `/sales/:docType` — which is what the guard caught when this list
/// was first written by hand.
List<AppScreen> _documentScreens(DocKind kind) => [
  for (final e in docTypes.entries)
    if (e.value.kind == kind)
      AppScreen(
        e.value.plural,
        '${kind == DocKind.sales ? '/sales' : '/purchases'}/${e.key}',
      ),
];

final List<ScreenModule> appScreenCatalogue = [
  ScreenModule('Sales and customers', [
    ScreenArea('Documents', [
      ..._documentScreens(DocKind.sales),
      AppScreen('Receipts and payments', '/receipts'),
      AppScreen('Recurring invoices and bills', '/recurring-documents'),
      AppScreen('Deliveries', '/deliveries'),
      AppScreen('Deposits taken', '/deposits'),
    ]),
    ScreenArea('Customers', [
      AppScreen('All contacts', '/contacts'),
      AppScreen('Customers', '/customers'),
      AppScreen('Suppliers', '/suppliers'),
      AppScreen('Prospects', '/prospects'),
      AppScreen('Salespeople', '/salespeople'),
      AppScreen('Chasing what is owed', '/collections'),
    ]),
    ScreenArea('CRM', [
      AppScreen('Pipeline', '/crm'),
      AppScreen('Leads', '/crm/leads'),
    ]),
  ]),
  ScreenModule('Purchases and suppliers', [
    ScreenArea('Documents', [
      ..._documentScreens(DocKind.purchase),
      AppScreen('Expenses', '/expenses'),
      AppScreen('Landed cost', '/landed-cost'),
    ]),
    ScreenArea('Money out', [
      AppScreen('Post-dated cheques', '/cheques'),
      AppScreen('Contra', '/contra'),
      AppScreen('Withholding tax', '/withholding'),
    ]),
  ]),
  ScreenModule('Accounting', [
    ScreenArea('The ledger', [
      AppScreen('Chart of accounts', '/accounts'),
      AppScreen('Journals', '/journals'),
      AppScreen('Recurring journals', '/recurring'),
      AppScreen('Reports', '/reports'),
      AppScreen('Financial statements', '/financial-statements'),
      AppScreen('Budgets', '/budgets'),
      AppScreen('Cash flow', '/cash-flow'),
    ]),
    ScreenArea('Banking', [
      AppScreen('Bank statements', '/bank-statements'),
      AppScreen('Reconcile', '/reconcile'),
      AppScreen('Transfers between accounts', '/transfers'),
      AppScreen('Exchange rates', '/exchange-rates'),
    ]),
    ScreenArea('Between companies', [
      AppScreen('Intercompany', '/intercompany'),
    ]),
  ]),
  ScreenModule('Stock and assets', [
    ScreenArea('Stock', [
      AppScreen('Items', '/items'),
      AppScreen('Batches and serial numbers', '/lots'),
      AppScreen('Stock take', '/stock-take'),
      AppScreen('Bundles', '/bundles'),
      AppScreen('Recipes', '/recipes'),
    ]),
    ScreenArea('Planning', [
      AppScreen('Forecasting', '/forecasting'),
      AppScreen('Manufacturing', '/manufacturing'),
    ]),
    ScreenArea('Assets', [AppScreen('Fixed assets', '/assets')]),
  ]),
  ScreenModule('People and payroll', [
    ScreenArea('People', [
      AppScreen('Employees', '/hr/people'),
      AppScreen('Leave', '/hr/leave'),
      AppScreen('Claims', '/hr/claims'),
      AppScreen('Talent', '/hr/talent'),
      AppScreen('Onboarding', '/hr/onboarding'),
      AppScreen('My own details', '/hr/me'),
      AppScreen('HR setup', '/hr/setup'),
    ]),
    ScreenArea('Payroll', [
      AppScreen('Payroll runs', '/hr/payroll'),
      AppScreen('Statutory remittances', '/hr/remittances'),
      AppScreen('EA forms', '/hr/ea-forms'),
    ]),
    ScreenArea('Time', [AppScreen('Timesheets', '/timesheets')]),
  ]),
  ScreenModule('Point of sale', [
    ScreenArea('The till', [
      AppScreen('Register', '/till'),
      AppScreen('Kiosk', '/kiosk'),
      AppScreen('Order board', '/order-board'),
      AppScreen('Queue', '/queue'),
    ]),
    ScreenArea('Floor and kitchen', [
      AppScreen('Floor plan', '/floor'),
      AppScreen('Kitchen display', '/kitchen'),
      AppScreen('Counters', '/counters'),
      AppScreen('Diary', '/diary'),
      AppScreen('Stalls', '/stalls'),
    ]),
    ScreenArea('Menu and offers', [
      AppScreen('Menu times', '/menu-times'),
      AppScreen('Promotions', '/promotions'),
      AppScreen('Loyalty', '/loyalty'),
      AppScreen('Memberships', '/memberships'),
    ]),
    ScreenArea('End of day', [
      AppScreen('Takings', '/takings'),
      AppScreen('Voids and write-offs', '/voids'),
      AppScreen('POS reports', '/pos-reports'),
    ]),
  ]),
  ScreenModule('Compliance', [
    ScreenArea('LHDN', [
      AppScreen('e-Invoice', '/einvoice'),
      AppScreen('Received e-Invoices', '/einvoice/received'),
      AppScreen('Outgoing email', '/email'),
    ]),
    ScreenArea('SSM', [
      AppScreen('Company secretarial', '/secretarial'),
    ]),
    ScreenArea('Legal', [AppScreen('Matters', '/legal')]),
  ]),
  ScreenModule('Property', [
    ScreenArea('Managed property', [AppScreen('Property', '/property')]),
  ]),
  ScreenModule('Service desk', [
    ScreenArea('Tickets', [
      AppScreen('Tickets', '/tickets'),
      AppScreen('Inbox', '/inbox'),
    ]),
    ScreenArea('Messages', [AppScreen('Chat', '/chat')]),
  ]),
  ScreenModule('AI assistant', [
    ScreenArea('Asking', [AppScreen('Ask about your books', '/ask')]),
  ]),
  ScreenModule('Setup and administration', [
    ScreenArea('This company', [
      AppScreen('Settings', '/settings'),
      AppScreen('Team', '/team'),
      AppScreen('Import', '/import'),
      AppScreen('Approvals', '/approvals'),
      AppScreen('Dashboard', '/dashboard'),
    ]),
    ScreenArea('More than one company', [
      AppScreen('Practice portfolio', '/practice'),
      AppScreen('Add a company', '/companies/new'),
      AppScreen('One payment, several companies', '/receipts/group'),
    ]),
    ScreenArea('Account', [
      AppScreen('Security log', '/security'),
      AppScreen('Report a problem', '/feedback'),
    ]),
  ]),
];
