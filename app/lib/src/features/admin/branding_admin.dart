import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform_live.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/landing_repository.dart';

/// What the product looks like, on a screen rather than in a row.
///
/// The brand already lived on `landing_page` and already reached the
/// whole app — `app.dart` has fed `brand_colour` into `AppTheme.light`
/// and `AppTheme.dark` since it was added. What did not exist was
/// anywhere to *see* it. The landing CMS has the same fields as two text
/// boxes labelled "Brand colour" and "Brand colour, dark", between the
/// hero copy and the SEO description, and a hex string in a text box is
/// not a colour anybody can judge.
///
/// So this shows the consequences instead of the values: the logo on the
/// two backgrounds it will actually sit on, the scheme Material derives
/// from the seed in both brightnesses, and the icon at the sizes a
/// browser will draw it.
///
/// Editing the same row the CMS edits, on purpose. A second home for the
/// brand colour would be a second answer to what colour this product is.
class BrandingAdminTab extends ConsumerStatefulWidget {
  const BrandingAdminTab({super.key});

  @override
  ConsumerState<BrandingAdminTab> createState() => _BrandingAdminTabState();
}

class _BrandingAdminTabState extends ConsumerState<BrandingAdminTab> {
  /// The edits not yet saved, keyed as the patch keys they will become.
  /// Absent means untouched, which is exactly what the saver reads an
  /// absent key as — so this map *is* the patch.
  final Map<String, dynamic> _draft = {};
  bool _busy = false;

  /// What the row says now, with anything edited on top.
  Object? _value(Map<String, dynamic> row, String key) =>
      _draft.containsKey(key) ? _draft[key] : row[key];

  String? _text(Map<String, dynamic> row, String key) {
    final v = _value(row, key);
    final s = v?.toString().trim();
    return (s == null || s.isEmpty) ? null : s;
  }

  void _set(String key, Object? value) => setState(() => _draft[key] = value);

  @override
  Widget build(BuildContext context) {
    final page = ref.watch(landingPageAdminProvider);

    return AsyncView(
      value: page,
      onRetry: () => ref.invalidate(landingPageAdminProvider),
      builder: (row) {
        final r = row ?? const <String, dynamic>{};
        return SingleChildScrollView(
          child: PageBody(
            maxWidth: 980,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _MarkCard(
                  logo: _text(r, 'logo_url'),
                  logoDark: _text(r, 'logo_dark_url'),
                  wordmark: _text(r, 'wordmark') ?? 'iAkauntan',
                  busy: _busy,
                  onUpload: _upload,
                  onClear: (field) => _set(field, null),
                  onWordmark: (v) => _set('wordmark', v),
                ),
                const SizedBox(height: 16),
                _ColourCard(
                  light: _text(r, 'brand_colour'),
                  dark: _text(r, 'brand_colour_dark'),
                  onChanged: _set,
                ),
                const SizedBox(height: 16),
                _SchemeCard(
                  mode: _text(r, 'theme_mode') ?? 'system',
                  onChanged: (v) => _set('theme_mode', v),
                ),
                const SizedBox(height: 16),
                _IconCard(
                  source: _text(r, 'app_icon_url'),
                  busy: _busy,
                  onUpload: () => _upload('app_icon_url'),
                  onClear: () => _set('app_icon_url', null),
                ),
                const SizedBox(height: 16),
                _SaveBar(
                  changes: _draft.length,
                  busy: _busy,
                  onSave: _save,
                  onDiscard: () => setState(_draft.clear),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _upload(String field) async {
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
      successMessage: 'Uploaded',
      action: () async {
        url = await ref
            .read(landingAdminProvider)
            .uploadLandingLogo(
              file.bytes!,
              field,
              contentType: mimeForExtension(file.extension),
            );
      },
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      // Into the draft, not the row. Uploading is not publishing, and
      // the bytes being in the bucket is not the same as the product
      // pointing at them — Save is what does that.
      if (ok && url != null) _draft[field] = url;
    });
  }

  Future<void> _save() async {
    if (_draft.isEmpty) return;
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Branding saved',
      action: () => ref.read(landingAdminProvider).saveLandingPage(_draft),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _draft.clear();
    });
    if (ok) {
      // Both, and for different reasons. The console reads the draft
      // row; every signed-in app reads `landing_page()`, which is where
      // the colours and the wordmark come from — so this is what makes
      // the product change colour without anybody reloading.
      ref.invalidate(landingPageAdminProvider);
      invalidatePlatformTable(ref, 'landing_page');
    }
  }
}

/// What to tell storage the bytes are.
///
/// Guessed from the extension rather than trusted from the picker, which
/// reports nothing on some platforms. SVG is deliberately absent: `0161`
/// restricted the bucket to png, jpeg and webp because an SVG is the one
/// image format that is also a program, and storage would refuse it
/// anyway — this just refuses it one step earlier and more clearly.
String? mimeForExtension(String? extension) => switch (extension
    ?.toLowerCase()) {
  'png' => 'image/png',
  'jpg' || 'jpeg' => 'image/jpeg',
  'webp' => 'image/webp',
  _ => null,
};

/// The logo, on both of the backgrounds it has to work on.
class _MarkCard extends StatelessWidget {
  const _MarkCard({
    required this.logo,
    required this.logoDark,
    required this.wordmark,
    required this.busy,
    required this.onUpload,
    required this.onClear,
    required this.onWordmark,
  });

  final String? logo;
  final String? logoDark;
  final String wordmark;
  final bool busy;
  final ValueChanged<String> onUpload;
  final ValueChanged<String> onClear;
  final ValueChanged<String> onWordmark;

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'The mark',
      subtitle: 'What the product is called, and what it looks like',
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            _LogoWell(
              label: 'On light',
              url: logo,
              plate: Colors.white,
              busy: busy,
              onUpload: () => onUpload('logo_url'),
              onClear: () => onClear('logo_url'),
            ),
            _LogoWell(
              label: 'On dark',
              url: logoDark ?? logo,
              plate: const Color(0xFF14181B),
              busy: busy,
              // Falls back to the light logo above, and says so, because
              // that is what the product does — a brand with one logo is
              // the common case and should not read as a missing file.
              hint: logoDark == null && logo != null
                  ? 'Using the light logo. Upload a second one if it '
                        'disappears here.'
                  : null,
              onUpload: () => onUpload('logo_dark_url'),
              onClear: () => onClear('logo_dark_url'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        TextFormField(
          initialValue: wordmark,
          decoration: const InputDecoration(
            labelText: 'Wordmark',
            helperText: 'Shown wherever there is no room for the logo. '
                'Cannot be empty.',
          ),
          onChanged: onWordmark,
        ),
      ],
    );
  }
}

/// One logo on one background, with the two things you can do to it.
class _LogoWell extends StatelessWidget {
  const _LogoWell({
    required this.label,
    required this.url,
    required this.plate,
    required this.busy,
    required this.onUpload,
    required this.onClear,
    this.hint,
  });

  final String label;
  final String? url;
  final Color plate;
  final bool busy;
  final String? hint;
  final VoidCallback onUpload;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 420,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 6),
          Container(
            height: 110,
            decoration: BoxDecoration(
              color: plate,
              borderRadius: BorderRadius.circular(Radii.md),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            alignment: Alignment.center,
            padding: const EdgeInsets.all(Space.md),
            child: url == null
                ? Text(
                    'No logo',
                    style: TextStyle(
                      color: plate.computeLuminance() > 0.5
                          ? Colors.black45
                          : Colors.white54,
                    ),
                  )
                : Image.network(
                    url!,
                    fit: BoxFit.contain,
                    // A broken URL is the ordinary outcome of a bucket
                    // that lost a file, and a red exception box in a
                    // settings screen tells nobody what to do about it.
                    errorBuilder: (_, _, _) => const Text(
                      'That image did not load',
                      style: TextStyle(color: Colors.redAccent),
                    ),
                  ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 6),
            Text(hint!, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 6),
          Row(children: [
            TextButton.icon(
              onPressed: busy ? null : onUpload,
              icon: const Icon(Icons.upload_outlined, size: 18),
              label: const Text('Upload'),
            ),
            if (url != null)
              TextButton(
                onPressed: busy ? null : onClear,
                child: const Text('Remove'),
              ),
          ]),
        ],
      ),
    );
  }
}

/// The seed colour, and what Material makes of it.
class _ColourCard extends StatelessWidget {
  const _ColourCard({
    required this.light,
    required this.dark,
    required this.onChanged,
  });

  final String? light;
  final String? dark;
  final void Function(String key, Object? value) onChanged;

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'Colour',
      subtitle: 'One seed each way, and the scheme Material derives',
      children: [
        SeedField(
          label: 'Brand colour',
          value: light,
          fallback: AppTheme.seed,
          onChanged: (v) => onChanged('brand_colour', v),
        ),
        const SizedBox(height: 8),
        SchemePreview(
          seed: AppTheme.parseHex(light) ?? AppTheme.seed,
          brightness: Brightness.light,
        ),
        const SizedBox(height: 20),
        SeedField(
          label: 'Brand colour, dark scheme',
          value: dark,
          fallback: AppTheme.parseHex(light) ?? AppTheme.seed,
          helper: 'Optional. Left empty, the dark scheme is derived from '
              'the colour above.',
          onChanged: (v) => onChanged('brand_colour_dark', v),
        ),
        const SizedBox(height: 8),
        SchemePreview(
          seed: AppTheme.parseHex(dark) ??
              AppTheme.parseHex(light) ??
              AppTheme.seed,
          brightness: Brightness.dark,
        ),
      ],
    );
  }
}

/// A hex colour, with somewhere to see it and something to pick from.
///
/// A field and swatches rather than a colour wheel: a brand colour is a
/// value somebody already has written down, and the swatches are there
/// so the field is never the only way in.
/// Public since `0337`, which needs the same field on the sign-in
/// page's console screen for the panel colour. One field, so the two
/// places cannot disagree about what a valid colour looks like.
class SeedField extends StatefulWidget {
  const SeedField({
    super.key,
    required this.label,
    required this.value,
    required this.fallback,
    required this.onChanged,
    this.helper,
  });

  final String label;
  final String? value;
  final Color fallback;
  final String? helper;
  final ValueChanged<String?> onChanged;

  @override
  State<SeedField> createState() => _SeedFieldState();
}

class _SeedFieldState extends State<SeedField> {
  late final TextEditingController _c =
      TextEditingController(text: widget.value ?? '');

  static const _presets = <String>[
    '#0B7A6B',
    '#1D4ED8',
    '#7C3AED',
    '#BE123C',
    '#B45309',
    '#15803D',
    '#0F172A',
  ];

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _apply(String hex) {
    _c.text = hex;
    widget.onChanged(hex);
  }

  @override
  Widget build(BuildContext context) {
    final parsed = AppTheme.parseHex(widget.value);
    final bad = widget.value != null && parsed == null;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 44,
          height: 44,
          margin: const EdgeInsets.only(top: 4, right: 12),
          decoration: BoxDecoration(
            color: parsed ?? widget.fallback,
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(color: Theme.of(context).dividerColor),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _c,
                decoration: InputDecoration(
                  labelText: widget.label,
                  hintText: '#0B7A6B',
                  helperText: widget.helper,
                  errorText: bad ? 'Six hex digits after a hash' : null,
                ),
                onChanged: (v) =>
                    widget.onChanged(v.trim().isEmpty ? null : v.trim()),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: [
                  for (final hex in _presets)
                    InkWell(
                      onTap: () => _apply(hex),
                      borderRadius: BorderRadius.circular(Radii.sm),
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: AppTheme.parseHex(hex),
                          borderRadius: BorderRadius.circular(Radii.sm),
                          border: Border.all(
                            color: Theme.of(context).dividerColor,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The scheme Material derives from a seed, as the colours themselves.
///
/// Public, and separated from the card, so a test can hand it a seed and
/// look at what comes out. What it draws is not decoration: a seed that
/// produces an unreadable `onPrimary` is a seed nobody should ship, and
/// the only way to know is to look at the pair.
class SchemePreview extends StatelessWidget {
  const SchemePreview({
    super.key,
    required this.seed,
    required this.brightness,
  });

  final Color seed;
  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );

    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            brightness == Brightness.light ? 'Light' : 'Dark',
            style: TextStyle(
              color: scheme.onSurface,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Swatch('Primary', scheme.primary, scheme.onPrimary),
              _Swatch(
                'Container',
                scheme.primaryContainer,
                scheme.onPrimaryContainer,
              ),
              _Swatch('Secondary', scheme.secondary, scheme.onSecondary),
              _Swatch('Surface', scheme.surface, scheme.onSurface),
              _Swatch(
                'Surface tint',
                scheme.surfaceContainerHighest,
                scheme.onSurfaceVariant,
              ),
              _Swatch('Error', scheme.error, scheme.onError),
            ],
          ),
          const SizedBox(height: 12),
          // The two controls people actually look at, in the colours
          // they will actually be.
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Text(
                'Post',
                style: TextStyle(
                  color: scheme.onPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text('Cancel', style: TextStyle(color: scheme.primary)),
          ]),
        ],
      ),
    );
  }
}

/// One role of the scheme, with its own label drawn on it — which is
/// the only way to see whether the pair is readable.
class _Swatch extends StatelessWidget {
  const _Swatch(this.label, this.colour, this.on);

  final String label;
  final Color colour;
  final Color on;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 104,
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: colour,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        style: TextStyle(color: on, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Which of the two a visitor gets before they have chosen.
class _SchemeCard extends StatelessWidget {
  const _SchemeCard({required this.mode, required this.onChanged});

  final String mode;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'Default scheme',
      subtitle: 'What somebody sees before they have chosen',
      children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
              value: 'system',
              label: Text('Follow the device'),
              icon: Icon(Icons.brightness_auto_outlined, size: 18),
            ),
            ButtonSegment(
              value: 'light',
              label: Text('Light'),
              icon: Icon(Icons.light_mode_outlined, size: 18),
            ),
            ButtonSegment(
              value: 'dark',
              label: Text('Dark'),
              icon: Icon(Icons.dark_mode_outlined, size: 18),
            ),
          ],
          selected: {mode},
          onSelectionChanged: (s) => onChanged(s.first),
        ),
        const SizedBox(height: 10),
        Text(switch (mode) {
          'light' => 'Everybody gets the light scheme, whatever their '
              'device is set to.',
          'dark' => 'Everybody gets the dark scheme, whatever their '
              'device is set to.',
          _ => 'Each visitor gets whichever their own device prefers. '
              'This is what the product did before there was a setting.',
        }, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

/// The square source the icons are built from, and an honest account of
/// when that actually happens.
class _IconCard extends StatelessWidget {
  const _IconCard({
    required this.source,
    required this.busy,
    required this.onUpload,
    required this.onClear,
  });

  final String? source;
  final bool busy;
  final VoidCallback onUpload;
  final VoidCallback onClear;

  /// The sizes worth looking at: a browser tab, a bookmark, and the two
  /// a phone uses when the site is added to a home screen.
  static const _sizes = <double>[16, 32, 64, 192];

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'App icon',
      subtitle: 'One square image; the favicon and the web icons are '
          'built from it',
      children: [
        if (source == null)
          Text(
            'No icon uploaded. The product is using the one it shipped '
            'with.',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else
          Wrap(
            spacing: 18,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              for (final size in _sizes)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.network(
                      source!,
                      width: size,
                      height: size,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Icon(
                        Icons.broken_image_outlined,
                        size: size,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${size.toInt()}px',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
            ],
          ),
        const SizedBox(height: 12),
        Row(children: [
          TextButton.icon(
            onPressed: busy ? null : onUpload,
            icon: const Icon(Icons.upload_outlined, size: 18),
            label: const Text('Upload'),
          ),
          if (source != null)
            TextButton(
              onPressed: busy ? null : onClear,
              child: const Text('Remove'),
            ),
        ]),
        const SizedBox(height: 8),
        // Said plainly rather than left to be discovered. A console that
        // implies an upload reaches a phone is a console that will be
        // believed.
        _Note(
          'Takes effect on the next deploy. The favicon and the web icons '
          'are files inside the built bundle, so they are regenerated '
          'when the site is next built — not when this is saved.',
        ),
        const SizedBox(height: 6),
        _Note(
          'Installed Android and iOS launcher icons are not touched at '
          'all. Those are baked into a store build, and changing them '
          'means shipping a new version of the app.',
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: 15, color: Theme.of(context).hintColor),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }
}

class _SaveBar extends StatelessWidget {
  const _SaveBar({
    required this.changes,
    required this.busy,
    required this.onSave,
    required this.onDiscard,
  });

  final int changes;
  final bool busy;
  final VoidCallback onSave;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Expanded(
          child: Text(
            changes == 0
                ? 'Nothing changed.'
                : '$changes ${changes == 1 ? 'change' : 'changes'} not '
                      'saved yet.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (changes > 0)
          TextButton(
            onPressed: busy ? null : onDiscard,
            child: const Text('Discard'),
          ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: (busy || changes == 0) ? null : onSave,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(title, subtitle: subtitle),
            ...children,
          ],
        ),
      ),
    );
  }
}
