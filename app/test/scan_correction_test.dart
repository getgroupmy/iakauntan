import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/shared/scan_runner.dart';

/// What the person corrected, on its way to the row that keeps it.
///
/// `0684`. The correction is the only ground truth this system
/// produces — somebody holding the paper, looking at the reading beside
/// it, putting a figure right — and until this it was handed to the
/// form and dropped. Every question about which reader is better, and
/// whether a cheaper one is actually cheaper, is unanswerable without
/// it.
///
/// Two things are asserted here and nowhere else.
///
/// THAT IT IS SENT AT ALL, AND SENT EVERY TIME. Including when nothing
/// was changed: a reading accepted as it stands is the reader being
/// RIGHT, which is the datum the whole count is built on. Send only the
/// corrections and the denominator is nothing, and every reader scores
/// 0% for ever.
///
/// AND THAT A FAILURE TO SEND IT LOSES NOTHING ELSE. This is a note
/// about a reading. The bill it came from is the thing that matters,
/// and a note that will not write must not take the bill with it.
void main() {
  const read = OcrExtraction(
    supplierName: 'TM Technology Services Sdn Bhd',
    subtotal: 316.95,
    taxAmount: 17.94,
    totalAmount: 334.89,
  );

  /// A pumped widget that hands its `WidgetRef` to [body].
  ///
  /// These helpers take a ref rather than a repo — they are called from
  /// inside the intake flow, which has one — so reaching them from a
  /// test means building something that has one too.
  Future<void> run(
    WidgetTester tester,
    Repo repo,
    Future<void> Function(WidgetRef ref) body,
  ) async {
    late WidgetRef captured;
    await tester.pumpWidget(ProviderScope(
      overrides: [repoProvider.overrideWithValue(repo)],
      child: MaterialApp(
        home: Consumer(builder: (context, ref, _) {
          captured = ref;
          return const SizedBox.shrink();
        }),
      ),
    ));
    await body(captured);
  }

  testWidgets('the accepted reading is filed against the attachment',
      (tester) async {
    final repo = _FakeRepo();
    await run(tester, repo,
        (ref) => rememberCorrection(ref,
            attachmentId: 'att-1', accepted: read));

    expect(repo.attachmentId, 'att-1');
    expect(repo.sent, isNotNull);
    // The figures, not a summary of them, and under the names the SQL
    // diffs on. `app.scan_corrected_fields` reads `total_amount`; send
    // `totalAmount` and every scan looks corrected in that field for
    // ever, with nothing anywhere saying why.
    expect(repo.sent!['total_amount'], 334.89);
    expect(repo.sent!['subtotal'], 316.95);
    expect(repo.sent!['tax_amount'], 17.94);
    expect(repo.sent!['supplier_name'],
        'TM Technology Services Sdn Bhd');
  });

  testWidgets('and is filed even when nothing was changed', (tester) async {
    // The case that looks skippable and is the one the count needs. A
    // reading accepted as it stands is the reader being right; record
    // only the corrections and every reader has a denominator of
    // nothing and scores zero for ever.
    final repo = _FakeRepo();
    await run(tester, repo,
        (ref) => rememberCorrection(ref,
            attachmentId: 'att-2', accepted: read));

    expect(repo.calls, 1);
  });

  testWidgets('a note that will not write does not take the bill with it',
      (tester) async {
    // Best effort on purpose. By the time this runs the person has
    // accepted a reading and the caller is about to build a document
    // out of it; throwing here would lose a corrected bill in order to
    // report a failed statistic.
    final repo = _FakeRepo(throws: true);
    await run(tester, repo,
        (ref) => rememberCorrection(ref,
            attachmentId: 'att-3', accepted: read));

    expect(repo.calls, 1);
  });

  testWidgets('a failed kind note does not stop the correction note',
      (tester) async {
    // `0614` and `0684` are two notes about one reading, sent by two
    // calls, and they fail independently on purpose. Folding them into
    // one would mean a reading with no kind on it — which is every
    // reading before 0614 — writing no correction either.
    final repo = _FakeRepo();
    await run(tester, repo, (ref) async {
      // This one reaches `client` through an extension body and throws;
      // `rememberDocumentKind` swallows it.
      await rememberDocumentKind(ref,
          attachmentId: 'att-4',
          accepted: const OcrExtraction(documentKind: 'bill'));
      await rememberCorrection(ref,
          attachmentId: 'att-4', accepted: read);
    });

    expect(repo.calls, 1);
    expect(repo.attachmentId, 'att-4');
  });
}

/// Answers `callRpc`, which is where this has to be caught.
///
/// `noteScanCorrection` is on `extension RepoOcr on Repo`, and a Dart
/// extension method binds to the STATIC type of the receiver — so a
/// fake declaring it would never be called, the real body would run,
/// and the assertions here would all read null while nothing said why.
/// That happened on the first version of this file.
/// `callRpc` is on the class, so it is the seam. See
/// docs/widget-tests.md.
class _FakeRepo implements Repo {
  _FakeRepo({this.throws = false});

  final bool throws;
  int calls = 0;
  String? attachmentId;
  Map<String, dynamic>? sent;

  // Read by `noteScanCorrection` before it calls anything. Left off the
  // first version of this file, so every call died in `noSuchMethod`
  // and was swallowed by the best-effort catch — which looks exactly
  // like the call never being made.
  @override
  String get orgId => 'org-1';

  @override
  Future<dynamic> callRpc(String fn, {Map<String, dynamic>? params}) async {
    if (fn != 'ocr_note_correction') {
      throw UnimplementedError('unexpected RPC $fn');
    }
    calls++;
    attachmentId = params?['p_attachment_id'] as String?;
    sent = (params?['p_accepted'] as Map).cast<String, dynamic>();
    if (throws) throw Exception('the row would not write');
    return const <String>[];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'the scan flow called Repo.${invocation.memberName}, which this '
        'fake does not answer',
      );
}
