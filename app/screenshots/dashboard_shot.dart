import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/platform_catalog_repository.dart';
import 'package:iakauntan/src/features/dashboard/dashboard_screen.dart';

/// Renders the real dashboard and writes it to a PNG.
///
///   flutter test screenshots/dashboard_shot.dart
///
/// Deliberately outside `test/`, so `flutter test` in CI does not run
/// it. This is a generator that happens to use the test binding for its
/// rasteriser, not an assertion about anything, and a golden image
/// checked on every push would fail the first time a font hinting
/// difference appeared between two machines.
///
/// ## Why this exists
///
/// The landing page's hero wants a picture of the product. Driving the
/// deployed app with a browser would be the obvious way to get one, and
/// is not available from here: the sandbox's network policy refuses
/// both `iakauntan.com` and the Supabase host, so there is nothing for
/// a headless browser to talk to.
///
/// This renders the same widgets the deployed app renders, against a
/// fixed dataset, with the app's own fonts and theme loaded. What comes
/// out is a real screenshot of the real interface — the figures are the
/// only invented part, and they are invented on purpose.
///
/// ## The figures are demo figures and are labelled as such
///
/// The company is named "Demo Sdn Bhd" and every number below is made
/// up. That is the correct thing for a product shot — nobody's actual
/// books belong on a marketing page — but it does mean this image must
/// never be presented as one customer's results. It is a picture of the
/// software, in the same way the drawn placeholder it replaces is.
void main() {
  const size = Size(1440, 900);

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _loadFonts();
  });

  testWidgets('dashboard', (tester) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      RepaintBoundary(
        key: _shot,
        child: ProviderScope(
          overrides: _demo,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(),
            home: const Scaffold(body: DashboardScreen()),
          ),
        ),
      ),
    );
    // Two pumps and a settle: the providers are futures, and the
    // reveal animations have to finish or the shot catches them
    // halfway through fading in.
    await tester.pump();
    await tester.pumpAndSettle(const Duration(seconds: 2));

    await _write(tester, 'dashboard.png');
  });
}

/// Everything the dashboard reads, answered from memory.
final _demo = <Override>[
  currentOrgProvider.overrideWith(
    (ref) async => Organization(
      id: '00000000-0000-0000-0000-0000000000d0',
      name: 'Demo Sdn Bhd',
      slug: 'demo',
    ),
  ),
  moduleLabelsProvider.overrideWith(
    (ref) async => const {
      'accounting': (name: 'Accounting', group: 'Finance'),
      'sales': (name: 'Sales', group: 'Finance'),
      'einvoice': (name: 'e-Invoice', group: 'Finance'),
    },
  ),
  enabledModulesProvider.overrideWith(
    (ref) async => {'accounting', 'sales', 'einvoice'},
  ),
  myModuleAccessProvider.overrideWith(
    (ref) async => const {
      'accounting': 'full',
      'sales': 'full',
      'einvoice': 'full',
    },
  ),
  moduleDashboardProvider.overrideWith((ref) async => const {}),
  dashboardProvider.overrideWith(
    (ref) async => DashboardSummary(const {
      'revenue': 486320.50,
      'expenses': 291744.20,
      'receivables': 128940.00,
      'payables': 63180.75,
      'overdue_receivables': 21460.00,
      'bank_balance': 214905.35,
      'draft_invoices': 4,
      'einvoice_pending': 2,
      'einvoice_invalid': 0,
      'low_stock': 3,
    }),
  ),
  revenueTrendProvider.overrideWith(
    (ref) async => const [
      {'month': '2026-01-01', 'revenue': 31200.0, 'expenses': 20100.0},
      {'month': '2026-02-01', 'revenue': 38650.0, 'expenses': 22400.0},
      {'month': '2026-03-01', 'revenue': 35980.0, 'expenses': 24850.0},
      {'month': '2026-04-01', 'revenue': 44120.0, 'expenses': 25600.0},
      {'month': '2026-05-01', 'revenue': 41870.0, 'expenses': 26310.0},
      {'month': '2026-06-01', 'revenue': 52340.0, 'expenses': 28940.0},
      {'month': '2026-07-01', 'revenue': 48910.0, 'expenses': 27520.0},
      {'month': '2026-08-01', 'revenue': 57250.0, 'expenses': 30180.0},
    ],
  ),
  arAgingProvider.overrideWith(
    (ref) async => const [
      {
        'contact_name': 'Kedai Runcit Seri Muda',
        'current': 18400.0,
        'days_1_30': 6200.0,
        'days_31_60': 0.0,
        'days_61_90': 0.0,
        'days_over_90': 0.0,
        'total': 24600.0,
      },
      {
        'contact_name': 'Perniagaan Maju Jaya',
        'current': 12100.0,
        'days_1_30': 3800.0,
        'days_31_60': 2400.0,
        'days_61_90': 0.0,
        'days_over_90': 0.0,
        'total': 18300.0,
      },
      {
        'contact_name': 'Syarikat Bina Setia',
        'current': 9600.0,
        'days_1_30': 0.0,
        'days_31_60': 4100.0,
        'days_61_90': 1900.0,
        'days_over_90': 0.0,
        'total': 15600.0,
      },
      {
        'contact_name': 'Restoran Nasi Kandar Ali',
        'current': 4200.0,
        'days_1_30': 1800.0,
        'days_31_60': 0.0,
        'days_61_90': 0.0,
        'days_over_90': 2300.0,
        'total': 8300.0,
      },
    ],
  ),
  activitiesProvider.overrideWith((ref) async => const []),
];

/// The app's own typeface and the icon font, so the shot is set in the
/// product's type rather than in the test binding's fallback boxes.
///
/// The icon font is the one that catches people out. A widget test
/// draws every `Icon` as an empty square unless MaterialIcons is
/// loaded, and an empty square is exactly what a missing glyph looks
/// like — so a shot taken without this reads as a broken build rather
/// than as a missing font. It ships inside the Flutter SDK rather than
/// with the app, which is why it is found by walking out from the
/// running Dart executable instead of by a path in this repository.
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
    var any = false;
    for (final path in entry.value) {
      final file = File(path);
      if (!file.existsSync()) continue;
      any = true;
      loader.addFont(
        file.readAsBytes().then((b) => ByteData.sublistView(b)),
      );
    }
    if (any) await loader.load();
  }
}

/// `.../bin/cache/dart-sdk/bin/dart` → `.../bin/cache/artifacts/...`
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

/// The boundary the rasteriser is pointed at.
final _shot = GlobalKey();

Future<void> _write(WidgetTester tester, String name) async {
  // The engine renders a RepaintBoundary to an image directly, which is
  // how a widget test gets pixels at all — there is no window to grab.
  final boundary =
      _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final bytes = data!.buffer.asUint8List();
  final out = Directory('screenshots/out')..createSync(recursive: true);
  File('${out.path}/$name').writeAsBytesSync(bytes);
  stdout.writeln('wrote screenshots/out/$name (${bytes.length} bytes)');
}
