import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/sign_in_screen.dart';
import '../features/contacts/contact_editor.dart';
import '../features/contacts/contacts_screen.dart';
import '../features/crm/pipeline_screen.dart';
import '../features/admin/platform_console_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/documents/document_editor.dart';
import '../features/documents/document_list_screen.dart';
import '../features/einvoice/einvoice_screen.dart';
import '../features/expenses/expenses_screen.dart';
import '../features/items/items_screen.dart';
import '../features/legal/matter_detail_screen.dart';
import '../features/legal/matters_screen.dart';
import '../features/onboarding/create_org_screen.dart';
import '../features/ledger/journals_screen.dart';
import '../features/reports/reports_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/hr/claims_screen.dart';
import '../features/hr/employee_editor.dart';
import '../features/hr/hr_setup_screen.dart';
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

      if (!signedIn) return path == '/signin' ? null : '/signin';
      if (path == '/signin') return '/';

      // Organizations may still be loading; hold the current route until
      // we know whether the user has any books to open.
      final orgs = ref.read(organizationsProvider);
      if (orgs.isLoading || orgs.hasError) return null;

      final hasOrg = (orgs.value ?? const []).isNotEmpty;
      if (!hasOrg && path != '/onboarding') return '/onboarding';
      if (hasOrg && path == '/onboarding') return '/';

      return null;
    },
    routes: [
      GoRoute(
        path: '/signin',
        builder: (_, __) => const SignInScreen(),
      ),
      GoRoute(
        path: '/onboarding',
        builder: (_, __) => const CreateOrgScreen(),
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

          GoRoute(path: '/expenses', builder: (_, __) => const ExpensesScreen()),
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
                builder: (_, state) => MatterDetailScreen(
                  matterId: state.pathParameters['id']!,
                ),
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
          GoRoute(path: '/einvoice', builder: (_, __) => const EinvoiceScreen()),
          GoRoute(path: '/journals', builder: (_, __) => const JournalsScreen()),
          GoRoute(path: '/reports', builder: (_, __) => const ReportsScreen()),
          GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
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
  }
}
