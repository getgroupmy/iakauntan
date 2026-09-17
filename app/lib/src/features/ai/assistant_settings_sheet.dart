import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
// `RepoAiSettings` is an extension, and a Dart extension is only in
// scope where its declaring library is imported.
import '../../data/ai_repository.dart';

/// Which model answers this company's questions, and whose key pays.
///
/// 0536 made both of those a setting. A company that never opens this
/// sheet follows whatever the platform is using and keeps following it
/// when the platform changes its mind, which is the right default: most
/// people do not want to choose a model, they want an answer.
///
/// The two reasons to open it are the two this sheet is arranged
/// around. A company with an account of its own — a key it already pays
/// for, or a gateway on its own network — puts it in here. And a
/// company that cares which model reads its books picks one.
///
/// ## What it will not show you
///
/// Whether a key is on file, and when it was set. Never the key. The
/// row this sheet reads has no column that could carry one.
class AssistantSettingsSheet extends ConsumerStatefulWidget {
  const AssistantSettingsSheet({super.key});

  @override
  ConsumerState<AssistantSettingsSheet> createState() =>
      _AssistantSettingsSheetState();
}

class _AssistantSettingsSheetState
    extends ConsumerState<AssistantSettingsSheet> {
  /// Null means "follow the platform", which is a different thing from
  /// "no provider" and the reason these are nullable rather than
  /// defaulted.
  String? _provider;
  String? _model;
  String _keySource = 'platform';
  bool _enabled = false;
  bool _loaded = false;

  void _seed(Map<String, dynamic> status) {
    if (_loaded) return;
    _loaded = true;
    _enabled = status['is_enabled'] == true;
    _keySource = '${status['key_source'] ?? 'platform'}';
    if (status['follows_platform'] != true) {
      _provider = status['provider_code'] as String?;
      _model = status['model_id'] as String?;
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(aiStatusProvider);
    final providers = ref.watch(aiProvidersProvider);
    final models = ref.watch(aiModelsProvider);
    final theme = Theme.of(context);

    return AsyncView<Map<String, dynamic>>(
      value: status,
      onRetry: () => ref.invalidate(aiStatusProvider),
      builder: (s) {
        _seed(s);
        final live = [
          for (final p in providers.valueOrNull ?? const [])
            if (p['is_active'] == true) p,
        ];
        final forProvider = [
          for (final m in models.valueOrNull ?? const [])
            if (m['provider_code'] == _provider &&
                m['is_active'] == true &&
                m['kind'] != 'image')
              m,
        ];
        final ready = s['is_ready'] == true;

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const SectionHeader(
                'The assistant',
                subtitle: 'Which model reads your books, and whose key pays',
              ),

              SwitchListTile(
                key: const ValueKey('assistant-enabled'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Answer questions about our books'),
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
              ),

              // What it is set to right now, and — the line this sheet
              // exists for — whether that can actually be called.
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            ready
                                ? Icons.check_circle_outline
                                : Icons.error_outline,
                            size: 18,
                            color: ready
                                ? theme.colorScheme.primary
                                : theme.colorScheme.error,
                          ),
                          const SizedBox(width: Space.sm),
                          Expanded(
                            child: Text(
                              ready
                                  ? 'Ready to answer'
                                  : 'Not ready to answer yet',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: Space.xs),
                      Text(
                        s['not_ready_reason'] as String? ??
                            [
                              '${s['provider_name'] ?? s['provider_code']}',
                              '${s['model_name'] ?? s['model_id'] ?? ''}',
                              if (s['follows_platform'] == true)
                                'following the platform',
                            ].where((t) => t.isNotEmpty).join(' · '),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Space.lg),

              // A picker rather than a dropdown, and a searchable one:
              // the list grows every time somebody adds a provider, and
              // a list that grows is a search box.
              SearchablePicker<String>(
                key: const ValueKey('assistant-provider'),
                label: 'Provider',
                value: _provider,
                allowEmpty: true,
                emptyLabel: 'Follow the platform',
                helperText:
                    'Left on "follow the platform" this moves with '
                    'whatever the platform is using, which is what most '
                    'companies want.',
                onChanged: (v) => setState(() {
                  _provider = v;
                  // A model belongs to a provider, so changing the
                  // provider cannot leave the old model behind — that
                  // is refused when it is saved, and it is friendlier
                  // to clear it here than to explain it there.
                  _model = null;
                }),
                options: [
                  for (final p in live)
                    PickerOption(
                      value: '${p['code']}',
                      label: '${p['name']}',
                      sublabel: [
                        '${p['wire']} shape',
                        if (p['base_url'] != null) '${p['base_url']}',
                      ].join(' · '),
                      keywords: ['${p['code']}', '${p['wire']}'],
                    ),
                ],
              ),
              const SizedBox(height: Space.md),

              if (_provider != null)
                SearchablePicker<String>(
                  key: const ValueKey('assistant-model'),
                  label: 'Model',
                  value: _model,
                  allowEmpty: true,
                  emptyLabel: 'Choose one',
                  helperText: forProvider.isEmpty
                      ? 'This provider has no model on file yet. A '
                            'platform administrator adds one.'
                      : null,
                  onChanged: (v) => setState(() => _model = v),
                  options: [
                    for (final m in forProvider)
                      PickerOption(
                        value: '${m['model_id']}',
                        label: '${m['name']}',
                        sublabel: [
                          '${m['model_id']}',
                          if (m['is_free'] == true) 'free',
                          if (m['context_tokens'] != null)
                            '${m['context_tokens']} tokens',
                          if (m['notes'] != null) '${m['notes']}',
                        ].join(' · '),
                        keywords: ['${m['model_id']}', '${m['kind']}'],
                      ),
                  ],
                ),
              if (_provider != null) const SizedBox(height: Space.md),

              const SectionHeader('Whose key pays'),
              // One `RadioGroup` around both, rather than a
              // `groupValue` and an `onChanged` on each. Flutter
              // deprecated the per-tile form after 3.32, and the
              // reason shows here: the selection and the handler were
              // written out twice, and two copies of "which one is
              // chosen" is one copy too many.
              RadioGroup<String>(
                groupValue: _keySource,
                onChanged: (v) => setState(() => _keySource = v ?? 'platform'),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RadioListTile<String>(
                      contentPadding: EdgeInsets.zero,
                      value: 'platform',
                      title: const Text('The platform\u2019s'),
                      subtitle: const Text(
                        'Questions come out of your scanning credit, the '
                        'same as a scan.',
                      ),
                    ),
                    RadioListTile<String>(
                      contentPadding: EdgeInsets.zero,
                      value: 'own',
                      title: const Text('Our own'),
                      subtitle: const Text(
                        'An account you already hold with the provider. '
                        'They bill you directly.',
                      ),
                    ),
                  ],
                ),
              ),

              if (_keySource == 'own') ...[
                const SizedBox(height: Space.sm),
                Text(
                  s['has_own_key'] == true
                      ? 'A key is on file, set '
                            '${Fmt.dateTime(s['own_key_set_at'])}. It cannot '
                            'be read back — replace it if you are not '
                            'sure it is the right one.'
                      : 'No key on file yet.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: Space.sm),
                Wrap(
                  spacing: Space.sm,
                  children: [
                    FilledButton.tonalIcon(
                      key: const ValueKey('assistant-key'),
                      onPressed: _provider == null ? null : _keyIn,
                      icon: const Icon(Icons.key_outlined),
                      label: Text(
                        s['has_own_key'] == true
                            ? 'Replace our key'
                            : 'Key ours in',
                      ),
                    ),
                    if (s['has_own_key'] == true)
                      TextButton.icon(
                        onPressed: _provider == null ? null : _clearKey,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Take it off'),
                      ),
                  ],
                ),
                if (_provider == null)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.xs),
                    child: Text(
                      'A key belongs to a provider, so choose one above '
                      'first.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],

              const SizedBox(height: Space.lg),
              FilledButton(
                key: const ValueKey('assistant-save'),
                onPressed: _save,
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _save() async {
    final org = ref.read(currentOrgIdProvider);
    if (org == null) return;
    await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .setAiSettings(
            org,
            enabled: _enabled,
            provider: _provider,
            model: _model,
            keySource: _keySource,
          ),
      successMessage: 'Saved',
    );
    ref.invalidate(aiStatusProvider);
  }

  Future<void> _keyIn() async {
    final org = ref.read(currentOrgIdProvider);
    final provider = _provider;
    if (org == null || provider == null) return;
    final key = TextEditingController();
    final url = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Our key'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: key,
                autofocus: true,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'API key',
                  helperText:
                      'Stored where only the service that asks the '
                      'question can read it, and never shown again.',
                  helperMaxLines: 3,
                ),
              ),
              const SizedBox(height: Space.md),
              TextField(
                controller: url,
                decoration: const InputDecoration(
                  labelText: 'Address (optional)',
                  helperText:
                      'Fill this in only for a gateway of your own, or a '
                      'region that is not the provider’s default.',
                  helperMaxLines: 3,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .setAiCredentials(
            org,
            provider,
            key.text,
            baseUrl: url.text.trim().isEmpty ? null : url.text.trim(),
          ),
      successMessage: 'Key saved',
    );
    ref.invalidate(aiStatusProvider);
  }

  Future<void> _clearKey() async {
    final org = ref.read(currentOrgIdProvider);
    final provider = _provider;
    if (org == null || provider == null) return;
    await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.clearAiCredentials(org, provider),
      successMessage: 'Key removed',
    );
    ref.invalidate(aiStatusProvider);
  }
}
