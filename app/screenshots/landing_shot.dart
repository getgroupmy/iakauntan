import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/landing/landing_content.dart';
import 'package:iakauntan/src/features/landing/landing_screen.dart';

/// Renders the real landing page and writes it to PNGs.
///
///   flutter test screenshots/landing_shot.dart
///
/// Deliberately outside `test/`, for the reason `dashboard_shot.dart`
/// gives at length: this is a generator that borrows the test binding
/// for its rasteriser, not an assertion, and a golden checked on every
/// push would fail the first time two machines hinted a font
/// differently.
///
/// ## Why it is rendered rather than photographed
///
/// A browser pointed at the deployed site would be the obvious way to
/// get one. The sandbox's network policy refuses both `iakauntan.com`
/// and the Supabase host, so there is nothing for a headless browser to
/// talk to — the same wall `dashboard_shot.dart` ran into.
///
/// What this does instead is render the same widgets the deployed app
/// renders, against the payload `landing_page()` actually returned, at
/// the two widths the page changes shape between. Two things in it are
/// not what a visitor sees, and both are said here rather than left to
/// be discovered:
///
///  * **The mark is the drawn fallback.** `logo_url` resolves to an
///    address in Supabase storage this machine cannot fetch, so
///    `Image.network` fails and `LandingMark` falls back to
///    `_FallbackMark` — exactly as it would for a visitor whose network
///    dropped. A visitor with a working connection sees the uploaded
///    logo there.
///  * **The hero picture is real.** `hero-dashboard.png` is in this
///    repository, so it is served from disk through an `HttpOverrides`
///    rather than fetched. The same bytes a browser would get.
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _loadFonts();
  });

  for (final shot in const [
    (name: 'landing-desktop.png', size: Size(1440, 4600)),
    (name: 'landing-phone.png', size: Size(420, 5400)),
  ]) {
    testWidgets(shot.name, (tester) async {
      tester.view
        ..physicalSize = shot.size
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await HttpOverrides.runZoned(() async {
        await tester.pumpWidget(
          RepaintBoundary(
            key: _shot,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.light(),
              home: Scaffold(
                body: LandingPage(
                  content: parseLandingContent(_payload),
                  // False on purpose. `preview` disables every button,
                  // and a disabled button draws in the disabled palette
                  // — grey on grey — which would put a defect in the
                  // shot that is not on the page. Nothing is tapped
                  // here, so the missing router is never reached.
                  preview: false,
                ),
              ),
            ),
          ),
        );
        // Two waits, for two different clocks. `runAsync` lets the
        // real one run: fetching and decoding an image is real I/O, and
        // under the fake clock `pumpAndSettle` drives the future to
        // completion is not something it can do — the hero would come
        // out a flat field of ink with the picture still in flight.
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 2)),
        );
        // And then the fake one, so the reveal animations finish rather
        // than being caught halfway through fading in.
        await tester.pumpAndSettle(const Duration(seconds: 3));
        await _write(tester, shot.name);
      }, createHttpClient: (_) => _Client());
    });
  }
}

/// What `public.landing_page()` returned, captured 25 August 2026.
///
/// The published page as it stands rather than an invention: the
/// operator's own company details, the four stats and three
/// testimonials live on it, and the catalogue the price band is built
/// from. `sections`, `reasons` and `badges` come back empty, so the
/// page draws the copy that ships with the product — which is what a
/// visitor sees today and is the point of looking.
final _payload = <String, Object?>{
  'page': {
    'wordmark': 'iAkauntan',
    'is_published': true,
    'theme_mode': 'system',
    'brand_colour': '#64d740',
    'brand_colour_dark': '#64d740',
    'hero_headline':
        'Accounting, CRM, payroll and e-Invoice for Malaysian business',
    'sign_in_label': 'Sign in',
    'register_label': 'Create an account',
    'register_enabled': true,
    'show_pricing': true,
    'company_name': 'Kabeer Holdings Sdn Bhd',
    'company_reg_no': '1339519K / 201901030189',
    'address':
        '33-2, Jln Eco Majestic 9/1A, \nEco majestic, \n43500 Semenyih, '
        '\nSelangor',
    'support_email': 'support@iakauntan.com',
    'support_phone': '0182000004',
    'bar_sign_in_desktop': true,
    'bar_register_desktop': true,
    'bar_sign_in_mobile': true,
    'bar_register_mobile': true,
    'hero_sign_in_desktop': true,
    'hero_register_desktop': true,
    'hero_sign_in_mobile': true,
    'hero_register_mobile': true,
  },
  'brand': {
    'wordmark': 'iAkauntan',
    'theme_mode': 'system',
    'brand_colour': '#64d740',
    'brand_colour_dark': '#64d740',
  },
  'sections': const [],
  'reasons': const [],
  'badges': const [],
  'logos': const [],
  'app_links': const [],
  'stats': const [
    {'icon': 'store', 'label': 'Modules', 'value': '25'},
    {'icon': 'check', 'label': 'Included in the core', 'value': '3'},
    {'icon': 'trending_up', 'label': 'Sample — replace me', 'value': '0'},
    {'icon': 'people', 'label': 'Sample — replace me', 'value': '0'},
  ],
  'testimonials': const [
    {
      'quote':
          'SAMPLE COPY, NOT A REAL CUSTOMER. Written to show the shape of '
          'this band. Replace it with something a customer actually said, '
          'or delete it — do not publish this page with this text on it.',
      'author': 'Razlan Hamdan',
      'company': 'Gig Worker',
    },
    {
      'quote':
          'SAMPLE COPY, NOT A REAL CUSTOMER. A second one, so the row can '
          'be seen at two and three columns.',
      'author': 'Mr Kevin',
      'company': 'GET Enterprise',
    },
    {
      'quote':
          'SAMPLE COPY, NOT A REAL CUSTOMER. A third, to fill the widest '
          'row.',
      'author': 'Geswant Singh',
      'company': 'Geswasnt & Co',
    },
  ],
  'modules': const [
    {
      'code': 'sales',
      'name': 'Sales & Invoicing',
      'monthly_price': 0,
      'is_core': true,
    },
    {
      'code': 'accounting',
      'name': 'General Ledger',
      'monthly_price': 0,
      'is_core': true,
    },
    {
      'code': 'contacts',
      'name': 'Contacts',
      'monthly_price': 0,
      'is_core': true,
    },
    {
      'code': 'einvoice',
      'name': 'LHDN e-Invoice',
      'monthly_price': 49,
      'is_core': false,
    },
    {
      'code': 'purchases',
      'name': 'Purchasing',
      'monthly_price': 39,
      'is_core': false,
    },
    {
      'code': 'inventory',
      'name': 'Inventory',
      'monthly_price': 39,
      'is_core': false,
    },
    {'code': 'crm', 'name': 'CRM', 'monthly_price': 29, 'is_core': false},
    {
      'code': 'legal',
      'name': 'Legal Firm Accounting',
      'monthly_price': 99,
      'is_core': false,
    },
    {
      'code': 'hr',
      'name': 'Human Resources',
      'monthly_price': 59,
      'is_core': false,
    },
    {
      'code': 'payroll',
      'name': 'Payroll & Statutory',
      'monthly_price': 89,
      'is_core': false,
    },
    {
      'code': 'secretarial',
      'name': 'Corporate Secretarial',
      'monthly_price': 79,
      'is_core': false,
    },
    {
      'code': 'property_strata',
      'name': 'Property — Strata',
      'monthly_price': 89,
      'is_core': false,
    },
    {
      'code': 'property_nonstrata',
      'name': 'Property — Non-Strata',
      'monthly_price': 69,
      'is_core': false,
    },
    {
      'code': 'timesheets',
      'name': 'Timesheets',
      'monthly_price': 49,
      'is_core': false,
    },
    {
      'code': 'fixed_assets',
      'name': 'Fixed Assets',
      'monthly_price': 39,
      'is_core': false,
    },
    {
      'code': 'approvals',
      'name': 'Approvals',
      'monthly_price': 29,
      'is_core': false,
    },
    {
      'code': 'mbrs',
      'name': 'Financial Statements & MBRS',
      'monthly_price': 79,
      'is_core': false,
    },
    {
      'code': 'ticketing',
      'name': 'Service Desk',
      'monthly_price': 59,
      'is_core': false,
    },
    {
      'code': 'forecasting',
      'name': 'Inventory Forecasting',
      'monthly_price': 49,
      'is_core': false,
    },
    {
      'code': 'pos',
      'name': 'Point of Sale',
      'monthly_price': 79,
      'is_core': false,
    },
    {
      'code': 'loyalty',
      'name': 'Loyalty & Points',
      'monthly_price': 29,
      'is_core': false,
    },
    {
      'code': 'memberships',
      'name': 'Memberships & Packages',
      'monthly_price': 29,
      'is_core': false,
    },
    {
      'code': 'branches',
      'name': 'Branches',
      'monthly_price': 0,
      'is_core': false,
    },
    {
      'code': 'manufacturing',
      'name': 'Manufacturing',
      'monthly_price': 0,
      'is_core': false,
    },
    {'code': 'chat', 'name': 'Chat', 'monthly_price': 0, 'is_core': false},
    {
      'code': 'attachments',
      'name': 'Document attachments',
      'monthly_price': 19,
      'is_core': false,
    },
  ],
};

/// Serves the images this repository holds, and refuses the rest.
///
/// `Image.network` under a test binding answers 400 to everything by
/// design, which would leave the hero a flat field of ink. The hero
/// picture is in `web/`, so it is handed over from disk. Anything else
/// — the logo in Supabase storage — is refused, and the page falls back
/// exactly as it does for a visitor whose network dropped.
class _Client implements HttpClient {
  static final _carried = <String, String>{
    'https://iakauntan.com/hero-dashboard.png': 'web/hero-dashboard.png',
  };

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    final path = _carried[url.toString()];
    if (path == null || !File(path).existsSync()) {
      throw HttpException('not carried in this repository', uri: url);
    }
    return _Request(File(path));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Request implements HttpClientRequest {
  _Request(this.file);
  final File file;

  @override
  Future<HttpClientResponse> close() async => _Response(file.readAsBytesSync());

  @override
  final HttpHeaders headers = _Headers();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Headers implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Response implements HttpClientResponse {
  _Response(this.bytes);
  final List<int> bytes;

  @override
  int get statusCode => 200;

  @override
  int get contentLength => bytes.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.fromIterable([bytes]).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final _shot = GlobalKey();

Future<void> _write(WidgetTester tester, String name) async {
  final boundary =
      _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage();
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  final out = Directory('screenshots/out')..createSync(recursive: true);
  File('${out.path}/$name').writeAsBytesSync(png!.buffer.asUint8List());
}

/// The app's own typeface and the icon font, so the shot is set in the
/// product's type rather than in the test binding's fallback boxes.
Future<void> _loadFonts() async {
  final faces = <String, List<String>>{
    'Plus Jakarta Sans': [
      'assets/fonts/PlusJakartaSans-Regular.ttf',
      'assets/fonts/PlusJakartaSans-Medium.ttf',
      'assets/fonts/PlusJakartaSans-SemiBold.ttf',
      'assets/fonts/PlusJakartaSans-Bold.ttf',
      'assets/fonts/PlusJakartaSans-ExtraBold.ttf',
    ],
    if (_materialIcons() case final path?) 'MaterialIcons': [path],
  };
  for (final entry in faces.entries) {
    final loader = FontLoader(entry.key);
    for (final path in entry.value) {
      final file = File(path);
      if (!file.existsSync()) continue;
      loader.addFont(
        Future.value(ByteData.view(file.readAsBytesSync().buffer)),
      );
    }
    await loader.load();
  }
}

/// MaterialIcons ships inside the Flutter SDK rather than with the app,
/// so it is found by walking out from the running Dart executable.
String? _materialIcons() {
  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 6; i++) {
    final candidate = File(
      '${dir.path}/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (candidate.existsSync()) return candidate.path;
    dir = dir.parent;
  }
  return null;
}
