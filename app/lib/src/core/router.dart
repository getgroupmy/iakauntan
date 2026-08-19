import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/reset_password_screen.dart';
import '../features/auth/sign_in_screen.dart';
import '../features/chat/chat_screen.dart';
import '../features/contacts/contact_editor.dart';
import '../features/contacts/contacts_screen.dart';
import '../features/crm/leads_screen.dart';
import '../features/crm/pipeline_screen.dart';
import '../features/admin/platform_console_screen.dart';
import '../features/assets/assets_screen.dart';
import '../features/banking/reconciliation_screen.dart';
import '../features/stock/lots_screen.dart';
import '../features/stock/stock_take_screen.dart';
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
import '../features/pos/floor_plan_screen.dart';
import '../features/pos/kitchen_screen.dart';
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
import '../features/team/team_screen.dart';
import '../features/shell/app_shell.dart';
import 'providers.dart';

final _rootKey = GlobalKey<NavigatorState>();
final _shellKey = GlobalKey<NavigatorState>();

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: _rootKey,
    initialLocation: '/',
    refreshListenable: _AuthRefresh(ref),
    redirect: (context, state) {
      final signedIn = ref.read(currentUserProvider) != null;
      final path = state.matchedLocation;

      // The signing page is the one route that works with no account at
      // all: a director will not sign up to an accounting system to sign
      // one resolution. It authorises itself against the token.
      if (path.startsWith('/sign/')) return null;
      // The other page that works with no account: a customer
      // opening a link to their own invoice.
      if (path.startsWith('/share/')) return null;

      if (!signedIn) return path == '/signin' ? null : '/signin';

      // Redeeming a reset link signs the user in, so this has to be
      // checked before anything else sends them to the dashboard —
      // otherwise they arrive at their books with the password they had
      // forgotten still in force.
      if (ref.read(passwordRecoveryProvider)) {
        return path == '/reset-password' ? null : '/reset-password';
      }

      if (path == '/signin') return '/';

      // Organizations may still be loading; hold the current route until
      // we know whether the user has any books to open. The same goes for
      // platform staff, who legitimately belong to no organization at all
      // — deciding before that answer arrives is what sent the operator
      // to the onboarding screen and left them there.
      final orgs = ref.read(organizationsProvider);
      if (orgs.isLoading || orgs.hasError) return null;

      // Held on error as well as while loading, exactly as the
      // organizations above are. Deciding without this answer sends the
      // operator to onboarding, and getting there by mistake is worse
      // than waiting: the redirect re-runs when the provider settles.
      final admin = ref.read(isPlatformAdminProvider);
      if (admin.isLoading || admin.hasError) return null;

      final hasOrg = (orgs.value ?? const []).isNotEmpty;

      if (!hasOrg) {
        // A platform operator has nothing to onboard into: their job is
        // other people's companies, and the console is their home. They
        // may still reach /onboarding deliberately if they want books of
        // their own — it just is not forced on them.
        //
        // And /settings, which is not about a company at all below the
        // company cards: it is where Change password and Sign out live,
        // and the avatar menu offers it on every screen including this
        // one. Left out of this list it was a dead link — the tap
        // navigated and the redirect put them straight back, which
        // looks identical to nothing happening.
        if (admin.value ?? false) {
          return path.startsWith('/admin') ||
                  path == '/onboarding' ||
                  path == '/settings'
              ? null
              : '/admin';
        }
        return path == '/onboarding' ? null : '/onboarding';
      }

      if (path == '/onboarding') return '/';

      return null;
    },
    routes: [
      GoRoute(path: '/signin', builder: (_, __) => const SignInScreen()),
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
      ShellRoute(
        navigatorKey: _shellKey,
        builder: (context, state, child) =>
            AppShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(path: '/', builder: (_, __) => const DashboardScreen()),

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
          GoRoute(
            path: '/admin',
            builder: (_, __) => const PlatformConsoleScreen(),
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
                builder: (_, st) =>
                    TicketScreen(id: st.pathParameters['id']!),
              ),
            ],
          ),
          GoRoute(
            path: '/forecasting',
            builder: (_, __) => const ForecastScreen(),
          ),
          GoRoute(path: '/till', builder: (_, __) => const TillScreen()),
          GoRoute(
            path: '/floor',
            builder: (_, __) => const FloorPlanScreen(),
          ),
          GoRoute(
            path: '/kitchen',
            builder: (_, __) => const KitchenScreen(),
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
              onPressed: () => _rootKey.currentContext?.go('/'),
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
class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(Ref ref) {
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
  }
}
