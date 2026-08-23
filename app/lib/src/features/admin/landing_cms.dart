import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
// `RepoLanding` is an extension, and a Dart extension is only in scope
// where its declaring library is imported.
import '../../data/landing_repository.dart';

/// The corporate landing page, edited rather than deployed.
///
/// 0290 put the page in the database so the copy on the front of the
/// product could change without an app release. This is the screen that
/// changes it: the brand and the logo, the hero, the blocks of copy in
/// the order they appear, the store buttons, and the footer.
///
/// ## Nothing is blanked by omission
///
/// `platform_save_landing_page` reads an absent key as "leave it
/// alone", which is why it takes a patch and not a row: correcting the
/// tagline must not wipe the address. The form honours that by sending
/// only the fields somebody actually changed.
///
/// ## Published is a decision
///
/// The page ships unpublished, and until the switch at the top is on,
/// `landing_page()` gives a visitor nothing — the site falls back to
/// the copy the product was built with. Drafting in the open is the
/// point; publishing a draft by accident is what the switch prevents.
class LandingCmsTab extends ConsumerWidget {
  const LandingCmsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(landingPageAdminProvider);
    return AsyncView<Map<String, dynamic>?>(
      value: page,
      onRetry: () => ref.invalidate(landingPageAdminProvider),
      builder: (row) => ListView(
        padding: const EdgeInsets.all(Space.md),
        children: [
          _PageForm(existing: row),
          const SizedBox(height: Space.lg),
          const _SectionsCard(),
          const SizedBox(height: Space.lg),
          const _AppLinksCard(),
        ],
      ),
    );
  }
}

class _PageForm extends ConsumerStatefulWidget {
  const _PageForm({required this.existing});

  final Map<String, dynamic>? existing;

  @override
  ConsumerState<_PageForm> createState() => _PageFormState();
}

class _PageFormState extends ConsumerState<_PageForm> {
  static const _fields = <String, String>{
    'wordmark': 'Wordmark',
    'tagline': 'Tagline',
    'hero_headline': 'Headline',
    'hero_subhead': 'Sub-heading',
    'sign_in_label': 'Sign-in button',
    'register_label': 'Register button',
    'logo_url': 'Logo URL',
    'logo_dark_url': 'Logo URL, dark background',
    'company_name': 'Company name',
    'company_reg_no': 'Registration number',
    'address': 'Address',
    'support_email': 'Support email',
    'support_phone': 'Support phone',
    'privacy_url': 'Privacy policy URL',
    'terms_url': 'Terms URL',
    'meta_title': 'Browser tab and link preview title',
    'meta_description': 'Link preview description',
  };

  late final Map<String, TextEditingController> _c = {
    for (final key in _fields.keys)
      key: TextEditingController(text: '${widget.existing?[key] ?? ''}'),
  };
  late bool _published = widget.existing?['is_published'] == true;
  late bool _register = widget.existing?['register_enabled'] != false;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Only what changed, so an untouched field cannot overwrite an edit
  /// somebody else made while this form was open.
  Map<String, dynamic> _patch() {
    final patch = <String, dynamic>{};
    for (final key in _fields.keys) {
      final now = _c[key]!.text.trim();
      final before = '${widget.existing?[key] ?? ''}'.trim();
      if (now != before) patch[key] = now;
    }
    if (_published != (widget.existing?['is_published'] == true)) {
      patch['is_published'] = _published;
    }
    if (_register != (widget.existing?['register_enabled'] != false)) {
      patch['register_enabled'] = _register;
    }
    return patch;
  }

  Future<void> _save() async {
    final patch = _patch();
    if (patch.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Nothing has changed.')));
      return;
    }
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Landing page saved',
      action: () => ref.read(repoProvider)!.saveLandingPage(patch),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) ref.invalidate(landingPageAdminProvider);
  }

  Future<void> _uploadLogo(String field) async {
    final result = await FilePicker.platform.pickFiles(
      withData: true,
      type: FileType.image,
    );
    final file = result?.files.singleOrNull;
    if (file == null || file.bytes == null || !mounted) return;

    setState(() => _busy = true);
    String? url;
    final ok = await runWithFeedback(
      context,
      successMessage: 'Logo uploaded',
      action: () async {
        url = await ref
            .read(repoProvider)!
            .uploadLandingLogo(
              file.bytes!,
              field,
              contentType: _mimeFor(file.extension),
            );
      },
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      // Into the field rather than straight into the row: uploading is
      // not publishing, and Save is still what commits it.
      if (ok && url != null) _c[field]!.text = url!;
    });
  }

  /// What to tell storage the bytes are.
  ///
  /// Guessed from the extension rather than trusted from the picker,
  /// which reports nothing on some platforms. Wrong here means the
  /// browser downloads the logo instead of drawing it.
  static String? _mimeFor(String? extension) {
    switch (extension?.toLowerCase()) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'webp':
        return 'image/webp';
      case 'svg':
        return 'image/svg+xml';
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'The page',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                if (!_published)
                  const StatusChip('not published', compact: true),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _published,
              onChanged: _busy ? null : (v) => setState(() => _published = v),
              title: const Text('Published'),
              subtitle: const Text(
                'Off, and a visitor sees the copy the product was built '
                'with rather than a half-written page.',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _register,
              onChanged: _busy ? null : (v) => setState(() => _register = v),
              title: const Text('Offer Create an account'),
              subtitle: const Text(
                'Off leaves only Sign in, for a platform that takes its '
                'customers on by invitation.',
              ),
            ),
            const Divider(height: Space.lg),
            for (final entry in _fields.entries) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _c[entry.key],
                      maxLines: entry.key == 'address' ||
                              entry.key == 'hero_subhead' ||
                              entry.key == 'meta_description'
                          ? 3
                          : 1,
                      decoration: InputDecoration(labelText: entry.value),
                    ),
                  ),
                  if (entry.key == 'logo_url' ||
                      entry.key == 'logo_dark_url') ...[
                    const SizedBox(width: Space.sm),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _uploadLogo(entry.key),
                      icon: const Icon(Icons.upload_file, size: 16),
                      label: const Text('Upload'),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: Space.sm),
            ],
            const SizedBox(height: Space.sm),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _busy ? null : _save,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionsCard extends ConsumerWidget {
  const _SectionsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sections = ref.watch(landingSectionsAdminProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'What the page says',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _editSection(context, ref, null),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add'),
                ),
              ],
            ),
            Builder(
              builder: (context) {
                final rows = sections.valueOrNull ?? const [];
                if (sections.isLoading) {
                  return const Padding(
                    padding: EdgeInsets.all(Space.md),
                    child: LinearProgressIndicator(),
                  );
                }
                if (rows.isEmpty) {
                  return const EmptyState(
                    icon: Icons.article_outlined,
                    title: 'No blocks of copy yet',
                    message: 'The page shows its hero and nothing under it.',
                  );
                }
                return Column(
                  children: [
                    for (final r in rows)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Text('${r['sort_order']}'),
                        title: Row(
                          children: [
                            Flexible(child: Text('${r['title']}')),
                            if (r['is_active'] != true) ...[
                              const SizedBox(width: Space.sm),
                              const StatusChip('off', compact: true),
                            ],
                          ],
                        ),
                        subtitle: r['body'] == null
                            ? null
                            : Text(
                                '${r['body']}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                        onTap: () => _editSection(context, ref, r),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editSection(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic>? existing,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _SectionDialog(existing: existing),
    );
    if (saved == true) ref.invalidate(landingSectionsAdminProvider);
  }
}

class _SectionDialog extends ConsumerStatefulWidget {
  const _SectionDialog({required this.existing});

  final Map<String, dynamic>? existing;

  @override
  ConsumerState<_SectionDialog> createState() => _SectionDialogState();
}

class _SectionDialogState extends ConsumerState<_SectionDialog> {
  late final _title = TextEditingController(
    text: '${widget.existing?['title'] ?? ''}',
  );
  late final _body = TextEditingController(
    text: '${widget.existing?['body'] ?? ''}',
  );
  late final _order = TextEditingController(
    text: '${widget.existing?['sort_order'] ?? ''}',
  );
  late String _icon = '${widget.existing?['icon'] ?? 'check'}';
  late bool _active = widget.existing?['is_active'] != false;
  bool _busy = false;

  /// The icons the page can draw.
  ///
  /// A fixed list because Flutter tree-shakes icons it cannot see at
  /// build time: one looked up from an arbitrary string at run time is
  /// one that is not in the bundle.
  static const _icons = [
    'check',
    'receipt',
    'payments',
    'people',
    'inventory',
    'store',
    'insights',
    'shield',
    'cloud',
  ];

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _order.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('A block needs a title.')));
      return;
    }
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Saved',
      action: () => ref.read(repoProvider)!.saveLandingSection(
        id: widget.existing?['id'] as String?,
        title: _title.text.trim(),
        body: _body.text.trim(),
        icon: _icon,
        sortOrder: int.tryParse(_order.text.trim()),
        isActive: _active,
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Removed',
      action: () => ref
          .read(repoProvider)!
          .deleteLandingSection(widget.existing!['id'] as String),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add a block' : 'Edit the block'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _title,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _body,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Body'),
              ),
              const SizedBox(height: Space.sm),
              DropdownButtonFormField<String>(
                value: _icon,
                decoration: const InputDecoration(labelText: 'Icon'),
                items: [
                  for (final i in _icons)
                    DropdownMenuItem(value: i, child: Text(i)),
                ],
                onChanged: (v) => setState(() => _icon = v ?? 'check'),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _order,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Order',
                  helperText: 'Lower comes first. Leave blank to put it last.',
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _active,
                onChanged: (v) => setState(() => _active = v),
                title: const Text('Show on the page'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.existing != null)
          TextButton(
            onPressed: _busy ? null : _delete,
            child: const Text('Remove'),
          ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _AppLinksCard extends ConsumerWidget {
  const _AppLinksCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final links = ref.watch(landingAppLinksAdminProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Where to download it',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _editLink(context, ref, null),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add a store'),
                ),
              ],
            ),
            Builder(
              builder: (context) {
                final rows = links.valueOrNull ?? const [];
                if (links.isLoading) {
                  return const Padding(
                    padding: EdgeInsets.all(Space.md),
                    child: LinearProgressIndicator(),
                  );
                }
                if (rows.isEmpty) {
                  return const EmptyState(
                    icon: Icons.download_outlined,
                    title: 'No store buttons',
                    message:
                        'Add one for each shop the app is published in and '
                        'the page offers it.',
                  );
                }
                return Column(
                  children: [
                    for (final r in rows)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Text('${r['sort_order']}'),
                        title: Row(
                          children: [
                            Flexible(child: Text('${r['label']}')),
                            if (r['is_active'] != true) ...[
                              const SizedBox(width: Space.sm),
                              const StatusChip('off', compact: true),
                            ],
                          ],
                        ),
                        subtitle: Text(
                          '${r['url']}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                        onTap: () => _editLink(context, ref, r),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editLink(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic>? existing,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _AppLinkDialog(existing: existing),
    );
    if (saved == true) ref.invalidate(landingAppLinksAdminProvider);
  }
}

class _AppLinkDialog extends ConsumerStatefulWidget {
  const _AppLinkDialog({required this.existing});

  final Map<String, dynamic>? existing;

  @override
  ConsumerState<_AppLinkDialog> createState() => _AppLinkDialogState();
}

class _AppLinkDialogState extends ConsumerState<_AppLinkDialog> {
  late final _code = TextEditingController(
    text: '${widget.existing?['store_code'] ?? ''}',
  );
  late final _label = TextEditingController(
    text: '${widget.existing?['label'] ?? ''}',
  );
  late final _url = TextEditingController(
    text: '${widget.existing?['url'] ?? ''}',
  );
  late final _order = TextEditingController(
    text: '${widget.existing?['sort_order'] ?? ''}',
  );
  late bool _active = widget.existing?['is_active'] != false;
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    _label.dispose();
    _url.dispose();
    _order.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _url.text.trim();
    // Said here as well as in the database, because being told at the
    // form is better than being told after pressing Save.
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('A store link has to be a full https:// address.'),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Saved',
      action: () => ref.read(repoProvider)!.saveLandingAppLink(
        storeCode: _code.text.trim(),
        label: _label.text.trim(),
        url: url,
        sortOrder: int.tryParse(_order.text.trim()),
        isActive: _active,
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Removed',
      action: () => ref
          .read(repoProvider)!
          .deleteLandingAppLink('${widget.existing!['store_code']}'),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    return AlertDialog(
      title: Text(isNew ? 'Add a store' : '${widget.existing!['store_code']}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _code,
                // The code is the key, and it chooses which glyph the
                // button gets. Set once so a saved button cannot become
                // a second one for the same shop.
                enabled: isNew,
                decoration: const InputDecoration(
                  labelText: 'Store',
                  helperText:
                      'app_store, play_store, appgallery, galaxy_store, web',
                ),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _label,
                decoration: const InputDecoration(labelText: 'Button text'),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _url,
                decoration: const InputDecoration(labelText: 'Link'),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _order,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Order'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _active,
                onChanged: (v) => setState(() => _active = v),
                title: const Text('Show on the page'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (!isNew)
          TextButton(
            onPressed: _busy ? null : _delete,
            child: const Text('Remove'),
          ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
