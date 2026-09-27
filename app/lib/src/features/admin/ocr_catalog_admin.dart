import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
// `RepoOcrCatalog` is an extension, and a Dart extension is only in
// scope where its declaring library is imported.
import '../../data/ocr_repository.dart';

/// The readers on offer, and what each one costs a scan.
///
/// 0113 wrote `platform_set_ocr_provider` so a reader would have a
/// shape worth naming rather than being another blob in
/// `platform_settings`, and nothing ever called it. Adding a reader,
/// correcting a price or retiring one has meant hand-written SQL
/// against production — on a table that decides what every tenant is
/// charged per scan.
///
/// ## Nothing is blanked by omission
///
/// The function takes null to mean "leave this alone", which is why it
/// exists instead of an update: correcting a price must not wipe the
/// endpoint. The editor honours that by sending only the fields that
/// were actually changed, so a half-filled form cannot quietly empty a
/// column somebody else set.
///
/// ## Retiring, not deleting
///
/// There is no delete. A reader that has scanned anything is referenced
/// by the credit ledger and by whichever companies chose it, so it goes
/// inactive and stops being offered rather than disappearing from under
/// its own history.
///
/// ## Which one a company gets
///
/// Switching a reader on here says it is ON OFFER. It does not say
/// anybody is using it, and until `0678` there was no way to say that
/// at all: the reader a company that had never chosen one fell back to
/// was the literal `'claude'` inside `ocr_status`. So retiring Claude
/// and switching Gemini on — exactly the pair of taps this screen
/// invites — left every such company pointed at a reader that the
/// tenant's own save would then refuse, with `Claude is not available`
/// and no control anywhere to fix it. The dropdown at the top of this
/// list is the missing half.
class OcrCatalogAdminTab extends ConsumerWidget {
  const OcrCatalogAdminTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(ocrProviderCatalogProvider);

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('Add a reader'),
      ),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: catalog,
        onRetry: () => ref.invalidate(ocrProviderCatalogProvider),
        skeleton: const ListSkeleton(rows: 6, leading: false),
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.document_scanner_outlined,
              title: 'No readers in the catalog',
              message:
                  'Add one and it becomes selectable by every company '
                  'without an app release.',
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              _DefaultReader(readers: rows),
              const Divider(height: 1),
              for (final r in rows)
                ListTile(
                  title: Row(
                    children: [
                      Flexible(child: Text('${r['name'] ?? r['code']}')),
                      if (r['is_active'] != true) ...[
                        const SizedBox(width: Space.sm),
                        const StatusChip('inactive', compact: true),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    [
                      '${r['code']}',
                      '${r['kind']}',
                      if (r['model'] != null) '${r['model']}',
                      if (r['runs_on_device'] == true) 'on device',
                      if (r['takes_key'] == true) 'takes a key',
                    ].join(' · '),
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: Text(
                    Fmt.toDouble(r['price']) <= 0
                        ? 'Free'
                        : '${Fmt.money(Fmt.toDouble(r['price']))} / scan',
                  ),
                  onTap: () => _edit(context, ref, r),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic>? existing,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ReaderDialog(existing: existing),
    );
    if (saved == true) ref.invalidate(ocrProviderCatalogProvider);
  }
}

class _ReaderDialog extends ConsumerStatefulWidget {
  const _ReaderDialog({required this.existing});

  final Map<String, dynamic>? existing;

  @override
  ConsumerState<_ReaderDialog> createState() => _ReaderDialogState();
}

class _ReaderDialogState extends ConsumerState<_ReaderDialog> {
  late final _code = TextEditingController(
    text: '${widget.existing?['code'] ?? ''}',
  );
  late final _name = TextEditingController(
    text: '${widget.existing?['name'] ?? ''}',
  );
  late final _kind = TextEditingController(
    text: '${widget.existing?['kind'] ?? 'openai'}',
  );
  late final _endpoint = TextEditingController(
    text: '${widget.existing?['endpoint'] ?? ''}',
  );
  late final _model = TextEditingController(
    text: '${widget.existing?['model'] ?? ''}',
  );
  late final _price = TextEditingController(
    text: widget.existing == null
        ? ''
        : Fmt.toDouble(widget.existing!['price']).toStringAsFixed(2),
  );
  late final _blurb = TextEditingController(
    text: '${widget.existing?['blurb'] ?? ''}',
  );
  late bool _active = widget.existing?['is_active'] != false;

  /// Whether this reader costs a company anything.
  ///
  /// Not a column. A price of zero IS free — `ocr_begin` writes a scan
  /// charged at zero and never touches the credit ledger, and
  /// `outOfCredit` is false at any balance — so a second column
  /// recording the same fact would be a second chance for the two to
  /// disagree. What was missing was a way to SAY it: the only control
  /// was a price box, and a free reader was a box somebody had to
  /// think to type `0` into.
  ///
  /// A new reader starts chargeable, which is the safer default: a
  /// reader wrongly marked free is scans given away, and a reader
  /// wrongly priced is a number somebody notices.
  late bool _free = widget.existing != null &&
      Fmt.toDouble(widget.existing!['price']) <= 0;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_code, _name, _kind, _endpoint, _model, _price, _blurb]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Only what changed. The function reads null as "leave it", so
  /// sending an untouched field back would be fine — but sending an
  /// emptied one as an empty string would not, and this keeps the two
  /// cases apart.
  String? _changed(TextEditingController c, String key) {
    final now = c.text.trim();
    final before = '${widget.existing?[key] ?? ''}'.trim();
    if (now == before) return null;
    return now;
  }

  Future<void> _save() async {
    final code = _code.text.trim();
    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A reader needs a code.')),
      );
      return;
    }
    if (!_free && (double.tryParse(_price.text.trim()) ?? 0) <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'A chargeable reader needs a price. Mark it free instead if '
            'it costs a company nothing.',
          ),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    // Free is zero, and it is sent rather than inferred: a reader
    // switched from chargeable to free has a price in the box that
    // nobody cleared, and leaving it would mean the word said one
    // thing and the ledger did another.
    final priceNow = _free ? 0.0 : double.tryParse(_price.text.trim());
    final priceBefore = widget.existing == null
        ? null
        : Fmt.toDouble(widget.existing!['price']);

    final ok = await runWithFeedback(
      context,
      successMessage: 'Catalog updated',
      action: () => ref.read(platformRepoProvider).setOcrProvider(
        code,
        name: _changed(_name, 'name'),
        kind: _changed(_kind, 'kind'),
        endpoint: _changed(_endpoint, 'endpoint'),
        model: _changed(_model, 'model'),
        price: priceNow != priceBefore ? priceNow : null,
        isActive: _active != (widget.existing?['is_active'] != false)
            ? _active
            : (widget.existing == null ? _active : null),
        blurb: _changed(_blurb, 'blurb'),
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    return AlertDialog(
      title: Text(isNew ? 'Add a reader' : '${widget.existing!['code']}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _code,
                // The code is the key every company's setting points at.
                // Changing it would strand them on a reader that no
                // longer exists, so it is set once.
                enabled: isNew,
                decoration: const InputDecoration(
                  labelText: 'Code',
                  helperText: 'What a company stores when it picks this',
                ),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _kind,
                decoration: const InputDecoration(
                  labelText: 'Kind',
                  helperText: 'How the edge function talks to it',
                ),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _endpoint,
                decoration: const InputDecoration(labelText: 'Endpoint'),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _model,
                decoration: const InputDecoration(labelText: 'Model'),
              ),
              const SizedBox(height: Space.md),
              // Said in words before it is said in ringgit. What an
              // operator is deciding is whether this reader costs a
              // company anything; the number is only how much.
              SegmentedButton<bool>(
                key: const ValueKey('reader-charging'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('Chargeable')),
                  ButtonSegment(value: true, label: Text('Free')),
                ],
                selected: {_free},
                onSelectionChanged: (v) => setState(() => _free = v.first),
              ),
              const SizedBox(height: Space.sm),
              if (_free)
                Text(
                  'Companies are not charged for this reader and it does '
                  'not touch their credit balance. Whatever it costs the '
                  'platform is still spent — a free reader on the '
                  'platform\'s own key is scans the platform pays for.',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.scheme.onSurfaceVariant,
                  ),
                )
              else
                TextField(
                  controller: _price,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Price per scan',
                    helperText: 'Ringgit, charged against purchased credit',
                  ),
                ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _blurb,
                decoration: const InputDecoration(
                  labelText: 'Blurb',
                  helperText: 'What a company reads when choosing',
                ),
              ),
              SwitchListTile(
                value: _active,
                onChanged: (v) => setState(() => _active = v),
                title: const Text('Offered to companies'),
                subtitle: const Text(
                  'Turning this off retires the reader. Nothing is '
                  'deleted — companies that used it keep their history.',
                ),
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}

/// Which reader a company that has never chosen one is handed.
///
/// The other half of the switch above it. `is_active` decides what is
/// ON OFFER; this decides what is GIVEN, and the two were never the
/// same question — a catalog where four readers are active still has
/// to hand exactly one of them to a company that has expressed no
/// opinion.
///
/// Only the usable ones are listed. `platform_set_default_ocr_provider`
/// refuses a reader that is switched off or has no model set, so
/// offering one here would be offering a choice whose save cannot
/// succeed; and the point of the setting is that the fallback is never
/// something the tenant's own save would refuse.
class _DefaultReader extends ConsumerWidget {
  const _DefaultReader({required this.readers});

  final List<Map<String, dynamic>> readers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Active, and with a model where the kind needs one — the same
    // test `app.ocr_provider_ready` applies, because a dropdown that
    // offers what the RPC refuses is a dropdown that lies.
    final usable = readers.where((r) {
      if (r['is_active'] != true) return false;
      final kind = '${r['kind']}';
      if (kind != 'anthropic' && kind != 'openai') return true;
      return '${r['model'] ?? ''}'.trim().isNotEmpty;
    }).toList();

    final current = ref.watch(ocrDefaultProviderProvider);

    return Padding(
      padding: const EdgeInsets.all(Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            'What a new company gets',
            subtitle:
                'A company that has never picked a reader is offered this '
                'one. Switching a reader on above only puts it on the '
                'list — it does not hand it to anybody.',
          ),
          const SizedBox(height: Space.sm),
          if (usable.isEmpty)
            Text(
              'No reader is both switched on and finished, so nothing can '
              'be the default. Switch one on and give it a model.',
              style: TextStyle(fontSize: 12, color: context.colors.warning),
            )
          else
            DropdownButtonFormField<String>(
              key: const ValueKey('default-reader'),
              initialValue:
                  usable.any((r) => '${r['code']}' == current.value?.provider)
                  ? current.value?.provider
                  : null,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'Default reader',
                // Named rather than left blank while it loads: a blank
                // dropdown on a screen that decides what every company
                // gets reads as "none", which is never true.
                helperText: current.isLoading
                    ? 'Reading what companies are getting now…'
                    : 'Companies that chose their own keep it.',
                // Free or not is the difference between having a
                // fallback and not having one, so it is shown on the
                // item rather than left to be looked up above.
                //
                // `initialValue` matches on the code alone, so the
                // label may say a price that has just been edited in
                // the dialog above; the list is invalidated on save.
                
              ),
              items: [
                for (final r in usable)
                  DropdownMenuItem(
                    value: '${r['code']}',
                    child: Text(
                      '${r['name'] ?? r['code']}'
                      '${Fmt.toDouble(r['price']) <= 0 ? ' — free' : ''}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (code) async {
                if (code == null) return;
                final ok = await runWithFeedback(
                  context,
                  doing: 'setting the default reader',
                  action: () => ref
                      .read(platformRepoProvider)
                      .setDefaultOcrProvider(code),
                  successMessage: 'New companies get this reader',
                );
                if (ok) ref.invalidate(ocrDefaultProviderProvider);
              },
            ),
          // What the second job of this reader is, said plainly.
          //
          // A platform that sets a chargeable default has not made a
          // small pricing decision — it has switched the fallback off.
          // That is invisible from the dropdown itself, and the day it
          // matters is the day a vendor is down, which is the worst
          // day to find out.
          if (current.value case final d? when d.provider.isNotEmpty) ...[
            const SizedBox(height: Space.sm),
            Text(
              d.isFallback
                  ? '${d.name} is free, so it is also the fallback: a scan '
                        'that fails on the reader a company chose is '
                        'retried on this one, once, at no charge to them.'
                  : d.runsOnDevice
                  ? '${d.name} runs on the phone, so there is no fallback. '
                        'A scan that fails on a company\'s chosen reader '
                        'fails — a server cannot retry on the device.'
                  : 'There is no fallback. ${d.name} costs '
                        '${Fmt.money(d.price)} a scan, and a reader used '
                        'without asking must not be charged for, so a scan '
                        'that fails on a company\'s chosen reader fails. '
                        'Mark a reader free and make it the default to turn '
                        'the fallback on.',
              style: TextStyle(
                fontSize: 12,
                color: d.isFallback
                    ? context.scheme.onSurfaceVariant
                    : context.colors.warning,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
