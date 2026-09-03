/// What a batch would do to the documents somebody has ticked.
///
/// Kept apart from the list screen because it is the part with rules in
/// it: a quotation does not post, an already-posted invoice does not
/// post again, and an action bar offering either is an action bar that
/// hands the database a request it will refuse one row at a time.
///
/// The database refuses those anyway and says so per document — see
/// 0500 — so nothing here is a security boundary. It is the difference
/// between "Post 12" and "Post 12, 4 of which cannot be posted".
library;

import '../../data/models.dart';
import 'doc_types.dart';

class BulkPlan {
  const BulkPlan({
    required this.selected,
    required this.postable,
    required this.emailable,
  });

  /// Everything ticked, whether or not an action applies to it.
  final List<BusinessDocument> selected;

  /// The ones a Post would actually put in the ledger.
  final List<BusinessDocument> postable;

  /// The ones there is any point sending.
  final List<BusinessDocument> emailable;

  bool get isEmpty => selected.isEmpty;

  /// A document that has been in the ledger cannot go in again, and one
  /// that was voided or rejected is finished with.
  static const _beforePosting = {'draft', 'pending', 'approved'};

  static BulkPlan of(
    Iterable<BusinessDocument> documents,
    Set<String> ids,
    String docType,
  ) {
    final meta = metaFor(docType);
    final selected = [
      for (final d in documents)
        if (ids.contains(d.id)) d
    ];
    return BulkPlan(
      selected: selected,
      postable: meta.posts
          ? [
              for (final d in selected)
                if (_beforePosting.contains(d.status)) d
            ]
          : const [],
      // A draft has no number a customer would recognise and no
      // agreement behind it, so sending one is not something to offer
      // in a batch — one at a time, from the document itself, is where
      // that decision belongs.
      emailable: [
        for (final d in selected)
          if (d.status != 'draft') d
      ],
    );
  }

  /// What the button says. Never a bare count: "Post 12" when every
  /// ticked document can be posted, and the shortfall named when it
  /// cannot, because the surprise afterwards is worse than the longer
  /// label.
  String postLabel() => _label('Post', postable.length);

  String emailLabel() => _label('Email', emailable.length);

  String _label(String verb, int n) {
    if (n == 0) return 'Nothing to ${verb.toLowerCase()}';
    if (n == selected.length) return '$verb $n';
    return '$verb $n of ${selected.length}';
  }

  /// What to say when the batch comes back. The failures are the point:
  /// a batch that posted 38 of 40 is a success and two things to fix.
  static String outcome(List<Map<String, dynamic>> rows, String field) {
    final done = rows.where((r) => r[field] == true).length;
    final failed = rows.length - done;
    if (rows.isEmpty) return 'Nothing to do.';
    if (failed == 0) return done == 1 ? '1 done.' : '$done done.';
    if (done == 0) return failed == 1 ? '1 could not.' : 'None of $failed could.';
    return '$done done, $failed could not.';
  }
}
