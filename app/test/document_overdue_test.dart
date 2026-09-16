import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/models.dart';

/// When a document is overdue, and the report it has to agree with.
///
/// `BusinessDocument.isOverdue` decides one thing on screen -- the chip
/// on the document list reads "overdue" instead of the status, and the
/// settlement dialog colours the row -- and it has to mean the same
/// thing as `v_ar_aging`, which is what the aging report, the
/// collections worklist and every statement are built from.
///
/// That view says:
///
///     when d.due_date is null or current_date <= d.due_date
///       then 'current'
///
/// So an invoice due TODAY is current, not late, and the comparison is
/// on the DATE. `Todo.isOverdue` already says the same thing in its own
/// words: colouring something red at one minute past midnight on the
/// day it falls due is how a list trains somebody to ignore the colour.
///
/// The three other guards each describe a document nobody is owed
/// money on, and each is a separate reason.
void main() {
  final now = DateTime.now();
  DateTime day(int offset) =>
      DateTime(now.year, now.month, now.day + offset);

  BusinessDocument doc({
    DateTime? dueDate,
    double balance = 1000,
    double total = 1000,
    String status = 'posted',
  }) =>
      BusinessDocument(
        id: 'd1',
        docType: 'invoice',
        docNo: 'INV-0001',
        docDate: day(-30),
        contactId: 'c1',
        dueDate: dueDate,
        totalAmount: total,
        balanceAmount: balance,
        status: status,
      );

  group('the date it fell due', () {
    test('yesterday is overdue', () {
      expect(doc(dueDate: day(-1)).isOverdue, isTrue);
    });

    test('today is not', () {
      // The disagreement this test was written for. The Dart used to
      // compare `dueDate.isBefore(DateTime.now())`, and `dueDate` is a
      // date column parsed to MIDNIGHT -- so from 00:01 on the due date
      // the screen said "overdue" while `v_ar_aging` said "current" and
      // the collections worklist did not list the customer at all.
      //
      // One day wide, every invoice, every day of the year.
      expect(doc(dueDate: day(0)).isOverdue, isFalse);
    });

    test('and tomorrow is not', () {
      expect(doc(dueDate: day(1)).isOverdue, isFalse);
    });

    test('a document with no due date is never overdue', () {
      // A quotation, a cash sale, a draft nobody has dated. `v_ar_aging`
      // says 'current' for a null due date in the same breath.
      expect(doc(dueDate: null).isOverdue, isFalse);
    });
  });

  group('and whether anything is still owed', () {
    test('a paid invoice is not overdue however old', () {
      // The balance is the whole point. An invoice settled a year late
      // is history, not a debt, and a red chip on it sends somebody to
      // chase money that has arrived.
      expect(doc(dueDate: day(-365), balance: 0).isOverdue, isFalse);
    });

    test('a partly paid one still is', () {
      // The control for the line above: 400 of 1,000 outstanding is
      // still 400 owed.
      expect(doc(dueDate: day(-10), balance: 400, total: 1000).isOverdue,
          isTrue);
    });

    test('a credit balance is not a debt', () {
      // `> 0`, not `!= 0`. An over-payment leaves a negative balance,
      // and the customer is owed money rather than owing it.
      expect(doc(dueDate: day(-10), balance: -50).isOverdue, isFalse);
    });

    test('and a voided document is owed by nobody', () {
      // The row keeps its balance -- a ledger is not erased -- so
      // without this guard every cancelled invoice in the file reads as
      // overdue forever. `v_ar_aging` excludes `status <> 'void'` for
      // the same reason.
      expect(doc(dueDate: day(-10), status: 'void').isOverdue, isFalse);
    });

    test('while an ordinary posted one does not get that exemption', () {
      expect(doc(dueDate: day(-10), status: 'posted').isOverdue, isTrue);
    });
  });
}
