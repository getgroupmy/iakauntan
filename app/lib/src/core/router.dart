import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/sign_in_screen.dart';
import '../features/contacts/contact_editor.dart';
import '../features/contacts/contacts_screen.dart';
import '../features/crm/pipeline_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/einvoice/einvoice_screen.dart';
import '../features/items/items_screen.dart';
import '../features/onboarding/create_org_screen.dart';
import '../features/reports/reports_screen.dart';
import '../features/sales/invoice_editor.dart';
import '../features/sales/sales_list_screen.dart';
import '../features/settings/settings_screen.dart';
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
          GoRoute(
            path: '/sales/:docType',
            builder: (_, state) => SalesListScreen(
              docType: state.pathParameters['docType'] ?? 'invoice',
            ),
            routes: [
              GoRoute(
                path: 'new',
                parentNavigatorKey: _rootKey,
                builder: (_, state) => InvoiceEditor(
                  docType: state.pathParameters['docType'] ?? 'invoice',
                ),
              ),
              GoRoute(
                path: ':id',
                parentNavigatorKey: _rootKey,
                builder: (_, state) => InvoiceEditor(
                  docType: state.pathParameters['docType'] ?? 'invoice',
                  documentId: state.pathParameters['id'],
                ),
              ),
            ],
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
          GoRoute(path: '/crm', builder: (_, __) => const PipelineScreen()),
          GoRoute(path: '/einvoice', builder: (_, __) => const EinvoiceScreen()),
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

/// Bridges Riverpod auth/org state into go_router's Listenable API.
class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(Ref ref) {
    ref.listen(authStateProvider, (_, __) => notifyListeners());
    ref.listen(organizationsProvider, (_, __) => notifyListeners());
  }
}
