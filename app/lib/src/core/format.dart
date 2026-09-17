import 'package:intl/intl.dart';

/// Malaysian formatting conventions used across the app.
class Fmt {
  const Fmt._();

  static final _date = DateFormat('dd/MM/yyyy');
  static final _longDate = DateFormat('d MMM yyyy');
  static final _monthYear = DateFormat('MMM yyyy');
  static final _dateTime = DateFormat('dd/MM/yyyy HH:mm');
  static final _plain = NumberFormat('#,##0.00');

  /// One formatter per precision, built on demand.
  ///
  /// Built from the NUMBER rather than chosen from a list of cases. The
  /// first version was a `switch` with an arm for 0, an arm for 3 and a
  /// default of 2 — and the arm for 3 was unreachable, because no seeded
  /// currency has three decimals. Deleting it would have been worse than
  /// leaving it: `check_currency_decimals.py` makes the map follow the
  /// seed, so the day somebody seeds a dinar the map gains a 3 and a
  /// formatter that knew only 0 and 2 would have printed it wrongly and
  /// said nothing.
  static final _byDecimals = <int, NumberFormat>{};

  /// How many decimals a currency actually has.
  ///
  /// Two, except where ISO 4217 says otherwise. Only the exceptions are
  /// listed, because writing out the other nineteen seeded currencies to
  /// say "2" is nineteen chances to type 3.
  ///
  /// This is a second copy of `ref_currencies.decimal_places`, and it is
  /// deliberate: `money` is a pure function called from four hundred
  /// places with no async context and nothing to await a lookup on.
  /// `scripts/check_currency_decimals.py` compares the two on every
  /// build, so the copy cannot drift from the seed without the build
  /// saying so.
  static const currencyDecimalsBy = <String, int>{
    'JPY': 0,
    'KRW': 0,
    'VND': 0,
  };

  static int currencyDecimals(String currency) =>
      currencyDecimalsBy[currency.toUpperCase()] ?? 2;
  static final _compact = NumberFormat.compact(locale: 'en');
  static final _whole = NumberFormat('#,##0');
  static final _fractional = NumberFormat('#,##0.####');
  static final _rate = NumberFormat('#,##0.00####');

  /// RM 1,234.56 — the symbol is spaced, which is how it appears on
  /// Malaysian tax invoices.
  ///
  /// At the currency's own precision. `Currency.decimalPlaces` has
  /// carried this since `0002`, with a comment saying exactly why —
  /// "Yen and won have none" — and nothing read it, so every foreign
  /// invoice, statement and PDF printed `JPY 1,200.00` for an amount
  /// that has no sen. The figure was right; the way it was written was
  /// not, and it goes to the customer.
  static String money(num? value, {String currency = 'MYR'}) =>
      '${prefix(currency)}${amountAt(value, currencyDecimals(currency))}';

  /// An amount at a given precision, with no currency in front of it.
  ///
  /// Public because it is the general behaviour and the only way to
  /// assert it: no seeded currency has three decimals, so a test going
  /// through [money] can reach 0 and 2 and nothing else. The dinars
  /// exist whether or not this product has met one.
  static String amountAt(num? value, int decimals) =>
      _byDecimals.putIfAbsent(decimals, () {
        // `#,##0` with no fraction, rather than a pattern with zero
        // places after the point: a yen figure is whole, and a decimal
        // pattern prints a separator with nothing behind it.
        return NumberFormat(
          decimals == 0 ? '#,##0' : '#,##0.${'0' * decimals}',
        );
      }).format(value ?? 0);

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

  /// A percentage of a money base, rounded the way Postgres rounds it.
  ///
  /// `0009_functions.sql` and `0099_withholding_tax.sql` both spell the
  /// rule out, and it is the house rule for every percentage of money
  /// here:
  ///
  ///     v_discount := round(v_gross * new.discount_percent / 100.0, 2);
  ///     v_tax      := round(v_net * coalesce(new.tax_rate, 0) / 100.0, 2);
  ///
  /// Postgres `numeric` is exact decimal, so it gets the half-up for
  /// nothing. A double does not, and the obvious transcription --
  ///
  ///     ((base * percent / 100) * 100).roundToDouble() / 100
  ///
  /// -- was written in four places in this app and is wrong in all of
  /// them. `2.90 * 5 / 100` is 0.145 in decimal and
  /// 0.14499999999999999 in binary, so multiplying back gives
  /// 14.499999999999998 and it rounds DOWN. Fourteen sen, not fifteen.
  ///
  /// Not a rare corner. Over every amount from one sen to twenty
  /// thousand ringgit: 2,468 wrong at 6 per cent, 9,173 at 10, 4,588
  /// at 5. Eight per cent happens to be clean, which is the current SST
  /// service rate and is luck rather than a reason.
  ///
  /// And always a cent LOW, never high. The error can only knock a
  /// value that sits exactly on a half-cent downwards off it, so this
  /// under-collects — the direction a tax authority minds.
  ///
  /// So the arithmetic here is integer, and there is no float in it at
  /// all. The base is taken in its smallest unit and the percentage in
  /// hundredths of a per cent, which makes the whole thing one exact
  /// division of two ints rounded half away from zero — which is what
  /// Postgres `round` does, including for negatives, so a credit note
  /// is the exact reverse of what it reverses.
  ///
  /// [baseDecimals] is how many decimals the base carries in the
  /// database, because that decides what "its smallest unit" is. Money
  /// is 2 and is the default. A document line's gross is
  /// `numeric(18, 4)` — quantity times unit price, kept at four so a
  /// price per thousand is not lost — and passes 4.
  static double percentOf(double base, double percent, {int baseDecimals = 2}) {
    final scale = _pow10[baseDecimals];
    final units = (base * scale).round();
    final hundredths = (percent * 100).round();
    return _halfAwayFromZero(units * hundredths, 100 * scale) / 100;
  }

  /// A figure already held to [from] decimals, rounded to [to] the way
  /// Postgres `numeric` rounds it.
  ///
  /// This is the second half of a two-stage rounding, and it needs the
  /// same care as [percentOf] for the same reason. `app.calc_document_line`
  /// holds a line's gross as `numeric(18, 4)` and then rounds it to the
  /// sen, and 50 grams at RM 2.90 is a gross of 0.1450 exactly — which
  /// must charge 15 sen. Written as `(0.145 * 100).round() / 100` it is
  /// 14, because 0.145 is 0.14499999999999999 in binary and multiplying
  /// back lands just under the half.
  ///
  /// So the value is taken as an integer count of its smallest unit
  /// first — which IS exact, because it is a whole number of them — and
  /// the rounding is integer arithmetic from there.
  static double reround(double value, {required int from, required int to}) {
    final units = (value * _pow10[from]).round();
    return _halfAwayFromZero(units, _pow10[from - to]) / _pow10[to];
  }

  /// Tax on an amount at a percentage rate. The money case of
  /// [percentOf], named for what it is used for.
  static double taxOn(double amount, double ratePercent) =>
      percentOf(amount, ratePercent);

  static const _pow10 = [1, 10, 100, 1000, 10000, 100000, 1000000];

  /// `round(n / d)` with halves going away from zero, in integers.
  static int _halfAwayFromZero(int n, int d) {
    if (n < 0) return -_halfAwayFromZero(-n, d);
    final q = n ~/ d;
    return (n % d) * 2 >= d ? q + 1 : q;
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
