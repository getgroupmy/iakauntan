import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Which scanning surfaces this platform offers. `0718`.
///
/// Five switches, and they are not five of the same thing. Three take a
/// button off a screen; two change a rule. The page says which is
/// which, in as many words, because an operator who believes the Scan
/// button is a security control has been misled by a screen — and a
/// screen that misleads is worse than no screen.
class ScanSettingsAdminTab extends ConsumerStatefulWidget {
  const ScanSettingsAdminTab({super.key});

  @override
  ConsumerState<ScanSettingsAdminTab> createState() =>
      _ScanSettingsAdminTabState();
}

class _ScanSettingsAdminTabState extends ConsumerState<ScanSettingsAdminTab> {
  /// The key being saved, so one row shows its own progress rather than
  /// the whole page going grey.
  String? _saving;

  Future<void> _set(String key, bool on) async {
    setState(() => _saving = key);
    final ok = await runWithFeedback(
      context,
      doing: 'moving a scanning switch',
      action: () =>
          ref.read(platformRepoProvider).setScanSurface(key: key, on: on),
      successMessage: on ? 'Switched on' : 'Switched off',
    );
    if (!mounted) return;
    setState(() => _saving = null);
    if (ok) ref.invalidate(scanSurfacesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final surfaces = ref.watch(scanSurfacesProvider);

    return AsyncView<ScanSurfaces>(
      value: surfaces,
      onRetry: () => ref.invalidate(scanSurfacesProvider),
      skeleton: const ListSkeleton(rows: 5, trailing: false),
      builder: (s) => SingleChildScrollView(
        child: PageBody(
          maxWidth: 820,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(
                        'What the scanning screens offer',
                        subtitle: 'Off takes the control off every '
                            'company on this platform.',
                      ),
                      _Switch(
                        id: 'scan_show_scan_button',
                        value: s.scanButton,
                        saving: _saving,
                        onChanged: _set,
                        title: 'Scan button — AI SmartScan',
                        subtitle: 'Photograph or pick a document and send '
                            'it to be read.',
                      ),
                      _Switch(
                        id: 'scan_show_upload_button',
                        value: s.uploadButton,
                        saving: _saving,
                        onChanged: _set,
                        title: 'Upload button — AI SmartScan',
                        subtitle: 'Keep a file for later without reading '
                            'it. Costs nothing to run.',
                      ),
                      _Switch(
                        id: 'statements_show_upload_button',
                        value: s.statementsUpload,
                        saving: _saving,
                        onChanged: _set,
                        title: 'Upload button — Bank statements',
                        subtitle: 'The shortcut beside each account. The '
                            'import itself is on Reconcile and stays '
                            'reachable either way.',
                      ),
                      const SizedBox(height: 4),
                      _Note(
                        'These three are presentation. Turning one off '
                        'takes a control off the screen; it does not '
                        'stop scanning, which every company switches on '
                        'for itself and which the server checks on its '
                        'own. Use them to take a surface off the product '
                        'while it is being worked on.',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Space.lg),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(
                        'What the platform allows',
                        subtitle: 'These two change what the database '
                            'will accept, not just what is drawn.',
                      ),
                      _Switch(
                        id: 'scan_allow_own_key',
                        value: s.ownKey,
                        saving: _saving,
                        onChanged: _set,
                        title: 'My own key',
                        subtitle: 'Let a company read on its own provider '
                            'key instead of on credit bought here. Off, '
                            'every reading is billed through the '
                            'platform. A company already on its own key '
                            'keeps it and can still move back.',
                      ),
                      _Switch(
                        id: 'scan_reader_on_by_default',
                        value: s.readerOnByDefault,
                        saving: _saving,
                        onChanged: _set,
                        title: 'Send documents to a reader — on by default',
                        subtitle: 'For a company that has never touched '
                            'the switch. One that has chosen — on or off '
                            '— keeps its answer.',
                      ),
                      if (s.readerOnByDefault) ...[
                        const SizedBox(height: 4),
                        _Note(
                          'On. A company that has never asked for it will '
                          'have its bills, receipts and bank statements '
                          'sent to a third-party model, and the reading '
                          'is charged to platform credit.',
                          tone: _Tone.warn,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Switch extends StatelessWidget {
  const _Switch({
    required this.id,
    required this.value,
    required this.saving,
    required this.onChanged,
    required this.title,
    required this.subtitle,
  });

  final String id;
  final bool value;
  final String? saving;
  final void Function(String key, bool on) onChanged;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    // Disabled only while THIS row is saving. Locking the page would
    // make one slow call look like five broken switches.
    final busy = saving != null;
    return SwitchListTile(
      key: ValueKey('scan-surface-$id'),
      contentPadding: EdgeInsets.zero,
      value: value,
      onChanged: busy ? null : (v) => onChanged(id, v),
      title: Text(title),
      subtitle: Text(subtitle),
      isThreeLine: subtitle.length > 60,
    );
  }
}

enum _Tone { plain, warn }

class _Note extends StatelessWidget {
  const _Note(this.text, {this.tone = _Tone.plain});

  final String text;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final warn = tone == _Tone.warn;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          warn ? Icons.warning_amber_outlined : Icons.info_outline,
          size: 16,
          color: warn ? context.colors.warning : context.scheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: warn
                      ? context.colors.warning
                      : context.scheme.onSurfaceVariant,
                ),
          ),
        ),
      ],
    );
  }
}
