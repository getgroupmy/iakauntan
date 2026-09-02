/// An amount written out, for the documents people still amend with a
/// pen.
///
/// Lived inside `receipt_pdf.dart` until an expense voucher needed the
/// same thing. Two copies of this would drift, and a receipt and a
/// voucher for the same payment disagreeing about how much it was is
/// the one thing neither document may do.
library;

/// Ringgit and sen in words.
///
/// Only for the currencies this is likely to be handed over in; anything
/// else falls back to the figure, because inventing English words for a
/// currency's minor unit is how you end up printing "fifty yen cents".
String amountInWords(double amount, String currency) {
  const names = {'MYR': ('Ringgit Malaysia', 'sen'), 'USD': ('US Dollars', 'cents')};
  final pair = names[currency];
  if (pair == null) return '';

  final whole = amount.floor();
  final minor = ((amount - whole) * 100).round();
  final words = _words(whole);
  if (words.isEmpty) return '';
  return minor == 0
      ? '${pair.$1} $words only'
      : '${pair.$1} $words and ${_words(minor)} ${pair.$2} only';
}

const _ones = [
  '', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine',
  'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen',
  'seventeen', 'eighteen', 'nineteen'
];
const _tens = [
  '', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty',
  'ninety'
];

String _words(int n) {
  if (n == 0) return 'zero';
  if (n < 0 || n >= 1000000000) return '';
  final parts = <String>[];
  void chunk(int value, String scale) {
    if (value == 0) return;
    parts.add('${_under1000(value)}${scale.isEmpty ? '' : ' $scale'}');
  }

  chunk(n ~/ 1000000, 'million');
  chunk((n % 1000000) ~/ 1000, 'thousand');
  chunk(n % 1000, '');
  return parts.join(' ');
}

String _under1000(int n) {
  final out = <String>[];
  if (n >= 100) {
    out.add('${_ones[n ~/ 100]} hundred');
    n %= 100;
    if (n != 0) out.add('and');
  }
  if (n >= 20) {
    out.add(_tens[n ~/ 10]);
    if (n % 10 != 0) out.add(_ones[n % 10]);
  } else if (n > 0) {
    out.add(_ones[n]);
  }
  return out.join(' ');
}
