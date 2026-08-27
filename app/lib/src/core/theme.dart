import 'package:flutter/material.dart';

/// Spacing scale. Deliberately tight: this is a ledger, scanned rather than
/// read, so more rows on screen beats more air around them.
abstract final class Space {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

/// Corner radii, kept to three so nothing drifts.
abstract final class Radii {
  static const sm = 8.0;
  static const md = 10.0;
  static const lg = 12.0;
}

/// How long a state change takes. One place so hover, selection and
/// expansion never disagree, and so the whole app can be stilled at once
/// when the platform asks for reduced motion.
abstract final class Motion {
  static const fast = Duration(milliseconds: 120);
  static const base = Duration(milliseconds: 180);
  static const slow = Duration(milliseconds: 280);
  static const curve = Curves.easeOut;

  /// Honours the operating system's "reduce motion" setting.
  static Duration of(BuildContext context, [Duration d = base]) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : d;
}

/// Status colours, which are *not* the brand accent — a figure is green
/// because it is money in, not because green is on brand. Held in a theme
/// extension so each brightness gets a shade that actually passes contrast
/// on its own ground, instead of one constant used on both.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.moneyIn,
    required this.moneyOut,
  });

  final Color success;
  final Color warning;
  final Color danger;
  final Color info;

  /// Ledger direction. Separate names from success/danger on purpose:
  /// money leaving the account is not a failure.
  final Color moneyIn;
  final Color moneyOut;

  static const _light = AppColors(
    success: Color(0xFF047857),
    warning: Color(0xFFB45309),
    danger: Color(0xFFDC2626),
    info: Color(0xFF1D4ED8),
    moneyIn: Color(0xFF047857),
    moneyOut: Color(0xFFB45309),
  );

  static const _dark = AppColors(
    success: Color(0xFF34D399),
    warning: Color(0xFFFBBF24),
    danger: Color(0xFFF87171),
    info: Color(0xFF60A5FA),
    moneyIn: Color(0xFF34D399),
    moneyOut: Color(0xFFFBBF24),
  );

  @override
  AppColors copyWith({
    Color? success,
    Color? warning,
    Color? danger,
    Color? info,
    Color? moneyIn,
    Color? moneyOut,
  }) => AppColors(
    success: success ?? this.success,
    warning: warning ?? this.warning,
    danger: danger ?? this.danger,
    info: info ?? this.info,
    moneyIn: moneyIn ?? this.moneyIn,
    moneyOut: moneyOut ?? this.moneyOut,
  );

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    return AppColors(
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      info: Color.lerp(info, other.info, t)!,
      moneyIn: Color.lerp(moneyIn, other.moneyIn, t)!,
      moneyOut: Color.lerp(moneyOut, other.moneyOut, t)!,
    );
  }
}

extension AppColorsX on BuildContext {
  /// Status colours for the current brightness.
  AppColors get colors =>
      Theme.of(this).extension<AppColors>() ?? AppColors._light;

  ColorScheme get scheme => Theme.of(this).colorScheme;
}

/// iAkauntan visual identity: a deep teal that reads as trustworthy on a
/// finance screen, with amber reserved for things needing attention
/// (overdue balances, invalid e-Invoices).
class AppTheme {
  const AppTheme._();

  /// The colour the product is drawn in when nobody has chosen one.
  ///
  /// A platform operator can override it from the console — 0292 stores
  /// the choice — and this stays the fallback, which is what every
  /// screen uses before the choice has been fetched and if it never
  /// arrives.
  static const seed = Color(0xFF0B7A6B);

  /// Turn `#RRGGBB` into a colour, or null if it is not one.
  ///
  /// Null rather than a throw or a default: the caller decides what to
  /// do without a colour, and a malformed one must not take down the
  /// theme and with it every screen.
  static Color? parseHex(String? hex) {
    if (hex == null) return null;
    final t = hex.trim();
    if (t.length != 7 || !t.startsWith('#')) return null;
    final v = int.tryParse(t.substring(1), radix: 16);
    if (v == null) return null;
    return Color(0xFF000000 | v);
  }

  /// Bundled, not fetched. A web build that reached for Google Fonts at
  /// runtime drew its whole layout with no glyphs at all whenever that
  /// request was blocked.
  static const fontFamily = 'Plus Jakarta Sans';

  static ThemeData light({
    Color? seedColor,
    Map<String, String> overrides = const {},
  }) => _build(Brightness.light, seedColor, overrides);

  static ThemeData dark({
    Color? seedColor,
    Map<String, String> overrides = const {},
  }) => _build(Brightness.dark, seedColor, overrides);

  /// Ink that can be read on [background].
  ///
  /// Material pairs every role with an `on` colour it computed from the
  /// seed. An override replaces the role and cannot replace the pair —
  /// so a pale Primary would keep white text on every filled button.
  /// This is what stops that, and it is a rendering decision rather
  /// than something to store.
  static Color inkOn(Color background) =>
      ThemeData.estimateBrightnessForColor(background) == Brightness.dark
          ? Colors.white
          : Colors.black87;

  /// [base] with whatever roles an operator has chosen replaced.
  ///
  /// On top of the derivation rather than instead of it: a platform
  /// that overrides nothing but Error keeps a coherent scheme with its
  /// own red in it, and clearing that box gives Material's red back.
  ///
  /// An unparseable value is ignored rather than thrown on — the
  /// database checks the shape, but this is the code path every screen
  /// in the product goes through, and a colour typed wrong somewhere
  /// must not be a product that will not draw.
  static ColorScheme applyOverrides(
    ColorScheme base,
    Map<String, String> overrides,
  ) {
    var scheme = base;
    for (final entry in overrides.entries) {
      final colour = parseHex(entry.value);
      if (colour == null) continue;
      final ink = inkOn(colour);
      scheme = switch (entry.key) {
        'primary' => scheme.copyWith(primary: colour, onPrimary: ink),
        'container' =>
          scheme.copyWith(primaryContainer: colour, onPrimaryContainer: ink),
        'secondary' => scheme.copyWith(secondary: colour, onSecondary: ink),
        'surface' => scheme.copyWith(surface: colour, onSurface: ink),
        // The tone raised surfaces use, which is what the console's
        // "Surface tint" tile shows. Not `surfaceTint`, which is an
        // elevation overlay nobody looks at directly.
        'surfaceTint' => scheme.copyWith(
          surfaceContainerHighest: colour,
          onSurfaceVariant: ink,
        ),
        'error' => scheme.copyWith(error: colour, onError: ink),
        _ => scheme,
      };
    }
    return scheme;
  }

  static ThemeData _build(
    Brightness brightness, [
    Color? seedColor,
    Map<String, String> overrides = const {},
  ]) {
    final scheme = applyOverrides(
      ColorScheme.fromSeed(
        seedColor: seedColor ?? seed,
        brightness: brightness,
      ),
      overrides,
    );
    final isDark = brightness == Brightness.dark;
    final colors = isDark ? AppColors._dark : AppColors._light;

    final surface = isDark ? scheme.surfaceContainerLow : Colors.white;
    final hover = scheme.primary.withValues(alpha: isDark ? 0.10 : 0.05);
    final focus = scheme.primary.withValues(alpha: isDark ? 0.16 : 0.09);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: fontFamily,
      extensions: [colors],
      scaffoldBackgroundColor: isDark
          ? scheme.surface
          : const Color(0xFFF6F8F8),
      visualDensity: VisualDensity.compact,
      hoverColor: hover,
      focusColor: focus,
      textTheme: _textTheme(brightness),
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? scheme.surface : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          color: scheme.onSurface,
          fontSize: 17,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? scheme.surfaceContainerHighest : Colors.white,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Space.md,
          vertical: Space.md,
        ),
        border: _border(scheme.outlineVariant),
        enabledBorder: _border(scheme.outlineVariant),
        focusedBorder: _border(scheme.primary, width: 1.6),
        errorBorder: _border(colors.danger),
        focusedErrorBorder: _border(colors.danger, width: 1.6),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.xl,
            vertical: Space.md,
          ),
          textStyle: const TextStyle(
            fontFamily: fontFamily,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.md),
          ),
        ).copyWith(mouseCursor: _clickable, side: _focusRing(scheme.onSurface)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.xl,
            vertical: Space.md,
          ),
          textStyle: const TextStyle(
            fontFamily: fontFamily,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.md),
          ),
        ).copyWith(mouseCursor: _clickable, side: _focusRing(scheme.primary)),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          textStyle: const TextStyle(
            fontFamily: fontFamily,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ).copyWith(mouseCursor: _clickable, side: _focusRing(scheme.primary)),
      ),
      chipTheme: ChipThemeData(
        side: BorderSide.none,
        // The colour is not decoration. A `labelStyle` supplied without
        // one does not fall through to the colour scheme — Chip resolves
        // the remaining fields against Material's own defaults, which are
        // built for a light surface, so the label came out near-black on
        // every chip in dark mode and the Modules row on Settings was
        // unreadable. Naming the colour is the whole fix, and it has to
        // be named on `secondaryLabelStyle` too or selected chips repeat
        // it.
        labelStyle: TextStyle(
          fontFamily: fontFamily,
          fontWeight: FontWeight.w600,
          fontSize: 12,
          color: scheme.onSurfaceVariant,
        ),
        secondaryLabelStyle: TextStyle(
          fontFamily: fontFamily,
          fontWeight: FontWeight.w600,
          fontSize: 12,
          color: scheme.onSecondaryContainer,
        ),
        iconTheme: IconThemeData(size: 16, color: scheme.onSurfaceVariant),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.6),
        space: 1,
        thickness: 1,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: isDark ? scheme.surface : Colors.white,
        indicatorColor: scheme.primaryContainer,
        labelType: NavigationRailLabelType.none,
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: Space.lg),
        horizontalTitleGap: Space.md,
        minVerticalPadding: Space.sm,
        // A row that responds to the pointer is the cheapest way to keep
        // your place in a long ledger.
        mouseCursor: _clickable,
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        textStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 12,
          color: scheme.onInverseSurface,
        ),
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelStyle: const TextStyle(
          fontFamily: fontFamily,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
        unselectedLabelStyle: const TextStyle(
          fontFamily: fontFamily,
          fontWeight: FontWeight.w500,
          fontSize: 14,
        ),
        mouseCursor: _clickable,
      ),
    );
  }

  /// Digits line up in columns everywhere, because in this app almost every
  /// number sits above or below another one it has to be compared with.
  static TextTheme _textTheme(Brightness brightness) {
    const tabular = [FontFeature.tabularFigures()];
    final base = ThemeData(brightness: brightness).textTheme;

    TextStyle? t(
      TextStyle? s, {
      double? size,
      FontWeight? weight,
      double? ls,
    }) => s?.copyWith(
      fontFamily: fontFamily,
      fontFeatures: tabular,
      fontSize: size,
      fontWeight: weight,
      letterSpacing: ls,
    );

    return base.copyWith(
      displaySmall: t(base.displaySmall, weight: FontWeight.w800, ls: -0.8),
      headlineMedium: t(base.headlineMedium, weight: FontWeight.w700, ls: -0.6),
      headlineSmall: t(
        base.headlineSmall,
        size: 22,
        weight: FontWeight.w700,
        ls: -0.4,
      ),
      titleLarge: t(
        base.titleLarge,
        size: 19,
        weight: FontWeight.w700,
        ls: -0.3,
      ),
      titleMedium: t(
        base.titleMedium,
        size: 15,
        weight: FontWeight.w600,
        ls: -0.1,
      ),
      titleSmall: t(base.titleSmall, size: 13, weight: FontWeight.w600),
      bodyLarge: t(base.bodyLarge, size: 15),
      bodyMedium: t(base.bodyMedium, size: 13.5),
      bodySmall: t(base.bodySmall, size: 12),
      labelLarge: t(base.labelLarge, size: 13, weight: FontWeight.w600),
      labelMedium: t(base.labelMedium, size: 12, weight: FontWeight.w600),
      labelSmall: t(base.labelSmall, size: 11, weight: FontWeight.w600),
    );
  }

  static final _clickable = WidgetStateProperty.resolveWith<MouseCursor?>(
    (states) => states.contains(WidgetState.disabled)
        ? SystemMouseCursors.basic
        : SystemMouseCursors.click,
  );

  /// A ring, not just a tint. The default focused overlay is a wash of the
  /// button's own colour, which on a filled button is nearly invisible —
  /// and keyboard users are the ones who cannot see where they are.
  static WidgetStateProperty<BorderSide?> _focusRing(Color color) =>
      WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? BorderSide(color: color, width: 2)
            : null,
      );

  static OutlineInputBorder _border(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        borderSide: BorderSide(color: color, width: width),
      );
}
