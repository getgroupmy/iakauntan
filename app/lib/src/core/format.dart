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
        : v
              .toString()
              .replaceAll(RegExp(r'0+$'), '')
              .replaceAll(RegExp(r'\.$'), '');
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

  static String date(DateTime? value) =>
      value == null ? '—' : _date.format(value);

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
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
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

  /// A figure as somebody actually typed it, or null if it is not one.
  ///
  /// The point of this is the NULL. `double.tryParse(text) ?? 0` is
  /// written in two hundred places in this app, and in most of them a
  /// zero is a harmless default. In a few it is the opposite of one:
  ///
  ///   * a contact's credit limit, where the field's own helper says
  ///     "Zero means no limit" and `0467` agrees -- `if coalesce(
  ///     v_limit, 0) <= 0 then return new` -- so a credit limit that
  ///     fails to parse does not become a small limit, it removes the
  ///     limit;
  ///   * a statutory rate, where zero is no contribution at all.
  ///
  /// Both fail OPEN, silently, on a typo. Returning null lets the field
  /// refuse instead.
  ///
  /// What it accepts is what people write in a money field here: a
  /// leading RM or MYR, a trailing per-cent sign, spaces anywhere, and
  /// grouping commas.
  ///
  /// What it REFUSES, rather than guessing at, is a comma that is not a
  /// grouping separator. Half the world writes 11,5 for eleven and a
  /// half; stripping the comma would read it as a hundred and fifteen,
  /// which on an EPF rate is a ten-fold error arrived at silently. A
  /// comma is only dropped where it separates exactly three digits, all
  /// the way along -- 1,234,567.89 -- and anything else is not a number
  /// this function is willing to have an opinion about.
  static double? typedNumber(String text) {
    var s = text.trim();
    if (s.isEmpty) return null;

    // What people put AROUND a figure rather than in it.
    s = s.replaceFirst(RegExp(r'^(RM|MYR)', caseSensitive: false), '');
    if (s.endsWith('%')) s = s.substring(0, s.length - 1);
    s = s.replaceAll(RegExp(r'\s'), '');
    if (s.isEmpty) return null;

    var sign = '';
    if (s.startsWith('-') || s.startsWith('+')) {
      if (s.startsWith('-')) sign = '-';
      s = s.substring(1);
    }

    if (s.contains(',')) {
      if (!RegExp(r'^\d{1,3}(,\d{3})+(\.\d+)?$').hasMatch(s)) return null;
      s = s.replaceAll(',', '');
    }

    // No exponents, no hex, no infinity: `double.tryParse` accepts all
    // three and none of them is a figure anybody typed into a money
    // field on purpose.
    if (!RegExp(r'^(\d+(\.\d*)?|\.\d+)$').hasMatch(s)) return null;
    return double.tryParse('$sign$s');
  }

  /// Tax on an amount at a percentage rate, rounded the way the
  /// database rounds it.
  ///
  /// `0099_withholding_tax.sql` states the rule, and it is the house
  /// rule for every percentage of money in this application:
  ///
  ///     v_gross := round(coalesce(p_gross_amount, ...), 2);
  ///     v_tax   := round(v_gross * v_rate / 100.0, 2);
  ///
  /// The base is rounded to cents FIRST, and the tax is rounded from
  /// that. Postgres `numeric` is exact decimal, so it gets the half-up
  /// right for nothing. A double does not, and the obvious Dart
  /// transcription is wrong:
  ///
  ///     ((amount * rate / 100) * 100).roundToDouble() / 100
  ///
  /// `2.90 * 5 / 100` is 0.145 in decimal and 0.14499999999999999 in
  /// binary, so the multiply-back lands on 14.499999999999998 and
  /// rounds DOWN. Fourteen sen instead of fifteen.
  ///
  /// It is not a rare corner. Measured over every amount from one sen
  /// to twenty thousand ringgit: 2,468 wrong at 6 per cent, 9,173 at
  /// 10, 4,588 at 5, 278 at 8.25 -- and always a cent LOW, because the
  /// error only ever pushes a value that sits exactly on a half-cent
  /// down off it. Eight per cent happens to be clean, which is the
  /// current SST service rate and is pure luck.
  ///
  /// Rounding the base to whole cents first removes it: an integer
  /// number of cents times a rate is exact in a double up to 2^53, and
  /// the halves that result land on values binary floating point can
  /// represent. Zero wrong over the same range at every rate tested.
  static double taxOn(double amount, double ratePercent) {
    final cents = (amount * 100).roundToDouble();
    return (cents * ratePercent / 100).roundToDouble() / 100;
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
