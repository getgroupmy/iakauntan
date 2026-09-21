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
                    '${Fmt.money(Fmt.toDouble(r['price']))} / scan',
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
    setState(() => _busy = true);
    final priceNow = double.tryParse(_price.text.trim());
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
              const SizedBox(height: Space.sm),
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
