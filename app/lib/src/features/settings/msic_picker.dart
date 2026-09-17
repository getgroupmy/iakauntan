import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// What SSM registers a company's business activity as.
///
/// `ref_msic_codes` has been in `0002` since the second migration and
/// seeded in `0011`, with a trigram index on `description` so it can be
/// searched by what a business actually does. Nothing read it. The
/// onboarding form declared an `_msicCode` that nothing ever assigned,
/// so every company created through it was registered with none; the
/// company card asked for the five digits in a free-text box, against a
/// list of them sitting in the database.
///
/// A wrong MSIC code is a misstatement on the incorporation and on
/// every annual return after it, and it is exactly the kind of thing
/// nobody types correctly from memory.

/// Whether a code is the shape MSIC 2008 uses.
///
/// Five digits, as `0002` says. Checked so a typed code that is not one
/// is refused here rather than accepted and carried into a filing.
bool msicLooksValid(String code) => RegExp(r'^[0-9]{5}$').hasMatch(code.trim());

/// How one reads in a list.
String msicLabel(Map<String, dynamic> row) =>
    '${row['code']} · ${row['description']}';

/// The codes worth showing for what somebody typed.
///
/// Ranked rather than filtered: a code typed in full is what they meant
/// and goes first, then anything whose code starts that way, then the
/// descriptions — because "bakery" is how a baker looks for 10710 and
/// "107" is how somebody half-remembering it does. Both are the same
/// box.
List<Map<String, dynamic>> msicMatches(
  Iterable<Map<String, dynamic>> all,
  String query,
) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return all.toList();
  final exact = <Map<String, dynamic>>[];
  final byCode = <Map<String, dynamic>>[];
  final byWords = <Map<String, dynamic>>[];
  for (final r in all) {
    final code = '${r['code']}'.toLowerCase();
    if (code == q) {
      exact.add(r);
    } else if (code.startsWith(q)) {
      byCode.add(r);
    } else if ('${r['description']}'.toLowerCase().contains(q) ||
        '${r['category'] ?? ''}'.toLowerCase().contains(q)) {
      byWords.add(r);
    }
  }
  return [...exact, ...byCode, ...byWords];
}

/// What the field shows for a code already chosen.
///
/// The code with its description where the list knows it, and the bare
/// code where it does not — a company registered under a code since
/// retired still has that code, and blanking it would look like the
/// company had none.
String msicSummary(Iterable<Map<String, dynamic>> all, String? code) {
  if (code == null || code.trim().isEmpty) return 'Not set';
  for (final r in all) {
    if ('${r['code']}' == code.trim()) return msicLabel(r);
  }
  return code.trim();
}

/// Choose a business activity.
Future<String?> pickMsicCode(BuildContext context, {String? current}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _MsicPicker(current: current),
    );

class _MsicPicker extends ConsumerStatefulWidget {
  const _MsicPicker({this.current});

  final String? current;

  @override
  ConsumerState<_MsicPicker> createState() => _MsicPickerState();
}

class _MsicPickerState extends ConsumerState<_MsicPicker> {
  final _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final codes = ref.watch(msicCodesProvider);
    final typed = _query.text.trim();
    final small = Theme.of(context).textTheme.bodySmall;

    return AlertDialog(
      title: const Text('What does this business do?'),
      content: SizedBox(
        width: 560,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('msic-search'),
              controller: _query,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'The activity, or the code',
                helperText:
                    'MSIC 2008 — what SSM registers the business '
                    'under, and what the annual return repeats.',
              ),
            ),
            const SizedBox(height: Space.sm),
            Expanded(
              child: AsyncView<List<Map<String, dynamic>>>(
                value: codes,
                onRetry: () => ref.invalidate(msicCodesProvider),
                builder: (all) {
                  final rows = msicMatches(all, typed);
                  if (rows.isEmpty) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Nothing in the list matches that.', style: small),
                        // The seed is a working subset rather than the
                        // whole of MSIC 2008, so a real code that is
                        // not in it has to be enterable.
                        if (msicLooksValid(typed))
                          TextButton(
                            key: const ValueKey('msic-use-typed'),
                            onPressed: () => Navigator.of(context).pop(typed),
                            child: Text('Use $typed anyway'),
                          ),
                      ],
                    );
                  }
                  return ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, i) => ListTile(
                      dense: true,
                      title: Text('${rows[i]['description']}'),
                      subtitle: Text(
                        [
                          '${rows[i]['code']}',
                          if (rows[i]['category'] != null)
                            '${rows[i]['category']}',
                        ].join(' · '),
                        style: small,
                      ),
                      selected: rows[i]['code'] == widget.current,
                      onTap: () =>
                          Navigator.of(context).pop('${rows[i]['code']}'),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
