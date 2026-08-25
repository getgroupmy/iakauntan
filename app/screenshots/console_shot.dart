import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/admin/platform_console_screen.dart';

/// Renders the platform console and writes it to a PNG.
///
///   flutter test screenshots/console_shot.dart
///
/// Outside `test/` for the same reason as the other two generators in
/// this directory: it borrows the test binding for its rasteriser, it
/// asserts nothing, and a golden image compared on every push would
/// fail the first time two machines hinted a font differently.
///
/// The figures are the platform's own, read off the console rather than
/// invented, so the shot can be held against the real screen. Nothing
/// here is a tenant's data — every number is a count across the whole
/// deployment.
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _loadFonts();
  });

  // One case, three shots: nothing here asserts anything, so there is
  // no reason to pay for three separate bindings.
  testWidgets('console', (tester) async {
    await _shoot(tester, const Size(412, 900), 'console-phone.png');
    await _shoot(
      tester,
      const Size(412, 900),
      'console-phone-menu.png',
      openMenu: true,
    );
    await _shoot(tester, const Size(1280, 900), 'console-laptop.png');
  });
}

Future<void> _shoot(
  WidgetTester tester,
  Size size,
  String name, {
  bool openMenu = false,
}) async {
  // Logical pixels, one to one: `physicalSize` is divided by the ratio
  // to get the layout size, so a phone's 412 with a ratio of 2 lays the
  // page out 206 wide — half a phone, and not the thing being looked
  // at. The raster is sharpened in `toImage` instead.
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    RepaintBoundary(
      key: _shot,
      child: ProviderScope(
        overrides: [
          isPlatformAdminProvider.overrideWith((ref) async => true),
          platformStatsProvider.overrideWith((ref) async => _stats),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const PlatformConsoleScreen(),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pumpAndSettle();

  if (openMenu) {
    // Opened through the scaffold rather than by tapping the button,
    // and pumped for a fixed span rather than settled. `pumpAndSettle`
    // over a tap on a tooltipped button does not come back here — it
    // keeps finding another frame to draw and runs until the test
    // times out, with no failure to read afterwards.
    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  await _write(tester, name);
}

/// What the console actually reported on the deployment, so the shot
/// can be compared with the screen it replaces.
const _stats = <String, dynamic>{
  'organizations': 7,
  'organizations_active': 7,
  'users': 10,
  'signups_30d': 10,
  'invoiced_value': 349278.50,
  'invoices': 76,
  'einvoices_valid': 0,
  'einvoices_failed': 0,
  'einvoice_enabled_orgs': 0,
};

/// The app's own typeface and the icon font. Without the icon font
/// every `Icon` draws as an empty square, which reads as a broken
/// build rather than as a missing font.
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
      loader.addFont(file.readAsBytes().then((b) => ByteData.sublistView(b)));
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

final _shot = GlobalKey();

Future<void> _write(WidgetTester tester, String name) async {
  final boundary =
      _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;

  // Inside `runAsync`, because rasterising a layer tree and encoding a
  // PNG is real work on a real thread and the test binding's clock is a
  // fake one. Awaited straight, the first shot came back and the second
  // never did: the encode had nothing to drive it and the run sat there
  // until it was killed.
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  });
  if (bytes == null) return;
  final out = Directory('screenshots/out')..createSync(recursive: true);
  File('${out.path}/$name').writeAsBytesSync(bytes);
  stdout.writeln('wrote screenshots/out/$name (${bytes.length} bytes)');
}
