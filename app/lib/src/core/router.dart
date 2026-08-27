import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/reset_password_screen.dart';
import '../features/auth/sign_in_screen.dart';
import '../features/landing/landing_screen.dart';
import '../features/chat/chat_screen.dart';
import '../features/contacts/contact_editor.dart';
import '../features/contacts/contacts_screen.dart';
import '../features/crm/leads_screen.dart';
import '../features/crm/pipeline_screen.dart';
import '../features/admin/platform_console_screen.dart';
import '../features/mail/inbox_screen.dart';
import '../features/assets/assets_screen.dart';
import '../features/banking/reconciliation_screen.dart';
import '../features/stock/lots_screen.dart';
import '../features/stock/stock_take_screen.dart';
import '../features/documents/cheques_screen.dart';
import '../features/documents/contra_screen.dart';
import '../features/documents/deposits_screen.dart';
import '../features/reports/budgets_screen.dart';
import '../features/reports/cash_forecast_screen.dart';
import '../features/stock/bundles_screen.dart';
import '../features/stock/landed_cost_screen.dart';
import '../features/stock/transfers_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/documents/document_editor.dart';
import '../features/documents/exchange_rates_screen.dart';
import '../features/documents/intercompany_screen.dart';
import '../features/documents/receipts_screen.dart';
import '../features/documents/salespeople_screen.dart';
import '../features/documents/document_list_screen.dart';
import '../features/einvoice/einvoice_screen.dart';
import '../features/expenses/expenses_screen.dart';
import '../features/items/items_screen.dart';
import '../features/legal/matter_detail_screen.dart';
import '../features/legal/matters_screen.dart';
import '../features/manufacturing/manufacturing_screen.dart';
import '../features/approvals/approvals_screen.dart';
import '../features/collections/collections_screen.dart';
import '../features/financials/filing_screen.dart';
import '../features/financials/filings_screen.dart';
import '../features/timesheets/timesheet_screen.dart';
import '../features/property/property_screen.dart';
import '../features/property/site_editor.dart';
import '../features/forecasting/forecast_screen.dart';
import '../features/pos/diary_screen.dart';
import '../features/pos/memberships_screen.dart';
import '../features/pos/menu_times_screen.dart';
import '../features/pos/pos_reports_screen.dart';
import '../features/pos/promotions_screen.dart';
import '../features/pos/recipes_screen.dart';
import '../features/pos/stalls_screen.dart';
import '../features/pos/deliveries_screen.dart';
import '../features/pos/public_menu_page.dart';
import '../features/pos/queue_screen.dart';
import '../features/pos/voids_screen.dart';
import '../features/loyalty/loyalty_screen.dart';
import '../features/pos/floor_plan_screen.dart';
import '../features/pos/kiosk_board_screen.dart';
import '../features/pos/kiosk_screen.dart';
import '../features/pos/kitchen_screen.dart';
import '../features/pos/stations_screen.dart';
import '../features/pos/takings_screen.dart';
import '../features/pos/till_screen.dart';
import '../features/ticketing/ticket_editor.dart';
import '../features/ticketing/ticket_screen.dart';
import '../features/ticketing/tickets_screen.dart';
import '../features/property/site_screen.dart';
import '../features/manufacturing/order_screen.dart';
import '../features/onboarding/create_org_screen.dart';
import '../features/ledger/journals_screen.dart';
import '../features/documents/recurring_documents_screen.dart';
import '../features/documents/withholding_screen.dart';
import '../features/imports/import_screen.dart';
import '../features/ledger/recurring_screen.dart';
import '../features/reports/group_reports_screen.dart';
import '../features/reports/reports_screen.dart';
import '../features/secretarial/entity_editor.dart';
import '../features/documents/shared_document_page.dart';
import '../features/settings/email_screen.dart';
import '../features/secretarial/signing_page.dart';
import '../features/secretarial/entity_screen.dart';
import '../features/secretarial/secretarial_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/hr/claims_screen.dart';
import '../features/hr/employee_editor.dart';
import '../features/hr/hr_setup_screen.dart';
import '../features/hr/onboarding_screen.dart';
import '../features/hr/leave_screen.dart';
import '../features/hr/my_hr_screen.dart';
import '../features/hr/payroll_screen.dart';
import '../features/hr/payslip_screen.dart';
import '../features/hr/people_screen.dart';
import '../features/hr/talent_screen.dart';
import '../features/team/security_screen.dart';
import '../features/team/team_screen.dart';
import '../features/shell/app_shell.dart';
import '../data/reserved_names_repository.dart';
import 'providers.dart';

final _rootKey = GlobalKey<NavigatorState>();
final _shellKey = GlobalKey<NavigatorState>();

/// Where a visitor at [path] belongs, given what is known about them.
///
/// Pulled out of the router as a plain function so it can be asserted.
/// This is the one rule in the app whose mistakes are unrecoverable from
/// the outside: a redirect that returns a path which redirects back is
/// not a wrong screen, it is a product that will not open, and nothing
/// about the code says so — the loop only appears in a browser, on the
/// address everybody uses.
///
/// Null means "stay". [hasOrg] and [isPlatformAdmin] are null while
/// their answers are still loading or have failed, which are the same
/// instruction: hold this route and decide when the answer arrives.
///
/// [atCompanyDoor] is true at `sinar.iakauntan.com` — a company's own
/// address, rather than the platform's. The bare domain's front page is
/// a shopfront for the product, and a company that paid for its own
/// address did not buy one; somebody arriving there wants the sign-in
/// form. It only moves `/`, so every other route is unaffected and a
/// signed-in visitor is not bounced anywhere.
String? routeFor({
  required String path,
  required bool signedIn,
  required bool recovering,
  required bool? hasOrg,
  required bool? isPlatformAdmin,
  bool atCompanyDoor = false,
}) {
  // The signing page is the one route that works with no account at
  // all: a director will not sign up to an accounting system to sign
  // one resolution. It authorises itself against the token.
  if (path.startsWith('/sign/')) return null;
  // The other page that works with no account: a customer opening a
  // link to their own invoice.
  if (path.startsWith('/share/')) return null;
  // And the third: somebody at a table with a phone and a QR sticker.
  // 0262's functions authorise themselves against the token, and a
  // customer will not sign up to an accounting system to order a teh
  // tarik.
  if (path.startsWith('/menu/')) return null;

  // And the fourth, which is not about a token at all: the corporate
  // landing page, which is now the address itself. Somebody who typed
  // what is on the business card has not come to sign in — they have
  // come to find out what this is — and that is as true of a customer
  // with a session already as of a stranger. So `/` is the front page
  // for everybody, and the books are at `/dashboard`, one tap away
  // behind the same button a stranger uses.
  //
  // It used to send a signed-in visitor from `/welcome` to their books,
  // which meant the product had no front page at all for anybody who
  // had ever logged in — including the person who owns it and is trying
  // to look at what they have just published.
  //
  // Unless this is a company's own address. `sinar.iakauntan.com` is
  // not a shopfront — a stranger who typed it was looking for Sinar,
  // not for what iAkauntan is — so its `/` is the sign-in form. Only
  // `/`: a signed-in visitor on any other route is left alone.
  if (path == '/') return atCompanyDoor ? '/signin' : null;
  // Kept because it was the address for a while and links to it exist.
  // One redirect, not a second copy of the page.
  if (path == '/welcome') return '/';

  // Signed out, and where that lands depends on whose address this is.
  //
  // At the bare domain it is the front page: somebody who has just
  // signed out of the product may well want to read about it, and that
  // is the page the button on it goes back to.
  //
  // At a company's own address it is the sign-in form. Signing out of
  // Sinar should leave you at Sinar's door, not at a shopfront for the
  // accounting system Sinar happens to use.
  //
  // Said in one hop rather than leaving `/` to redirect on again. The
  // chain did resolve, but it made the answer to "where does signing
  // out go" depend on a second rule further up the function, and this
  // is the rule that is asserted.
  if (!signedIn) {
    if (path == '/signin') return null;
    return atCompanyDoor ? '/signin' : '/';
  }

  // Redeeming a reset link signs the user in, so this has to be checked
  // before anything else sends them to the dashboard — otherwise they
  // arrive at their books with the password they had forgotten still in
  // force.
  if (recovering) return path == '/reset-password' ? null : '/reset-password';

  // Already signed in and pressing the landing page's way in: the button
  // means "take me to my books", which is what it means to somebody
  // without a session too — they just have a password to type on the
  // way.
  if (path == '/signin') return '/dashboard';

  // Organizations may still be loading; hold the current route until we
  // know whether the user has any books to open. The same goes for
  // platform staff, who legitimately belong to no organization at all —
  // deciding before that answer arrives is what sent the operator to the
  // onboarding screen and left them there.
  if (hasOrg == null || isPlatformAdmin == null) return null;

  if (!hasOrg) {
    // A platform operator has nothing to onboard into: their job is
    // other people's companies, and the console is their home. They may
    // still reach /onboarding deliberately if they want books of their
    // own — it just is not forced on them.
    //
    // And /settings, which is not about a company at all below the
    // company cards: it is where Change password and Sign out live, and
    // the avatar menu offers it on every screen including this one. Left
    // out of this list it was a dead link — the tap navigated and the
    // redirect put them straight back, which looks identical to nothing
    // happening.
    if (isPlatformAdmin) {
      return path.startsWith('/admin') ||
              path == '/onboarding' ||
              path == '/settings'
          ? null
          : '/admin';
    }
    return path == '/onboarding' ? null : '/onboarding';
  }

  if (path == '/onboarding') return '/dashboard';

  return null;
}

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: _rootKey,
    initialLocation: '/',
    refreshListenable: AuthRefresh(ref),
    redirect: (context, state) {
      final orgs = ref.read(organizationsProvider);
      final admin = ref.read(isPlatformAdminProvider);
      return routeFor(
        path: state.matchedLocation,
        signedIn: ref.read(currentUserProvider) != null,
        recovering: ref.read(passwordRecoveryProvider),
        // Loading and error are the same answer — wait — for both, so
        // they arrive as one nullable rather than two states the rule
        // would have to know about.
        hasOrg: orgs.isLoading || orgs.hasError
            ? null
            : (orgs.value ?? const []).isNotEmpty,
        isPlatformAdmin: admin.isLoading || admin.hasError
            ? null
            : (admin.value ?? false),
        // While the lookup is in flight this is false, so the front
        // page draws and the redirect happens when the answer lands —
        // the same choice `app.dart` makes, for the same reason.
        atCompanyDoor: ref.read(workspaceLookupProvider).valueOrNull?.host ==
            WorkspaceHost.found,
      );
    },
    routes: [
      GoRoute(
        path: '/signin',
        builder: (_, state) => SignInScreen(
          // The landing page's two buttons are the same screen in its
          // two moods. Passed as a query parameter rather than as two
          // routes, so /signin stays the one address anybody links to.
          startOnRegister: state.uri.queryParameters['mode'] == 'register',
        ),
      ),
      // Outside the shell and outside auth, like the signing and share
      // pages: no navigation rail, no company switcher, nothing but the
      // company's own front page. It is the address itself now — what
      // is printed on the business card — so somebody arriving with a
      // session already gets the page rather than being posted straight
      // into books they did not ask for.
      GoRoute(path: '/', builder: (_, __) => const LandingScreen()),
      GoRoute(path: '/onboarding', builder: (_, __) => const CreateOrgScreen()),
      // Reachable two ways on purpose: the router forces it after a
      // recovery event, and the reset e-mail links straight here. If the
      // event is missed the link still lands somewhere useful.
      GoRoute(
        path: '/reset-password',
        builder: (_, __) => const ResetPasswordScreen(),
      ),
      // Outside the shell as well as outside auth: no navigation rail,
      // no company switcher, nothing but the document being signed.
      GoRoute(
        path: '/sign/:token',
        builder: (_, state) =>
            SigningPage(token: state.pathParameters['token']!),
      ),
      // Same treatment for a customer sent their own invoice: no shell,
      // no sign-in, nothing but the document.
      GoRoute(
        path: '/share/:token',
        builder: (_, state) =>
            SharedDocumentPage(token: state.pathParameters['token']!),
      ),
      // The menu on the sticker. No shell, no sign-in, nothing but the
      // shop's own list and a basket.
      GoRoute(
        path: '/menu/:token',
        builder: (_, state) =>
            PublicMenuPage(token: state.pathParameters['token']!),
      ),
      ShellRoute(
        navigatorKey: _shellKey,
        builder: (context, state, child) =>
            AppShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(
            path: '/dashboard',
            builder: (_, __) => const DashboardScreen(),
          ),

          // Sales and purchases share one list and one editor; the doc
          // type in the path decides which cycle applies.
          ..._documentRoutes('/sales', 'invoice'),
          ..._documentRoutes('/purchases', 'bill'),

          GoRoute(
            path: '/expenses',
            builder: (_, __) => const ExpensesScreen(),
          ),
          GoRoute(
            path: '/contacts',
            builder: (_, __) => const ContactsScreen(),
            routes: [
              GoRoute(
                path: 'new',
                parentNavigatorKey: _rootKey,
                builder: (_, state) => ContactEditor(
                  contactType: state.uri.queryParameters['type'] ?? 'customer',
                ),
              ),
              GoRoute(
                path: ':id',
                parentNavigatorKey: _rootKey,
                builder: (_, state) =>
                    ContactEditor(contactId: state.pathParameters['id']),
              ),
            ],
          ),
          GoRoute(path: '/items', builder: (_, __) => const ItemsScreen()),
          GoRoute(
            path: '/legal',
            builder: (_, __) => const MattersScreen(),
            routes: [
              GoRoute(
                path: ':id',
                parentNavigatorKey: _rootKey,
                builder: (_, state) =>
                    MatterDetailScreen(matterId: state.pathParameters['id']!),
              ),
            ],
          ),
          GoRoute(path: '/team', builder: (_, __) => const TeamScreen()),
          GoRoute(
            path: '/security',
            builder: (_, __) => const SecurityScreen(),
          ),
          GoRoute(path: '/hr/me', builder: (_, __) => const MyHrScreen()),
          GoRoute(
            path: '/hr/people',
            builder: (_, __) => const PeopleScreen(),
            routes: [
              GoRoute(
                path: 'new',
                parentNavigatorKey: _rootKey,
                builder: (_, __) => const EmployeeEditor(),
              ),
              GoRoute(
                path: ':id',
                parentNavigatorKey: _rootKey,
                builder: (_, state) =>
                    EmployeeEditor(employeeId: state.pathParameters['id']),
              ),
            ],
          ),
          GoRoute(path: '/hr/leave', builder: (_, __) => const LeaveScreen()),
          GoRoute(path: '/hr/claims', builder: (_, __) => const ClaimsScreen()),
          GoRoute(path: '/hr/talent', builder: (_, __) => const TalentScreen()),
          GoRoute(path: '/hr/setup', builder: (_, __) => const HrSetupScreen()),
          GoRoute(
            path: '/hr/payroll',
            builder: (_, __) => const PayrollScreen(),
            routes: [
              GoRoute(
                path: ':id',
                parentNavigatorKey: _rootKey,
                builder: (_, state) =>
                    PayrollRunScreen(runId: state.pathParameters['id']!),
              ),
            ],
          ),
          GoRoute(
            path: '/hr/payslip/:id',
            builder: (_, state) =>
                PayslipScreen(payslipId: state.pathParameters['id']!),
          ),
          GoRoute(path: '/inbox', builder: (_, __) => const InboxScreen()),
          // One route per console section, from the same table the side
          // menu is built from, so a section cannot appear in the menu
          // without somewhere to go or exist without appearing.
          for (final section in platformConsoleSections)
            GoRoute(
              path: section.path,
              builder: (_, __) => PlatformConsoleScreen(path: section.path),
            ),
          GoRoute(path: '/crm', builder: (_, __) => const PipelineScreen()),
          GoRoute(path: '/crm/leads', builder: (_, __) => const LeadsScreen()),
          GoRoute(
            path: '/hr/onboarding',
            builder: (_, __) => const OnboardingScreen(),
          ),
          GoRoute(
            path: '/einvoice',
            builder: (_, __) => const EinvoiceScreen(),
          ),
          GoRoute(
            path: '/journals',
            builder: (_, __) => const JournalsScreen(),
          ),
          GoRoute(path: '/email', builder: (_, __) => const EmailScreen()),
          GoRoute(
            path: '/recurring',
            builder: (_, __) => const RecurringScreen(),
          ),
          GoRoute(
            path: '/recurring-documents',
            builder: (_, __) => const RecurringDocumentsScreen(),
          ),
          GoRoute(
            path: '/withholding',
            builder: (_, __) => const WithholdingScreen(),
          ),
          GoRoute(path: '/import', builder: (_, __) => const ImportScreen()),
          GoRoute(
            path: '/exchange-rates',
            builder: (_, __) => const ExchangeRatesScreen(),
          ),
          GoRoute(
            path: '/salespeople',
            builder: (_, __) => const SalespeopleScreen(),
          ),
          GoRoute(
            path: '/intercompany',
            builder: (_, __) => const IntercompanyScreen(),
          ),
          GoRoute(
            path: '/receipts',
            builder: (_, __) => const ReceiptsScreen(),
          ),
          GoRoute(path: '/assets', builder: (_, __) => const AssetsScreen()),
          GoRoute(path: '/lots', builder: (_, __) => const LotsScreen()),
          GoRoute(
            path: '/stock-take',
            builder: (_, __) => const StockTakeScreen(),
          ),
          GoRoute(
            path: '/transfers',
            builder: (_, __) => const TransfersScreen(),
          ),
          GoRoute(
            path: '/landed-cost',
            builder: (_, __) => const LandedCostScreen(),
          ),
          GoRoute(path: '/bundles', builder: (_, __) => const BundlesScreen()),
          GoRoute(path: '/contra', builder: (_, __) => const ContraScreen()),
          GoRoute(
            path: '/deposits',
            builder: (_, __) => const DepositsScreen(),
          ),
          GoRoute(path: '/budgets', builder: (_, __) => const BudgetsScreen()),
          GoRoute(path: '/cheques', builder: (_, __) => const ChequesScreen()),
          GoRoute(
            path: '/cash-flow',
            builder: (_, __) => const CashFlowScreen(),
          ),
          GoRoute(path: '/chat', builder: (_, __) => const ChatScreen()),
          GoRoute(
            path: '/collections',
            builder: (_, __) => const CollectionsScreen(),
          ),
          GoRoute(
            path: '/approvals',
            builder: (_, __) => const ApprovalsScreen(),
          ),
          GoRoute(
            path: '/financial-statements',
            builder: (_, __) => const FilingsScreen(),
            routes: [
              GoRoute(
                path: ':id',
                parentNavigatorKey: _rootKey,
                builder: (_, state) =>
                    FilingScreen(filingId: state.pathParameters['id']!),
              ),
            ],
          ),
          GoRoute(
            path: '/timesheets',
            builder: (_, __) => const TimesheetScreen(),
          ),
          GoRoute(
            path: '/tickets',
            builder: (_, __) => const TicketsScreen(),
            routes: [
              // Before `:id`, or `/tickets/new` matches it and the
              // viewer is handed the literal string `new` as a uuid —
              // the same trap `/property/new` fell into.
              GoRoute(
                path: 'new',
                parentNavigatorKey: _rootKey,
                builder: (_, __) => const TicketEditor(),
              ),
              GoRoute(
                path: ':id',
                parentNavigatorKey: _rootKey,
                builder: (_, st) => TicketScreen(id: st.pathParameters['id']!),
              ),
            ],
          ),
          GoRoute(
            path: '/forecasting',
            builder: (_, __) => const ForecastScreen(),
          ),
          GoRoute(path: '/till', builder: (_, __) => const TillScreen()),
          GoRoute(path: '/floor', builder: (_, __) => const FloorPlanScreen()),
          GoRoute(path: '/kitchen', builder: (_, __) => const KitchenScreen()),
          GoRoute(path: '/diary', builder: (_, __) => const DiaryScreen()),
          GoRoute(
            path: '/memberships',
            builder: (_, __) => const MembershipsScreen(),
          ),
          GoRoute(path: '/loyalty', builder: (_, __) => const LoyaltyScreen()),
          GoRoute(path: '/voids', builder: (_, __) => const VoidsScreen()),
          GoRoute(
            path: '/promotions',
            builder: (_, __) => const PromotionsScreen(),
          ),
          GoRoute(path: '/queue', builder: (_, __) => const QueueScreen()),
          GoRoute(
            path: '/deliveries',
            builder: (_, __) => const DeliveriesScreen(),
          ),
          GoRoute(
            path: '/menu-times',
            builder: (_, __) => const MenuTimesScreen(),
          ),
          GoRoute(
            path: '/pos-reports',
            builder: (_, __) => const PosReportsScreen(),
          ),
          GoRoute(path: '/recipes', builder: (_, __) => const RecipesScreen()),
          GoRoute(path: '/stalls', builder: (_, __) => const StallsScreen()),
          GoRoute(path: '/takings', builder: (_, __) => const TakingsScreen()),
          GoRoute(path: '/kiosk', builder: (_, __) => const KioskScreen()),
          GoRoute(
            path: '/counters',
            builder: (_, __) => const StationsScreen(),
          ),
          GoRoute(
            path: '/order-board',
            builder: (_, __) => const KioskBoardScreen(),
          ),
          GoRoute(
            path: '/property',
            builder: (_, __) => const PropertyScreen(),
            routes: [
              // Before `:id`, or `/property/new` matches it and the
              // viewer is handed the literal string `new` as a uuid.
              GoRoute(
                path: 'new',
                parentNavigatorKey: _rootKey,
                builder: (_, __) => const PropertySiteEditor(),
              ),
              GoRoute(
                path: ':id',
                parentNavigatorKey: _rootKey,
                builder: (_, state) =>
                    PropertySiteScreen(siteId: state.pathParameters['id']!),
              ),
              GoRoute(
                path: ':id/edit',
                parentNavigatorKey: _rootKey,
                builder: (_, state) =>
                    PropertySiteEditor(siteId: state.pathParameters['id']),
              ),
            ],
          ),
          GoRoute(
            path: '/manufacturing',
            builder: (_, __) => const ManufacturingScreen(),
            routes: [
              GoRoute(
                path: ':id',
                parentNavigatorKey: _rootKey,
                builder: (_, state) => ManufacturingOrderScreen(
                  orderId: state.pathParameters['id']!,
                ),
              ),
            ],
          ),
          GoRoute(
            path: '/reconcile',
            builder: (_, __) => const ReconciliationScreen(),
          ),
          GoRoute(
            path: '/secretarial',
            builder: (_, __) => const SecretarialScreen(),
            routes: [
              GoRoute(
                path: 'new',
                parentNavigatorKey: _rootKey,
                builder: (_, __) => const CorpEntityEditor(),
              ),
              GoRoute(
                path: ':id/edit',
                parentNavigatorKey: _rootKey,
                builder: (_, state) =>
                    CorpEntityEditor(entityId: state.pathParameters['id']),
              ),
              GoRoute(
                path: ':id',
                parentNavigatorKey: _rootKey,
                builder: (_, state) =>
                    CorpEntityScreen(entityId: state.pathParameters['id']!),
              ),
            ],
          ),
          GoRoute(
            path: '/reports',
            builder: (_, __) => const ReportsScreen(),
            routes: [
              // On the root navigator, so it arrives with a back arrow to
              // the company it was opened from. The group is a place you
              // visit from a company, not a place in the sidebar.
              GoRoute(
                path: 'group',
                parentNavigatorKey: _rootKey,
                builder: (_, __) => const GroupReportsScreen(),
              ),
            ],
          ),
          GoRoute(
            path: '/settings',
            builder: (_, __) => const SettingsScreen(),
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.explore_off, size: 40),
            const SizedBox(height: 12),
            Text('No page at ${state.matchedLocation}'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => _rootKey.currentContext?.go('/dashboard'),
              child: const Text('Back to dashboard'),
            ),
          ],
        ),
      ),
    ),
  );
});

/// List plus editor routes for one document cycle. Editors open on the
/// root navigator so they cover the shell rather than nesting inside it.
List<RouteBase> _documentRoutes(String prefix, String fallbackType) => [
  GoRoute(
    path: '$prefix/:docType',
    builder: (_, state) => DocumentListScreen(
      docType: state.pathParameters['docType'] ?? fallbackType,
    ),
    routes: [
      GoRoute(
        path: 'new',
        parentNavigatorKey: _rootKey,
        builder: (_, state) => DocumentEditor(
          docType: state.pathParameters['docType'] ?? fallbackType,
        ),
      ),
      GoRoute(
        path: ':id',
        parentNavigatorKey: _rootKey,
        builder: (_, state) => DocumentEditor(
          docType: state.pathParameters['docType'] ?? fallbackType,
          documentId: state.pathParameters['id'],
        ),
      ),
    ],
  ),
];

/// Bridges Riverpod auth/org state into go_router's Listenable API.
/// What tells the router to decide again.
///
/// Every input to `routeFor` that can still be loading has to be in
/// here. The redirect runs once per navigation; a provider that
/// resolves afterwards changes the right answer and nothing asks for
/// it again, so the visitor sits on the screen the loading state
/// happened to produce. That is not a subtle failure — it is the front
/// page instead of the sign-in form, or a signed-in operator stuck
/// wherever they landed — and it has now happened twice.
///
/// Public, and constructed from a provider below, so a test can hold
/// one and watch it fire.
class AuthRefresh extends ChangeNotifier {
  AuthRefresh(Ref ref) {
    ref.listen(authStateProvider, (_, __) => notifyListeners());
    ref.listen(organizationsProvider, (_, __) => notifyListeners());
    // The redirect holds its decision while this is loading, so it has to
    // be told when the answer lands or an operator with no organization
    // would sit on whatever route they happened to be on.
    ref.listen(isPlatformAdminProvider, (_, __) => notifyListeners());
    // Listened to as much for the side effect as the signal: this is what
    // builds the recovery notifier, and it has to be alive and subscribed
    // before the recovery event arrives or it will miss it.
    ref.listen(passwordRecoveryProvider, (_, __) => notifyListeners());
    // Whose address this is, for the same reason as the three above and
    // with the same failure when it is missing. `0333` added
    // `atCompanyDoor` to the redirect without adding this line: the
    // lookup is still in flight on the first evaluation, so the rule saw
    // `false`, `/` stayed, the front page drew — and nothing ever asked
    // the question again. A visitor at `sinar.iakauntan.com` sat on the
    // platform's shopfront, which is exactly what that rule exists to
    // prevent.
    ref.listen(workspaceLookupProvider, (_, __) => notifyListeners());
  }
}
