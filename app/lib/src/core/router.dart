import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'surface.dart';

import '../features/ai/ask_screen.dart';
import '../features/feedback/feedback_screen.dart';
import '../features/firms/practice_screen.dart';
import '../features/auth/reset_password_screen.dart';
import '../features/auth/sign_in_screen.dart';
import '../features/landing/landing_screen.dart';
import '../features/landing/no_access_screen.dart';
import '../features/landing/site_page_screen.dart';
import '../features/chat/chat_screen.dart';
import '../features/contacts/contact_editor.dart';
import '../features/contacts/contacts_screen.dart';
import '../features/contacts/duplicate_contacts_screen.dart';
import '../features/contacts/tax_details_page.dart';
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
import '../features/documents/knock_off_screen.dart';
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
import '../features/legal/client_money_screen.dart';
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
import '../features/documents/group_payment_screen.dart';
import '../features/onboarding/create_org_screen.dart';
import '../features/ledger/journals_screen.dart';
import '../features/documents/recurring_documents_screen.dart';
import '../features/documents/withholding_screen.dart';
import '../features/imports/import_screen.dart';
import '../features/ledger/recurring_screen.dart';
import '../features/reports/group_reports_screen.dart';
import '../features/reports/layout_builder_screen.dart';
import '../features/reports/reports_screen.dart';
import '../features/secretarial/entity_editor.dart';
import '../features/documents/customer_portal_page.dart';
import '../features/documents/shared_document_page.dart';
import '../features/ticketing/shared_ticket_page.dart';
import '../features/settings/email_screen.dart';
import '../features/secretarial/signing_page.dart';
import '../features/secretarial/entity_screen.dart';
import '../features/secretarial/people_screen.dart';
import '../features/secretarial/secretarial_screen.dart';
import '../features/settings/chart_of_accounts_card.dart';
import '../features/profile/profile_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/hr/claims_screen.dart';
import '../features/hr/ea_forms_screen.dart';
import '../features/hr/employee_editor.dart';
import '../features/hr/hr_setup_screen.dart';
import '../features/hr/onboarding_screen.dart';
import '../features/hr/leave_screen.dart';
import '../features/hr/my_hr_screen.dart';
import '../features/hr/payroll_screen.dart';
import '../features/hr/statutory_remittances_screen.dart';
import '../features/hr/payslip_screen.dart';
import '../features/hr/people_screen.dart';
import '../features/hr/talent_screen.dart';
import '../features/dashboard/todos_screen.dart';
import '../features/settings/landing_settings.dart';
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
/// What one address is confined to, from the row `workspace_by_host`
/// returned.
///
/// Null everywhere the operator has not pointed a name at a module,
/// which is every address by default. [Confinement.landingPath] is
/// where somebody signing in through it lands, and [Confinement.allows]
/// is everywhere else they may go — the module's other screens when a
/// module was chosen, and nowhere at all when one exact screen was.
///
/// [Confinement.ours] is `0344`'s: the address belongs to the platform
/// rather than to a company. It changes one thing, and only one — see
/// `moduleHeld` below.
typedef Confinement = ({
  String module,
  String landingPath,
  Set<String> allows,
  bool ours,
});

Confinement? confinementFor(Map<String, dynamic>? workspace) {
  final module = workspace?['module_code'];
  if (module is! String || module.isEmpty) return null;

  // `0344`. An address of ours has no company behind it, which is the
  // whole of what it means here.
  final ours = workspace?['purpose'] == 'admin';

  final path = workspace?['landing_path'];
  if (path is String && path.isNotEmpty) {
    // One screen was named. That is the whole of what this address
    // opens — a kitchen display is not a door into the rest of the
    // till.
    return (module: module, landingPath: path, allows: {path}, ours: ours);
  }

  final paths = pathsForModule(module);
  if (paths.isEmpty) {
    // A module with no screen in the navigation. Nothing to confine to
    // and nothing to send them to, so this is not a restriction — the
    // alternative is bouncing somebody around an address that opens
    // nothing at all.
    return null;
  }
  // No particular screen, so the module's own front door: the first of
  // its destinations in the order the navigation lists them, which is
  // the one a person would call "the" screen for that module.
  return (module: module, landingPath: paths.first, allows: paths, ours: ours);
}

/// Whether the module behind a confined address is held, for the
/// router's `moduleHeld`.
///
/// Null means "still loading", which the rule below treats as "wait"
/// rather than as either answer.
///
/// A function rather than three lines inside the redirect closure,
/// because the interesting case cannot be reached from outside a
/// running router otherwise — and it is the case that matters. `0344`.
/// An address of ours has no company behind it, so there is no
/// subscription to hold and nothing to look up. Asking anyway refuses
/// every one of them: a platform operator with no company of their own
/// holds no modules at all, so the lookup answers false for a reason
/// that has nothing to do with the address.
///
/// An **empty** set is "not known yet" rather than "none of them", and
/// that is not a guess about intent — `enabledModulesProvider` answers
/// `{}` as settled data whenever `repoProvider` is null, which it is
/// for the moment between signing in and the current company landing.
/// Read as a fact it says this person holds no modules at all, and the
/// rule below then sends them to `/no-access` with confidence, a
/// heartbeat before the truth arrives. That is the `/no-access` flash:
/// not a wrong answer about the module, a confident answer given
/// before there was anything to answer about. No real company has
/// nothing enabled — the core modules are always on — so nothing is
/// lost by waiting.
bool? moduleHeldFor(Confinement? door, AsyncValue<Set<String>> enabled) {
  if (door == null) return null;
  if (door.ours) return true;
  return enabled.whenOrNull(
    data: (held) => held.isEmpty ? null : held.contains(door.module),
  );
}

/// Whether this is the iOS or Android app rather than a browser.
///
/// One line, and the whole of it is in `core/surface.dart` — the same
/// fact decides whether a passkey button can be drawn and whether a
/// stranger is offered an account, and three copies of `!kIsWeb &&
/// (android || iOS)` is three places for the subtle half to be dropped
/// from. [currentSurface] says which half that is.
bool get runningInTheApp => currentSurface.isApp;

/// signed-in visitor is not bounced anywhere.
String? routeFor({
  required String path,
  required bool signedIn,
  required bool recovering,
  required bool? hasOrg,
  required bool? isPlatformAdmin,
  bool atCompanyDoor = false,
  bool doorKnown = true,

  /// Whether this is the iOS or Android app rather than a browser.
  ///
  /// The website has a shopfront and the app does not. Somebody who
  /// typed `iakauntan.com` has not come to sign in -- they have come to
  /// find out what this is -- so `/` is the landing page and the form
  /// is one button away. Nobody installs an accounting system from an
  /// app store to read about accounting systems: they installed it
  /// because they already have books here, or because somebody at work
  /// told them to. Every question the landing page answers for a
  /// stranger was answered before the download finished.
  ///
  /// Defaults false, so the web is unchanged and every existing caller
  /// and test means what it meant.
  bool nativeApp = false,
  bool vetting = false,
  String? confinedTo,
  Set<String> confinedAllows = const {},
  bool? moduleHeld,

  /// Where this person has asked to land, from `Settings > Landing
  /// page`. Null while the preference is still being read -- or if
  /// reading it failed -- and null means the dashboard, which is what
  /// everybody got before this existed.
  ///
  /// It does NOT override confinement. A device pinned to the till goes
  /// to the till whatever its user prefers -- that is a property of the
  /// ADDRESS, chosen by whoever set the device up, and a preference is
  /// a property of the person. The confinement block below runs first
  /// and returns before this is ever read.
  String? landingRoute,
}) {
  // The signing page is the one route that works with no account at
  // all: a director will not sign up to an accounting system to sign
  // one resolution. It authorises itself against the token.
  if (path.startsWith('/sign/')) return null;
  // The other page that works with no account: a customer opening a
  // link to their own invoice.
  if (path.startsWith('/share/')) return null;
  // 0626, and the same again: a customer filling in their own TIN,
  // because from this year an e-Invoice will not clear MyInvois
  // without it and only they have it.
  if (path.startsWith('/tax-details/')) return null;
  // And 0493's widening of it: the same customer opening their whole
  // account rather than one document.
  if (path.startsWith('/account/')) return null;
  // And a customer replying to their own support ticket, for the same
  // reason: they will not sign up to an accounting system to answer a
  // question about their printer.
  if (path.startsWith('/ticket/')) return null;
  // And the fourth: somebody at a table with a phone and a QR sticker.
  // 0262's functions authorise themselves against the token, and a
  // customer will not sign up to an accounting system to order a teh
  // tarik.
  if (path.startsWith('/menu/')) return null;

  // And the fourth, which is not about a token either: the terms
  // somebody is being asked to agree to, the privacy policy that
  // describes what happens to them, and the address to write to about
  // both. A policy you have to sign in to read is not a policy, and
  // the footer links to all three from the front page — including the
  // front page of a company's own address, where `/` is the sign-in
  // form and these three still are not.
  if (path == '/terms' || path == '/privacy' || path == '/contact') {
    return null;
  }

  // And the fifth, which is not about a token at all: the corporate
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
  //
  // Unless this is the app, where there is no shopfront to stand in
  // front of. Checked BEFORE the company-door rule and before the
  // signed-out rule below, because it is the stronger fact: a build in
  // an app store has no hostname for `atCompanyDoor` to be about, and
  // an app that opened on a marketing page would be an app whose first
  // screen is an advertisement for the thing already installed.
  //
  // `/signin` and not `/login`: `/login` is a company's own door,
  // reached by typing that company's address, and there is no address
  // to type here.
  //
  // Answered in ONE hop, by asking what `/signin` itself answers, and
  // that is not tidiness. Returning `/signin` flat put a signed-in
  // platform operator through `/` to `/signin` to `/dashboard` to
  // `/admin` -- four -- and the sweep at the bottom of
  // `router_redirect_test.dart` refused it for taking more than three.
  // It was right to: every hop in that chain is a `GoRouter` rebuild,
  // and the bound is what keeps a rule like this one from quietly
  // becoming a chain nobody can follow.
  //
  // The recursion is one deep and cannot be more: `/signin` is neither
  // `/` nor `/welcome`, so the branch it re-enters is not this one.
  if (nativeApp && (path == '/' || path == '/welcome')) {
    return routeFor(
          path: '/signin',
          signedIn: signedIn,
          recovering: recovering,
          hasOrg: hasOrg,
          isPlatformAdmin: isPlatformAdmin,
          atCompanyDoor: atCompanyDoor,
          doorKnown: doorKnown,
          nativeApp: nativeApp,
          vetting: vetting,
          confinedTo: confinedTo,
          confinedAllows: confinedAllows,
          moduleHeld: moduleHeld,
          landingRoute: landingRoute,
        ) ??
        '/signin';
  }
  if (path == '/') return atCompanyDoor ? '/login' : null;
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
    // Two doors, and an address has exactly one of them. `/signin` is
    // the platform's front desk, written for somebody who may not have
    // an account yet; `/login` is a company's own, written for people
    // who work there. Whichever address this is, the other one is a
    // redirect rather than a second page to keep in step.
    //
    // Held until the lookup answers. `atCompanyDoor` is false while it
    // is in flight, and acting on that would send a company's own staff
    // to the platform's door and move them to theirs a moment later —
    // with the wrong heading over the form in between.
    if (path == '/signin' || path == '/login') {
      if (!doorKnown) return null;
      final door = atCompanyDoor ? '/login' : '/signin';
      return path == door ? null : door;
    }
    // `/` is the front page on the web and a redirect to `/signin` in
    // the app, and saying so in one hop rather than two is the same
    // choice the block above this one makes and for the same reason:
    // the chain resolves either way, and the answer to "where does
    // signing out go" should not depend on a second rule further up.
    if (nativeApp) return '/signin';
    return atCompanyDoor ? '/login' : '/';
  }

  // Signed in, and the door checks that may undo it are still running.
  // Hold: moving anybody now means moving them back a moment later,
  // and the round trip is visible — it is the "in, then out, then a
  // dialog" that made a decision look like a fault.
  if (vetting) return null;

  // Redeeming a reset link signs the user in, so this has to be checked
  // before anything else sends them to the dashboard — otherwise they
  // arrive at their books with the password they had forgotten still in
  // force.
  if (recovering) return path == '/reset-password' ? null : '/reset-password';

  // Already signed in and pressing the landing page's way in: the button
  // means "take me to my books", which is what it means to somebody
  // without a session too — they just have a password to type on the
  // way.
  //
  // Held until the lookup says whose address this is. Not for the sake
  // of correctness — it ends up in the same place either way — but
  // because "the books" is a different screen at a confined address,
  // and answering early sends somebody to the dashboard and then moves
  // them off it, which they watch happen. Once the answer is in, the
  // hop to the dashboard and the hop from there to the till resolve as
  // one chain and nothing in between is ever drawn.
  if (path == '/signin' || path == '/login') {
    if (!doorKnown) return null;
    // The dashboard while the preference is still being read, and NOT a
    // hold. Holding would be tidier -- it would avoid the hop from the
    // dashboard to wherever somebody actually asked for -- but it makes
    // a preference that never arrives into a sign-in screen nobody can
    // leave. A read that errors, a network that drops at exactly the
    // wrong moment, and every user of the product is stuck at the door.
    // One visible hop is the cheaper failure by a long way.
    return landingRoute ?? '/dashboard';
  }

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

  // `0342`. An address pointed at one module opens that module and
  // nothing else — it is a restriction rather than a nicer starting
  // point. A counter tablet on `till.iakauntan.com` cannot wander into
  // payroll, and the way it cannot is here rather than in the menu,
  // because a menu that hides a page is not a page that refuses to
  // open.
  //
  // The database is still the authority on what may be *read*: this
  // only decides which screens draw. What it buys is that the tablet
  // by the till shows a till.
  if (confinedTo != null) {
    // Not subscribed, or the module was put away. Saying so is the
    // whole behaviour — `moduleHeld` false with no screen to send them
    // to would otherwise be a redirect loop onto a page that will not
    // render.
    if (moduleHeld == false) {
      return path == '/no-access' ? null : '/no-access';
    }
    // Still loading. Hold the route rather than guessing, exactly as
    // `hasOrg` above does: guessing "allowed" flashes a screen this
    // address is not for, and guessing "refused" flashes the refusal.
    if (moduleHeld == null) return null;

    if (path == confinedTo || confinedAllows.contains(path)) return null;
    // Settings stays reachable. It is where Sign out lives, and an
    // address somebody cannot sign out of is a device nobody can hand
    // to the next shift.
    if (path == '/settings') return null;
    return confinedTo;
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
      // What this address is confined to, if anything.
      final door = confinementFor(
        ref.read(workspaceLookupProvider).valueOrNull?.workspace,
      );

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
        doorKnown: ref.read(workspaceLookupProvider).hasValue,
        nativeApp: runningInTheApp,
        vetting: ref.read(vettingProvider),
        // 0342. An address the operator pointed at one module opens
        // that and nothing else. All three are null or empty at every
        // other address, and nothing above changes.
        confinedTo: door?.landingPath,
        confinedAllows: door?.allows ?? const {},
        // `read`, not `watch`, for the reason spelled out below: a
        // watch here rebuilds the router and restarts it at
        // `initialLocation`. Null while it loads, which `routeFor`
        // reads as "wait".
        landingRoute: ref.read(userPreferencesProvider).whenOrNull(
          // `moduleAllowed` rather than `moduleEnabled`: the latter
          // takes a WidgetRef and watches, and this is neither a widget
          // nor a place that may watch.
          data: (prefs) => landingRouteFor(
            prefs,
            (m) => moduleAllowed(
              entitled: ref.read(enabledModulesProvider).valueOrNull,
              access: ref.read(myModuleAccessProvider).valueOrNull,
              code: m,
            ),
          ),
        ),
        // `read`, like every other provider here, and the difference is
        // not stylistic. `watch` inside this callback makes
        // `routerProvider` itself depend on the modules, so the moment
        // they resolve the provider is rebuilt — and a rebuilt
        // `GoRouter` starts again at `initialLocation`, walking `/` →
        // `/signin` → `/dashboard` → the confined screen, and does it
        // again on the next resolve. That is the loop. What re-runs
        // this redirect is `AuthRefresh` below, which is why every
        // provider the rule reads is listened to there.
        moduleHeld: moduleHeldFor(door, ref.read(enabledModulesProvider)),
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
      // The same screen at a company's own address, reading its own
      // page of copy — `0348`'s sixth `site_pages` row rather than the
      // `signin` one.
      //
      // The same widget and not a copy of it. What differs between the
      // platform's door and a company's is a heading and a lead-in;
      // everything else — the two-step email, the refusals, the hold
      // around the sign-in — is the part that must not drift, and a
      // second seven-hundred-line screen is how it would.
      //
      // No `mode` here. Joining the platform is not something a
      // company's door offers, which is the rule `0336` set and the
      // reason the register link is absent from it already.
      GoRoute(
        path: '/login',
        builder: (_, __) => const SignInScreen(scope: SignInScope.workspace),
      ),
      // Outside the shell and outside auth, like the signing and share
      // pages: no navigation rail, no company switcher, nothing but the
      // company's own front page. It is the address itself now — what
      // is printed on the business card — so somebody arriving with a
      // session already gets the page rather than being posted straight
      // into books they did not ask for.
      GoRoute(path: '/', builder: (_, __) => const LandingScreen()),
      // The three pages the footer links to. Outside the shell and
      // outside auth for the reason given in `routeFor`: they are read
      // before anybody has an account, and often instead of getting one.
      for (final slug in const ['terms', 'privacy', 'contact'])
        GoRoute(
          path: '/$slug',
          builder: (_, __) => SitePageScreen(slug: slug),
        ),
      // 0342. Outside the shell, because the shell is a menu of places
      // this address does not open.
      GoRoute(path: '/no-access', builder: (_, __) => const NoAccessScreen()),
      GoRoute(path: '/onboarding', builder: (_, __) => const CreateOrgScreen()),
      // The same form, at an address the redirect does not send anybody
      // away from. `/onboarding` is first-run only — a person who
      // already has a company is bounced from it to the dashboard — so
      // until now there was no way at all to open a second set of books
      // from inside the app.
      GoRoute(
        path: '/companies/new',
        builder: (_, __) => const CreateOrgScreen(returnTo: '/dashboard'),
      ),
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
      // And the same customer's whole account: every invoice still
      // owed, in one place. It renders none of them — tapping one asks
      // for a document token and comes back through `/share/` above.
      GoRoute(
        path: '/account/:token',
        builder: (_, state) =>
            CustomerPortalPage(token: state.pathParameters['token']!),
      ),
      // 0626. The same customer, asked for their own TIN. Its own path
      // rather than `/share/`, because 0493 emailed portal links on the
      // document route and every one of them opened a page saying the
      // link was not valid — the whole of 0494.
      GoRoute(
        path: '/tax-details/:token',
        builder: (_, state) =>
            TaxDetailsPage(token: state.pathParameters['token']!),
      ),
      // And a customer reading — and replying to — their own support
      // ticket. `0192` built the requester's half of the conversation
      // and nothing could write it, so the person who raised a ticket
      // could not say anything on it.
      GoRoute(
        path: '/ticket/:token',
        builder: (_, state) =>
            SharedTicketPage(token: state.pathParameters['token']!),
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
          // The whole list, rather than the card at the top of the
          // dashboard that shows five of it. 0526.
          GoRoute(
            path: '/todos',
            builder: (_, __) => const TodosScreen(),
          ),

          // Sales and purchases share one list and one editor; the doc
          // type in the path decides which cycle applies.
          ..._documentRoutes('/sales', 'invoice'),
          ..._documentRoutes('/purchases', 'bill'),

          GoRoute(
            path: '/expenses',
            builder: (_, __) => const ExpensesScreen(),
          ),
          // One screen, four doors. `/contacts/customer` is not available
          // as an address: `/contacts/:id` is the editor, so it would be
          // read as a contact whose id is the word "customer".
          for (final kind in const [
            (path: '/customers', type: 'customer'),
            (path: '/suppliers', type: 'supplier'),
            (path: '/prospects', type: 'prospect'),
          ])
            GoRoute(
              path: kind.path,
              // Keyed by the type. Without it Flutter reuses the State
              // across these three routes — same widget, same position —
              // and `initialType` is only read once, so walking from
              // Customer to Supplier would leave the old tab selected.
              builder: (_, __) => ContactsScreen(
                key: ValueKey(kind.type),
                initialType: kind.type,
              ),
            ),
          // Not `/contacts/duplicates`, for the reason above: that
          // address is read as a contact whose id is the word.
          GoRoute(
            path: '/duplicate-contacts',
            builder: (_, __) => const DuplicateContactsScreen(),
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
          // Client money in and out are their own destinations, above
          // the matter route's `:id` child -- `/legal/receipts` would
          // otherwise be read as a matter with that id.
          GoRoute(
            path: '/legal/receipts',
            builder: (_, __) => const ClientMoneyScreen(inbound: true),
          ),
          GoRoute(
            path: '/legal/payouts',
            builder: (_, __) => const ClientMoneyScreen(inbound: false),
          ),
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
          // The AI module's only door. Nothing here gates it: the
          // sidebar hides it without the module and every server call
          // behind it refuses without one, so a typed address reaches a
          // screen that says so rather than a blank page.
          GoRoute(path: '/ask', builder: (_, __) => const AskScreen()),
          GoRoute(
            path: '/feedback',
            builder: (_, __) => const FeedbackScreen(),
          ),
          GoRoute(
            path: '/practice',
            builder: (_, __) => const PracticeScreen(),
          ),
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
            path: '/hr/remittances',
            builder: (_, __) => const StatutoryRemittancesScreen(),
          ),
          GoRoute(
            path: '/hr/ea-forms',
            builder: (_, __) => const EaFormsScreen(),
          ),
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
          // The chart had no route at all until now: it was a card most
          // of the way down Settings, which is where a company's SETUP
          // lives. The chart is not setup — it is the thing somebody
          // opens to look an account up — and it belongs beside the
          // journals that post to it.
          GoRoute(
            path: '/accounts',
            builder: (_, __) => const ChartOfAccountsScreen(),
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
            routes: [
              GoRoute(
                path: 'group',
                parentNavigatorKey: _rootKey,
                builder: (_, __) => const GroupPaymentScreen(),
              ),
            ],
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
          // 0630. The other half of the allocation model: what one
          // customer owes beside what they have in hand, applied in
          // one action. Its own screen rather than a dialog on the
          // receipt, because at month end the question starts from
          // the customer rather than from any one document.
          GoRoute(
            path: '/knock-off',
            builder: (_, __) => const KnockOffScreen(),
          ),
          // 0637. The report kind is in the path because the two
          // layouts are separate things a company edits separately.
          GoRoute(
            path: '/reports/layout/:kind',
            builder: (_, state) => LayoutBuilderScreen(
              kind: state.pathParameters['kind'] ?? 'profit_loss',
            ),
          ),
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
              // Before ':id', because a path parameter would otherwise
              // swallow it and open a company called "people".
              GoRoute(
                path: 'people',
                parentNavigatorKey: _rootKey,
                builder: (_, __) => const CorpPeopleScreen(),
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
          // The person, as opposed to the company. `0649` and
          // `features/profile/` -- there was no such screen on any
          // surface until then, and `profiles` has held these columns
          // since `0001`.
          GoRoute(
            path: '/profile',
            builder: (_, __) => const ProfileScreen(),
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
    // What a confined address is allowed to open. Listened to for the
    // same reason as the rest — the rule reads it and holds while it is
    // unknown — and added when the redirect stopped `watch`ing it,
    // because watching it there rebuilt the router instead of
    // re-running the rule.
    ref.listen(enabledModulesProvider, (_, __) => notifyListeners());
    // And the hold itself, or letting go of it would never be noticed.
    ref.listen(vettingProvider, (_, __) => notifyListeners());
  }
}
