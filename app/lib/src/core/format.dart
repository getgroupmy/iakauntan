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
  static final _whole = NumberFormat('#,##0');
  static final _fractional = NumberFormat('#,##0.####');
  static final _rate = NumberFormat('#,##0.00####');

  /// RM 1,234.56 — the symbol is spaced, which is how it appears on
  /// Malaysian tax invoices.
  static String money(num? value, {String currency = 'MYR'}) =>
      '${prefix(currency)}${_plain.format(value ?? 0)}';

  /// What an amount field puts in front of the figure being typed.
  /// Shares [money]'s rule so an entered amount and a formatted one read
  /// the same way.
  static String prefix(String currency) =>
      currency == 'MYR' ? 'RM ' : '$currency ';

  static String plain(num? value) => _plain.format(value ?? 0);

  /// An exchange rate, at the precision the pair actually needs.
  ///
  /// `exchange_rates.rate` is numeric(18, 8) because thinly quoted pairs
  /// need it — IDR to MYR is around 0.00028 — but printing 4.70000000
  /// beside a US dollar invoice is noise. Two decimals minimum, six
  /// maximum, trailing zeros dropped in between.
  static String rate(num? value) => _rate.format(value ?? 0);

  static String compact(num? value) => _compact.format(value ?? 0);

  static String qty(num? value) {
    final v = value ?? 0;
    // Drop trailing zeros so 2.0000 shows as 2 but 2.5 stays 2.5.
    return v == v.roundToDouble()
        ? v.toStringAsFixed(0)
        : v.toString().replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }

  /// Share counts. Whole numbers are the norm and "340.00 shares" reads
  /// like money rather than shares, but fractional entitlements exist so
  /// the decimals are kept when there are any.
  static String shares(num? value) {
    final v = value ?? 0;
    return v == v.roundToDouble() ? _whole.format(v) : _fractional.format(v);
  }

  static String percent(num? value) {
    final v = value ?? 0;
    return '${v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2)}%';
  }

  static String date(DateTime? value) => value == null ? '—' : _date.format(value);

  static String longDate(DateTime? value) =>
      value == null ? '—' : _longDate.format(value);

  /// Month name on its own, for payroll period labels.
  /// Clock time only, for attendance rows.
  static String time(DateTime? value) =>
      value == null ? '—' : DateFormat('HH:mm').format(value.toLocal());

  /// Leave is counted in days and halves, so trim a trailing ".0".
  static String days(double value) {
    final s = value.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  /// Which day of the week a date falls on. A holiday landing on a
  /// Saturday or Sunday is the first thing anybody checks about it.
  static String weekday(DateTime? value) =>
      value == null ? '—' : DateFormat('EEEE').format(value);

  static String monthName(int month) => _monthNames[(month - 1) % 12];

  static const _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

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
