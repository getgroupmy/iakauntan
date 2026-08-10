import '../../data/models.dart';

/// Turning a payroll run into something a bank will accept.
///
/// Every Malaysian bank wants its own layout — Maybank M2E, CIMB
/// BizChannel and RHB Reflex all differ, and some want fixed-width rather
/// than delimited. Rather than guess at one and be wrong for everyone,
/// this writes a plain, fully-quoted CSV with the six fields every bulk
/// transfer needs, which every one of those portals can import or which
/// can be mapped once and reused.
abstract final class PaymentFile {
  static const header = <String>[
    'Employee No',
    'Employee Name',
    'Bank',
    'Account No',
    'Amount',
    'Reference',
  ];

  /// Only payable lines are written. A line with a [PaymentLine.problem]
  /// is deliberately left out of the file and shown on screen instead:
  /// a bank will reject the batch over one bad row, and an amount sent to
  /// a blank account number is worse than an amount not sent.
  static String csv(List<PaymentLine> lines) {
    final buffer = StringBuffer()..write(_row(header));
    for (final line in lines.where((l) => l.isPayable)) {
      buffer.write(_row([
        line.employeeNo,
        line.employeeName,
        line.bankName ?? '',
        line.bankAccountNo ?? '',
        line.amount.toStringAsFixed(2),
        line.reference,
      ]));
    }
    return buffer.toString();
  }

  /// CRLF line endings, which is what RFC 4180 asks for and what the
  /// bank portals are written against.
  static String _row(List<String> fields) =>
      '${fields.map(_escape).join(',')}\r\n';

  /// Everything is quoted rather than only the fields that need it. Names
  /// here carry commas ("Tan Wei Ming, Jr"), slashes and the a/l and a/p
  /// patronymics, and a quoted field is never ambiguous.
  static String _escape(String value) =>
      '"${value.replaceAll('"', '""').replaceAll(RegExp(r'[\r\n]+'), ' ')}"';

  /// A filename that sorts and says what it is without being opened.
  static String filename(String runNo) =>
      'payment-${runNo.toLowerCase()}.csv';

  static double total(List<PaymentLine> lines) => lines
      .where((l) => l.isPayable)
      .fold<double>(0, (sum, l) => sum + l.amount);
}
