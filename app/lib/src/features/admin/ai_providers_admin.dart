import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/platform_live.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
// `RepoAiProviders` is an extension, and a Dart extension is only in
// scope where its declaring library is imported.
import '../../data/ai_repository.dart';

/// Where the AI key is keyed in, and where the model is chosen.
///
/// Until 0536 there was no such place. `ask/index.ts` read
/// `AI_ANTHROPIC_API_KEY` out of the deployment's environment and
/// called a model named in a `const` at the top of the file — so
/// turning the assistant on took a deployment, changing the key took
/// another one, and every tenant on the platform used the same provider
/// whether it suited them or not.
///
/// ## The key goes in and does not come back
///
/// This screen can set a key and can say whether one is on file. It
/// cannot show you the key, and that is not an omission: the row it
/// reads has no column that could carry one, and the only function that
/// returns a key is granted to the service role, which the app does not
/// hold. A key you have lost is one you replace, which is what the
/// provider's own console would tell you too.
///
/// ## Why a provider is a row
///
/// There are two request shapes worth writing adapters for — the
/// Anthropic Messages API and the OpenAI chat-completions shape that
/// OpenRouter, DeepSeek, Qwen, Cerebras, NVIDIA NIM and Gemini's
/// compatibility endpoint all speak. Everything else about a provider
/// is data. So a gateway on your own network, or something that shipped
/// last week, is a row added from here rather than a release.
class AiProvidersAdminTab extends ConsumerWidget {
  const AiProvidersAdminTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalogue = ref.watch(aiProviderCatalogueProvider);
    final models = ref.watch(aiModelsProvider);

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editProvider(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('Add a provider'),
      ),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: catalogue,
        onRetry: () => ref.invalidate(aiProviderCatalogueProvider),
        skeleton: const ListSkeleton(rows: 6, leading: false, subtitle: false),
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.smart_toy_outlined,
              title: 'No providers on file',
              message:
                  'Add one and every company on this deployment can '
                  'choose it, without an app release.',
            );
          }
          final allModels = models.valueOrNull ?? const [];
          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              PageBody(
                maxWidth: 860,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SectionHeader(
                      'The assistant',
                      subtitle:
                          'Which model answers, at whose expense, and '
                          'with which key',
                    ),
                    for (final p in rows)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _ProviderCard(
                          provider: p,
                          models: [
                            for (final m in allModels)
                              if (m['provider_code'] == p['code']) m,
                          ],
                        ),
                      ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ProviderCard extends ConsumerWidget {
  const _ProviderCard({required this.provider, required this.models});

  final Map<String, dynamic> provider;
  final List<Map<String, dynamic>> models;

  String get _code => '${provider['code']}';
  bool get _hasKey => provider['has_key'] == true;
  bool get _needsKey => provider['needs_key'] != false;
  bool get _isDefault => provider['is_default'] == true;
  bool get _isActive => provider['is_active'] == true;

  /// The address it will actually be called at: the one keyed in beside
  /// the key if there is one, otherwise the provider's own.
  String? get _address =>
      (provider['key_base_url'] as String?) ?? (provider['base_url'] as String?);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final live = models.where((m) => m['is_active'] == true).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: Space.sm,
                    runSpacing: Space.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '${provider['name']}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (_isDefault)
                        const StatusChip('the default', compact: true),
                      if (!_isActive)
                        const StatusChip('switched off', compact: true),
                      if (_needsKey)
                        StatusChip(
                          _hasKey ? 'key on file' : 'no key',
                          compact: true,
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Edit this provider',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => _editProvider(context, ref, provider),
                ),
              ],
            ),
            const SizedBox(height: Space.xs),
            Text(
              [
                _code,
                '${provider['wire']} shape',
                _address ?? 'no address on file',
                '${live.length} model${live.length == 1 ? '' : 's'}',
                if ((provider['tenants'] as int? ?? 0) > 0)
                  '${provider['tenants']} companies using it',
              ].join(' · '),
              style: theme.textTheme.bodySmall,
            ),
            if (_hasKey && provider['key_set_at'] != null)
              Padding(
                padding: const EdgeInsets.only(top: Space.xs),
                child: Text(
                  'Key set ${Fmt.dateTime(provider['key_set_at'])}. It cannot '
                  'be read back — replace it if you are not sure.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (provider['key_hint'] != null)
              Padding(
                padding: const EdgeInsets.only(top: Space.xs),
                child: Text(
                  '${provider['key_hint']}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: Space.md),
            Wrap(
              spacing: Space.sm,
              runSpacing: Space.xs,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => _keyIn(context, ref, provider),
                  icon: const Icon(Icons.key_outlined),
                  label: Text(_hasKey ? 'Replace the key' : 'Key one in'),
                ),
                if (_hasKey)
                  TextButton.icon(
                    onPressed: () => _clearKey(context, ref),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Take it off'),
                  ),
                TextButton.icon(
                  onPressed: () => _addModel(context, ref, _code),
                  icon: const Icon(Icons.add),
                  label: const Text('Add a model'),
                ),
                if (!_isDefault && _isActive && live.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => _makeDefault(context, ref, _code, live),
                    icon: const Icon(Icons.star_outline),
                    label: const Text('Make this the default'),
                  ),
              ],
            ),
            if (live.isNotEmpty) ...[
              const SizedBox(height: Space.sm),
              Wrap(
                spacing: Space.xs,
                runSpacing: Space.xs,
                children: [
                  for (final m in live)
                    Chip(
                      label: Text(
                        '${m['model_id']}'
                        '${m['is_free'] == true ? ' · free' : ''}'
                        '${m['kind'] != 'chat' ? ' · ${m['kind']}' : ''}'
                        '${_isDefault && provider['default_model'] == m['model_id'] ? ' ✓' : ''}',
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _clearKey(BuildContext context, WidgetRef ref) async {
    final sure = await confirm(
      context,
      title: 'Take the key off ${provider['name']}?',
      message:
          'Any company using the platform key for this provider stops '
          'being able to ask a question until another one is keyed in.',
      confirmLabel: 'Take it off',
    );
    if (!sure || !context.mounted) return;
    await runWithFeedback(
      context,
      action: () => ref.read(platformRepoProvider).clearPlatformAiKey(_code),
      successMessage: 'Key removed',
    );
    ref.invalidate(aiProviderCatalogueProvider);
    invalidatePlatformTable(ref, 'ai_provider_credentials');
  }
}

/// The key sheet.
///
/// One field for the key and one for an address, because the two go
/// together: a company behind its own gateway, or a DashScope account
/// in a different region, needs both and needs them to agree.
Future<void> _keyIn(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic> provider,
) async {
  final key = TextEditingController();
  final url = TextEditingController(
    text: '${provider['key_base_url'] ?? ''}',
  );
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('The key for ${provider['name']}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (provider['key_hint'] != null)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.md),
                child: Text('${provider['key_hint']}'),
              ),
            TextField(
              controller: key,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API key',
                helperText:
                    'Stored where only the service role can read it, and '
                    'never shown again.',
                helperMaxLines: 3,
              ),
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: url,
              decoration: InputDecoration(
                labelText: 'Address (optional)',
                hintText: '${provider['base_url'] ?? 'https://…/v1'}',
                helperText:
                    'Leave empty to use the address on the provider. Fill '
                    'it in for a gateway, or a region that is not the '
                    'default one.',
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
  if (saved != true || !context.mounted) return;
  await runWithFeedback(
    context,
    action: () => ref
        .read(platformRepoProvider)
        .setPlatformAiKey(
          '${provider['code']}',
          key.text,
          baseUrl: url.text.trim().isEmpty ? null : url.text.trim(),
        ),
    successMessage: 'Key saved',
  );
  ref.invalidate(aiProviderCatalogueProvider);
  invalidatePlatformTable(ref, 'ai_provider_credentials');
}

/// Which model everybody who has not chosen one gets.
///
/// A picker rather than a text field, and a searchable one, because a
/// provider with forty models is a list nobody scrolls. The pair is
/// saved together: a default naming a model the provider does not
/// answer to is a deployment where every question fails.
Future<void> _makeDefault(
  BuildContext context,
  WidgetRef ref,
  String code,
  List<Map<String, dynamic>> models,
) async {
  final choosable = [
    for (final m in models)
      if (m['kind'] != 'image') m,
  ];
  if (choosable.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'That provider has no model that holds a conversation yet. '
            'Add one first.',
          ),
        ),
      );
    }
    return;
  }
  String? picked = '${choosable.first['model_id']}';
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Make this the default'),
        content: SizedBox(
          width: 420,
          child: SearchablePicker<String>(
            key: const ValueKey('ai-default-model'),
            label: 'Model',
            value: picked,
            onChanged: (v) => setState(() => picked = v),
            options: [
              for (final m in choosable)
                PickerOption(
                  value: '${m['model_id']}',
                  label: '${m['name']}',
                  sublabel: [
                    '${m['model_id']}',
                    if (m['is_free'] == true) 'free',
                    if (m['context_tokens'] != null)
                      '${m['context_tokens']} tokens',
                  ].join(' · '),
                  keywords: ['${m['model_id']}', '${m['kind']}'],
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
    ),
  );
  if (saved != true || picked == null || !context.mounted) return;
  await runWithFeedback(
    context,
    action: () => ref.read(platformRepoProvider).setPlatformAiDefault(code, picked!),
    successMessage: 'Default saved',
  );
  ref.invalidate(aiProviderCatalogueProvider);
  invalidatePlatformTable(ref, 'platform_settings');
}

/// A model the catalogue does not list yet.
///
/// The id is what goes on the wire and the name is what a person reads,
/// which is why both are asked for rather than one being derived from
/// the other.
Future<void> _addModel(
  BuildContext context,
  WidgetRef ref,
  String provider,
) async {
  final id = TextEditingController();
  final name = TextEditingController();
  var kind = 'chat';
  var free = false;
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('A model for $provider'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: id,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Model id',
                  helperText: 'Exactly as the provider spells it on the wire.',
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: Space.md),
              TextField(
                controller: name,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  helperText: 'What a person picking it reads.',
                ),
              ),
              const SizedBox(height: Space.md),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'chat', label: Text('Chat')),
                  ButtonSegment(value: 'vision', label: Text('Vision')),
                  ButtonSegment(value: 'image', label: Text('Image')),
                ],
                selected: {kind},
                onSelectionChanged: (s) => setState(() => kind = s.first),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Free at the point of use'),
                value: free,
                onChanged: (v) => setState(() => free = v),
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
            child: const Text('Add'),
          ),
        ],
      ),
    ),
  );
  if (saved != true || !context.mounted) return;
  await runWithFeedback(
    context,
    action: () => ref
        .read(platformRepoProvider)
        .upsertAiModel(
          provider,
          id.text.trim(),
          name: name.text.trim().isEmpty ? id.text.trim() : name.text.trim(),
          kind: kind,
          isFree: free,
        ),
    successMessage: 'Model added',
  );
  ref.invalidate(aiModelsProvider);
  invalidatePlatformTable(ref, 'ai_models');
}

/// Adding a provider, or editing one.
///
/// The wire shape is the only field that has to be chosen from a list,
/// because it is the only thing about a provider that is code rather
/// than data.
Future<void> _editProvider(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic>? existing,
) async {
  final code = TextEditingController(text: '${existing?['code'] ?? ''}');
  final name = TextEditingController(text: '${existing?['name'] ?? ''}');
  final url = TextEditingController(text: '${existing?['base_url'] ?? ''}');
  final docs = TextEditingController(text: '${existing?['docs_url'] ?? ''}');
  final hint = TextEditingController(text: '${existing?['key_hint'] ?? ''}');
  var wire = '${existing?['wire'] ?? 'openai'}';
  var active = existing?['is_active'] != false;
  var needsKey = existing?['needs_key'] != false;

  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(existing == null ? 'Add a provider' : 'Edit ${name.text}'),
        content: SingleChildScrollView(
          child: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: code,
                  enabled: existing == null,
                  decoration: const InputDecoration(
                    labelText: 'Code',
                    helperText:
                        'Lower case letters, digits and underscores. It '
                        'goes in a settings row and a log line, not on a '
                        'screen.',
                    helperMaxLines: 3,
                  ),
                ),
                const SizedBox(height: Space.md),
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: Space.md),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'openai',
                      label: Text('OpenAI shape'),
                    ),
                    ButtonSegment(
                      value: 'anthropic',
                      label: Text('Anthropic'),
                    ),
                  ],
                  selected: {wire},
                  onSelectionChanged: (s) => setState(() => wire = s.first),
                ),
                const SizedBox(height: Space.xs),
                Text(
                  'Nearly everything speaks the OpenAI chat-completions '
                  'shape. Anthropic is its own.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: Space.md),
                TextField(
                  controller: url,
                  decoration: const InputDecoration(
                    labelText: 'Address',
                    hintText: 'https://…/v1',
                    helperText:
                        'The base the request hangs off. A provider with '
                        'no address cannot be called, and says so.',
                    helperMaxLines: 3,
                  ),
                ),
                const SizedBox(height: Space.md),
                TextField(
                  controller: docs,
                  decoration: const InputDecoration(
                    labelText: 'Documentation (optional)',
                  ),
                ),
                const SizedBox(height: Space.md),
                TextField(
                  controller: hint,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'What the key looks like (optional)',
                    helperText:
                        'Shown to whoever has to find one. "A key from '
                        'openrouter.ai/keys, beginning sk-or-."',
                    helperMaxLines: 3,
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Needs an API key'),
                  value: needsKey,
                  onChanged: (v) => setState(() => needsKey = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Offered to companies'),
                  subtitle: const Text(
                    'Switch off rather than delete: a company that chose '
                    'it keeps the row that says so.',
                  ),
                  value: active,
                  onChanged: (v) => setState(() => active = v),
                ),
              ],
            ),
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
    ),
  );
  if (saved != true || !context.mounted) return;
  await runWithFeedback(
    context,
    action: () => ref
        .read(platformRepoProvider)
        .upsertAiProvider(
          code.text.trim(),
          name: name.text.trim(),
          wire: wire,
          baseUrl: url.text.trim().isEmpty ? null : url.text.trim(),
          docsUrl: docs.text.trim().isEmpty ? null : docs.text.trim(),
          keyHint: hint.text.trim().isEmpty ? null : hint.text.trim(),
          needsKey: needsKey,
          isActive: active,
        ),
    successMessage: 'Saved',
  );
  ref.invalidate(aiProviderCatalogueProvider);
  ref.invalidate(aiProvidersProvider);
  invalidatePlatformTable(ref, 'ai_providers');
}
