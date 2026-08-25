import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform_live.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/landing_repository.dart';
import '../landing/landing_content.dart';
import '../landing/landing_screen.dart';

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
          _PreviewBar(published: row?['is_published'] == true),
          const SizedBox(height: Space.lg),
          _PageForm(existing: row),
          const SizedBox(height: Space.lg),
          const _SectionsCard(),
          const SizedBox(height: Space.lg),
          const _SectionsCard(kind: 'reason'),
          const SizedBox(height: Space.lg),
          const _SectionsCard(kind: 'badge'),
          const SizedBox(height: Space.lg),
          const _StatsCard(),
          const SizedBox(height: Space.lg),
          const _TestimonialsCard(),
          const SizedBox(height: Space.lg),
          const _LogosCard(),
          const SizedBox(height: Space.lg),
          const _AppLinksCard(),
        ],
      ),
    );
  }
}

/// Look at the draft without publishing it.
///
/// `0290` gated everything the page returns on `is_published`, which is
/// right — a CMS whose half-written sentence is on the internet the
/// moment it is typed is worse than no CMS. What it left out was any
/// state in which the person writing the draft could see it: between
/// typing a testimonial and publishing the site there was nothing to
/// look at. The two ways to see a band were to publish invented copy to
/// the open internet or to unpublish and see nothing.
///
/// So `0318` added `platform_landing_preview`, which returns the same
/// payload `landing_page()` will return once published, refused to
/// anybody who is not a platform administrator. This draws it with the
/// page's own widgets.
class _PreviewBar extends ConsumerWidget {
  const _PreviewBar({required this.published});

  final bool published;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Row(
          children: [
            Icon(
              published ? Icons.public : Icons.visibility_off_outlined,
              size: 20,
              color: published ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: Space.sm),
            Expanded(
              child: Text(
                published
                    ? 'This page is live. Anybody who visits the address '
                          'sees what is below.'
                    : 'This page is a draft. Visitors see the copy the '
                          'product ships with, not yours.',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: Space.sm),
            FilledButton.icon(
              onPressed: () => _open(context, ref),
              icon: const Icon(Icons.visibility, size: 16),
              label: const Text('Preview'),
            ),
          ],
        ),
      ),
    );
  }

  void _open(BuildContext context, WidgetRef ref) {
    // Invalidated first, so pressing Preview after an edit shows the
    // edit. The provider is a future that would otherwise hold whatever
    // the draft looked like when the tab was opened.
    ref.invalidate(landingPreviewProvider);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const _PreviewScreen(),
      ),
    );
  }
}

class _PreviewScreen extends ConsumerWidget {
  const _PreviewScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = ref.watch(landingPreviewProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Preview'),
        // Said on the screen itself rather than only in the tab behind
        // it: somebody looking at a finished-looking front page should
        // not have to remember whether they published it.
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.only(bottom: Space.sm),
            child: Text(
              'The draft, as it will look once published.',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
      body: AsyncView<LandingContent>(
        value: preview,
        onRetry: () => ref.invalidate(landingPreviewProvider),
        // The page's own widgets, with the ways in inert. A preview
        // built from a second set of widgets would drift from the page
        // it claims to preview.
        builder: (content) => LandingPage(content: content, preview: true),
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
    'brand_colour': 'Brand colour (#RRGGBB)',
    'brand_colour_dark': 'Brand colour on a dark background (#RRGGBB)',
    'hero_headline': 'Headline',
    'hero_subhead': 'Sub-heading',
    // Present on the table since 0290 and read by nothing until the
    // hero became two columns. A dead column in a CMS is a field an
    // operator fills in and then cannot find on the page.
    'hero_image_url': 'Hero image URL',
    'pricing_heading': 'Pricing heading',
    'pricing_note': 'Pricing note',
    'cta_headline': 'Call to action headline',
    'cta_body': 'Call to action sub-line',
    'cta_label': 'Call to action button',
    'cta_url': 'Call to action link',
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

  /// The eight switches, in the order somebody reads the page.
  ///
  /// Keyed by column so the form, the patch and the database cannot
  /// drift: adding a switch is adding a line here.
  static const _wayIn = <String, String>{
    'bar_sign_in_desktop': 'Sign in — top bar, desktop',
    'bar_register_desktop': 'Create an account — top bar, desktop',
    'bar_sign_in_mobile': 'Sign in — top bar and menu, phone',
    'bar_register_mobile': 'Create an account — top bar and menu, phone',
    'hero_sign_in_desktop': 'Sign in — under the headline, desktop',
    'hero_register_desktop': 'Create an account — under the headline, desktop',
    'hero_sign_in_mobile': 'Sign in — under the headline, phone',
    'hero_register_mobile': 'Create an account — under the headline, phone',
  };

  late final Map<String, TextEditingController> _c = {
    for (final key in _fields.keys)
      key: TextEditingController(text: '${widget.existing?[key] ?? ''}'),
  };
  late bool _published = widget.existing?['is_published'] == true;
  late bool _register = widget.existing?['register_enabled'] != false;
  late bool _pricing = widget.existing?['show_pricing'] == true;
  // Absent reads as on, the same way `register_enabled` does: a payload
  // saved before the columns existed must not hide the way in.
  late final Map<String, bool> _ways = {
    for (final key in _wayIn.keys) key: widget.existing?[key] != false,
  };
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
    if (_pricing != (widget.existing?['show_pricing'] == true)) {
      patch['show_pricing'] = _pricing;
    }
    for (final entry in _ways.entries) {
      if (entry.value != (widget.existing?[entry.key] != false)) {
        patch[entry.key] = entry.value;
      }
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
      action: () => ref.read(landingAdminProvider).saveLandingPage(patch),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    // Including the brand: `landingContentProvider` is where the
    // signed-in app reads the product name and the logo from.
    if (ok) invalidatePlatformTable(ref, 'landing_page');
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
            .read(landingAdminProvider)
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
              value: _pricing,
              onChanged: _busy ? null : (v) => setState(() => _pricing = v),
              title: const Text('Publish the price list'),
              subtitle: const Text(
                'On, the landing page shows every module and lets a visitor '
                'tick what they need and see the month add up. Off, it says '
                'nothing about price at all.',
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
            Text(
              'Where each way in is drawn',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            const Text(
              'One switch per button, by place and by screen width. The '
              'links in the footer stay whatever is set here, so a '
              'visitor who reads to the bottom can always get in.',
            ),
            for (final entry in _wayIn.entries)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _ways[entry.key]!,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _ways[entry.key] = v),
                title: Text(entry.value),
                // Registration closed means there is no account to
                // create, so the four register switches have nothing to
                // act on until it is open again. Said here rather than
                // by hiding them: an operator who turns registration
                // back on should find their choices where they left
                // them.
                subtitle: !_register && entry.key.contains('_register_')
                    ? const Text('Waiting on Offer Create an account')
                    : null,
              ),
            const Divider(height: Space.lg),
            for (final entry in _fields.entries) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _c[entry.key],
                      maxLines:
                          entry.key == 'address' ||
                              entry.key == 'hero_subhead' ||
                              entry.key == 'cta_body' ||
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

/// The blocks of copy, of one kind.
///
/// Features and reasons are the same rows in `landing_sections` split
/// by `kind`, so this is one card shown twice rather than two cards to
/// keep in step. The saver defaults `kind` to `feature`, which is what
/// every row written before 0317 is.
class _SectionsCard extends ConsumerWidget {
  const _SectionsCard({this.kind = 'feature'});

  final String kind;

  bool get _reasons => kind == 'reason';
  bool get _badges => kind == 'badge';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sections = ref.watch(switch (kind) {
      'reason' => landingReasonsAdminProvider,
      'badge' => landingBadgesAdminProvider,
      _ => landingSectionsAdminProvider,
    });
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _badges
                        ? 'What it files under'
                        : _reasons
                        ? 'Why choose it'
                        : 'What the page says',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
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
                  return EmptyState(
                    icon: _badges
                        ? Icons.verified_outlined
                        : _reasons
                        ? Icons.thumb_up_outlined
                        : Icons.article_outlined,
                    title: _badges
                        ? 'No badges written yet'
                        : _reasons
                        ? 'No reasons written yet'
                        : 'No blocks of copy yet',
                    // Neither band is ever empty on the page: both fall
                    // back to the copy the product ships with, which
                    // describes what this repository actually does.
                    message:
                        'The page shows the copy iAkauntan ships '
                        'with until you write your own.',
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
      builder: (_) => _SectionDialog(existing: existing, kind: kind),
    );
    if (saved == true) invalidatePlatformTable(ref, 'landing_sections');
  }
}

class _SectionDialog extends ConsumerStatefulWidget {
  const _SectionDialog({required this.existing, required this.kind});

  final Map<String, dynamic>? existing;

  /// `feature` or `reason`. Sent on every save, including an edit, so
  /// a block cannot be moved between the two bands by accident and can
  /// be moved deliberately by editing it from the other tab.
  final String kind;

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
    'expenses',
    'payments',
    'people',
    'inventory',
    'store',
    'insights',
    'shield',
    'cloud',
    'gavel',
    'calculate',
    'lock',
    'devices',
    'sync_alt',
    'support',
    'schedule',
    'star',
    'trending_up',
    'handshake',
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
      action: () => ref
          .read(landingAdminProvider)
          .saveLandingSection(
            id: widget.existing?['id'] as String?,
            title: _title.text.trim(),
            body: _body.text.trim(),
            icon: _icon,
            sortOrder: int.tryParse(_order.text.trim()),
            isActive: _active,
            kind: widget.kind,
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
          .read(landingAdminProvider)
          .deleteLandingSection(widget.existing!['id'] as String),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(switch ((widget.existing == null, widget.kind)) {
        (true, 'reason') => 'Add a reason',
        (true, 'badge') => 'Add a badge',
        (true, _) => 'Add a block',
        (false, 'reason') => 'Edit the reason',
        (false, 'badge') => 'Edit the badge',
        (false, _) => 'Edit the block',
      }),
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
                decoration: InputDecoration(
                  labelText: 'Body',
                  // The strip draws an icon and a line and nothing
                  // else. A field that is stored and never rendered is
                  // worse than an absent one.
                  helperText: widget.kind == 'badge'
                      ? 'Not shown on the badge strip.'
                      : null,
                ),
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
    if (saved == true) invalidatePlatformTable(ref, 'landing_app_links');
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
      action: () => ref
          .read(landingAdminProvider)
          .saveLandingAppLink(
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
          .read(landingAdminProvider)
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

/// The band of figures on the front page.
///
/// Ships empty and the page skips the band entirely until somebody
/// writes rows. That is deliberate: a number like "8,000 businesses" is
/// a claim about the world, and the only person in a position to make
/// it is the operator who can stand behind it. Nothing here seeds an
/// example, because an example left in is a false claim on a page that
/// asks people for money.
class _StatsCard extends ConsumerWidget {
  const _StatsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(landingStatsAdminProvider);
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
                    'The numbers',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _edit(context, ref, null),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add'),
                ),
              ],
            ),
            Builder(
              builder: (context) {
                final rows = stats.valueOrNull ?? const [];
                if (stats.isLoading) {
                  return const Padding(
                    padding: EdgeInsets.all(Space.md),
                    child: LinearProgressIndicator(),
                  );
                }
                if (rows.isEmpty) {
                  return const EmptyState(
                    icon: Icons.trending_up,
                    title: 'No figures yet',
                    message:
                        'The page shows no band of numbers. Add one only '
                        'for a figure you can stand behind.',
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
                            Flexible(child: Text('${r['value']}')),
                            if (r['is_active'] != true) ...[
                              const SizedBox(width: Space.sm),
                              const StatusChip('off', compact: true),
                            ],
                          ],
                        ),
                        subtitle: Text('${r['label']}'),
                        onTap: () => _edit(context, ref, r),
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

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic>? existing,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _StatDialog(existing: existing),
    );
    if (saved == true) invalidatePlatformTable(ref, 'landing_stats');
  }
}

class _StatDialog extends ConsumerStatefulWidget {
  const _StatDialog({required this.existing});

  final Map<String, dynamic>? existing;

  @override
  ConsumerState<_StatDialog> createState() => _StatDialogState();
}

class _StatDialogState extends ConsumerState<_StatDialog> {
  late final _value = TextEditingController(
    text: '${widget.existing?['value'] ?? ''}',
  );
  late final _label = TextEditingController(
    text: '${widget.existing?['label'] ?? ''}',
  );
  late final _order = TextEditingController(
    text: '${widget.existing?['sort_order'] ?? ''}',
  );
  late String _icon = '${widget.existing?['icon'] ?? 'trending_up'}';
  late bool _active = widget.existing?['is_active'] != false;
  bool _busy = false;

  static const _icons = [
    'trending_up',
    'people',
    'store',
    'schedule',
    'star',
    'handshake',
    'insights',
    'check',
  ];

  @override
  void dispose() {
    _value.dispose();
    _label.dispose();
    _order.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_value.text.trim().isEmpty || _label.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('A figure needs both the number and what it counts.'),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Saved',
      action: () => ref
          .read(landingAdminProvider)
          .saveLandingStat(
            id: widget.existing?['id'] as String?,
            value: _value.text.trim(),
            label: _label.text.trim(),
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
          .read(landingAdminProvider)
          .deleteLandingStat(widget.existing!['id'] as String),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add a figure' : 'Edit the figure'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _value,
                decoration: const InputDecoration(
                  labelText: 'The number',
                  // Text, not a number field: the page prints this
                  // exactly as typed and nothing ever adds it up.
                  helperText:
                      'Shown exactly as you type it — 240,000, '
                      '1,200+, RM4b.',
                ),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _label,
                decoration: const InputDecoration(
                  labelText: 'What it counts',
                  helperText: 'Businesses, outlets, years.',
                ),
              ),
              const SizedBox(height: Space.sm),
              DropdownButtonFormField<String>(
                value: _icons.contains(_icon) ? _icon : 'trending_up',
                decoration: const InputDecoration(labelText: 'Icon'),
                items: [
                  for (final i in _icons)
                    DropdownMenuItem(value: i, child: Text(i)),
                ],
                onChanged: (v) => setState(() => _icon = v ?? 'trending_up'),
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

/// What customers say.
///
/// Ships empty, and the database refuses a quote with nobody's name
/// against it. An unattributed testimonial is exactly the shape an
/// invented one takes, and the software cannot check that a person said
/// a thing — only that somebody is named as having said it, and that
/// the operator is the one who put the name there.
class _TestimonialsCard extends ConsumerWidget {
  const _TestimonialsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quotes = ref.watch(landingTestimonialsAdminProvider);
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
                    'What customers say',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _edit(context, ref, null),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add'),
                ),
              ],
            ),
            Builder(
              builder: (context) {
                final rows = quotes.valueOrNull ?? const [];
                if (quotes.isLoading) {
                  return const Padding(
                    padding: EdgeInsets.all(Space.md),
                    child: LinearProgressIndicator(),
                  );
                }
                if (rows.isEmpty) {
                  return const EmptyState(
                    icon: Icons.format_quote,
                    title: 'No testimonials yet',
                    message:
                        'The page shows none. Add only what a customer '
                        'actually said, with their name against it.',
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
                            Flexible(
                              child: Text(
                                r['company'] == null
                                    ? '${r['author']}'
                                    : '${r['author']} — ${r['company']}',
                              ),
                            ),
                            if (r['is_active'] != true) ...[
                              const SizedBox(width: Space.sm),
                              const StatusChip('off', compact: true),
                            ],
                          ],
                        ),
                        subtitle: Text(
                          '${r['quote']}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _edit(context, ref, r),
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

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic>? existing,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _TestimonialDialog(existing: existing),
    );
    if (saved == true) invalidatePlatformTable(ref, 'landing_testimonials');
  }
}

class _TestimonialDialog extends ConsumerStatefulWidget {
  const _TestimonialDialog({required this.existing});

  final Map<String, dynamic>? existing;

  @override
  ConsumerState<_TestimonialDialog> createState() => _TestimonialDialogState();
}

class _TestimonialDialogState extends ConsumerState<_TestimonialDialog> {
  late final _quote = TextEditingController(
    text: '${widget.existing?['quote'] ?? ''}',
  );
  late final _author = TextEditingController(
    text: '${widget.existing?['author'] ?? ''}',
  );
  late final _company = TextEditingController(
    text: '${widget.existing?['company'] ?? ''}',
  );
  late final _order = TextEditingController(
    text: '${widget.existing?['sort_order'] ?? ''}',
  );
  late bool _active = widget.existing?['is_active'] != false;
  bool _busy = false;

  @override
  void dispose() {
    _quote.dispose();
    _author.dispose();
    _company.dispose();
    _order.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_quote.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A testimonial needs a quote.')),
      );
      return;
    }
    // Said here as well as in the database, so somebody typing it finds
    // out before they press Save rather than after.
    if (_author.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('A quote needs the name of whoever said it.'),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Saved',
      action: () => ref
          .read(landingAdminProvider)
          .saveLandingTestimonial(
            id: widget.existing?['id'] as String?,
            quote: _quote.text.trim(),
            author: _author.text.trim(),
            company: _company.text.trim(),
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
          .read(landingAdminProvider)
          .deleteLandingTestimonial(widget.existing!['id'] as String),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.existing == null ? 'Add a testimonial' : 'Edit the testimonial',
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _quote,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'What they said'),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _author,
                decoration: const InputDecoration(
                  labelText: 'Who said it',
                  helperText:
                      'Required. A quote with no name against it is '
                      'not something to put on a front page.',
                ),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _company,
                decoration: const InputDecoration(
                  labelText: 'Their company',
                  helperText: 'Optional.',
                ),
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

/// The wall of customer logos.
///
/// Ships empty. Putting a company's mark on a page says they are a
/// customer, which is theirs to agree to.
class _LogosCard extends ConsumerWidget {
  const _LogosCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logos = ref.watch(landingLogosAdminProvider);
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
                    'Customer logos',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _edit(context, ref, null),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add'),
                ),
              ],
            ),
            Builder(
              builder: (context) {
                final rows = logos.valueOrNull ?? const [];
                if (logos.isLoading) {
                  return const Padding(
                    padding: EdgeInsets.all(Space.md),
                    child: LinearProgressIndicator(),
                  );
                }
                if (rows.isEmpty) {
                  return const EmptyState(
                    icon: Icons.workspaces_outline,
                    title: 'No customer logos yet',
                    message:
                        'The page shows no logo wall. Add a mark only '
                        'with that company\'s agreement.',
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
                            Flexible(child: Text('${r['name']}')),
                            if (r['is_active'] != true) ...[
                              const SizedBox(width: Space.sm),
                              const StatusChip('off', compact: true),
                            ],
                          ],
                        ),
                        subtitle: Text(
                          '${r['logo_url']}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _edit(context, ref, r),
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

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic>? existing,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _LogoDialog(existing: existing),
    );
    if (saved == true) invalidatePlatformTable(ref, 'landing_logos');
  }
}

class _LogoDialog extends ConsumerStatefulWidget {
  const _LogoDialog({required this.existing});

  final Map<String, dynamic>? existing;

  @override
  ConsumerState<_LogoDialog> createState() => _LogoDialogState();
}

class _LogoDialogState extends ConsumerState<_LogoDialog> {
  late final _name = TextEditingController(
    text: '${widget.existing?['name'] ?? ''}',
  );
  late final _url = TextEditingController(
    text: '${widget.existing?['logo_url'] ?? ''}',
  );
  late final _order = TextEditingController(
    text: '${widget.existing?['sort_order'] ?? ''}',
  );
  late bool _active = widget.existing?['is_active'] != false;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _order.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A logo needs the name of whose it is.')),
      );
      return;
    }
    if (!_url.text.trim().startsWith('http')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A logo needs a full https address.')),
      );
      return;
    }
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Saved',
      action: () => ref
          .read(landingAdminProvider)
          .saveLandingLogo(
            id: widget.existing?['id'] as String?,
            name: _name.text.trim(),
            logoUrl: _url.text.trim(),
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
          .read(landingAdminProvider)
          .deleteLandingLogo(widget.existing!['id'] as String),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add a logo' : 'Edit the logo'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Whose logo it is',
                ),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _url,
                decoration: const InputDecoration(
                  labelText: 'Image address',
                  helperText:
                      'A full https address. Shown as their name if '
                      'the image will not load.',
                ),
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
