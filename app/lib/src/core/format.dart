import 'package:intl/intl.dart';

/// Malaysian formatting conventions used across the app.
class Fmt {
  const Fmt._();

  static final _date = DateFormat('dd/MM/yyyy');
  static final _longDate = DateFormat('d MMM yyyy');
  static final _monthYear = DateFormat('MMM yyyy');
  static final _dateTime = DateFormat('dd/MM/yyyy HH:mm');
  static final _plain = NumberFormat('#,##0.00');
  static final _compact = NumberFormat.compact(locale: 'en');

  /// RM 1,234.56 — the symbol is spaced, which is how it appears on
  /// Malaysian tax invoices.
  static String money(num? value, {String currency = 'MYR'}) {
    final amount = _plain.format(value ?? 0);
    return currency == 'MYR' ? 'RM $amount' : '$currency $amount';
  }

  static String plain(num? value) => _plain.format(value ?? 0);

  static String compact(num? value) => _compact.format(value ?? 0);

  static String qty(num? value) {
    final v = value ?? 0;
    // Drop trailing zeros so 2.0000 shows as 2 but 2.5 stays 2.5.
    return v == v.roundToDouble()
        ? v.toStringAsFixed(0)
        : v.toString().replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }

  static String percent(num? value) {
    final v = value ?? 0;
    return '${v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2)}%';
  }

  static String date(DateTime? value) => value == null ? '—' : _date.format(value);

  static String longDate(DateTime? value) =>
      value == null ? '—' : _longDate.format(value);

  static String monthYear(DateTime? value) =>
      value == null ? '—' : _monthYear.format(value);

  static String dateTime(DateTime? value) =>
      value == null ? '—' : _dateTime.format(value.toLocal());

  /// ISO date, which is what Postgres `date` columns expect.
  static String iso(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  static DateTime? parseDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    return DateTime.tryParse(value.toString());
  }

  static double toDouble(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0;
  }

  static int toInt(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString()) ?? 0;
  }

  /// Turns snake_case enum values from Postgres into readable labels.
  static String label(String? raw) {
    if (raw == null || raw.isEmpty) return '—';
    return raw
        .split('_')
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }

  static String initials(String? name) {
    final parts = (name ?? '').trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }
}
