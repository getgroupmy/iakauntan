import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../shared/ocr_key_pool_editor.dart';

/// The keys behind each reader, and what each one is allowed to spend.
///
/// Until `0675` a reader had one key: `OCR_KEY_<CODE>` in the edge
/// function's environment. Changing it took a deploy and there was
/// nowhere to put a second one — which is the wrong shape for Gemini,
/// whose free tier is capped per key by requests per minute and per
/// day. The way anybody actually runs that is several keys with the
/// traffic spread across them.
///
/// ## The key goes in and does not come back
///
/// This screen can add a key, change what it may spend, stand it down
/// and remove it. It cannot show you one. `ocr_keys_for` has no column
/// that could carry a key, the table behind it has its grants revoked
/// from everybody but the service role, and the last four characters
/// are here only so two keys off the same account can be told apart
/// against Google's own console. A key you have lost is one you
/// replace, which is what Google would tell you too.
///
/// ## Two gates, and they fail differently
///
/// A key runs when its CLOCK allows it and its BUDGET has room, and
/// the screen says which one stopped it, because the answers are
/// different: switched off is a decision to reverse, outside its hours
/// is a wait with a known end, and spent is a wait that needs nobody.
class OcrKeysAdminTab extends ConsumerStatefulWidget {
  const OcrKeysAdminTab({super.key});

  @override
  ConsumerState<OcrKeysAdminTab> createState() => _OcrKeysAdminTabState();
}

class _OcrKeysAdminTabState extends ConsumerState<OcrKeysAdminTab> {
  String? _provider;

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(ocrProviderCatalogProvider);

    return AsyncView<List<Map<String, dynamic>>>(
      value: catalog,
      onRetry: () => ref.invalidate(ocrProviderCatalogProvider),
      skeleton: const ListSkeleton(rows: 5, leading: false),
      builder: (readers) {
        // Only the ones a key means anything to. The on-device reader
        // has no key for anybody to bring, and offering a pool for it
        // would be offering to configure something that does not exist.
        final keyed = readers.where((r) => r['takes_key'] == true).toList();
        if (keyed.isEmpty) {
          return const EmptyState(
            icon: Icons.vpn_key_outlined,
            title: 'No reader takes a key',
            message: 'Add one on the Readers screen and its pool appears '
                'here.',
          );
        }

        final chosen = keyed.firstWhere(
          (r) => r['code'] == _provider,
          orElse: () => keyed.first,
        );
        final code = '${chosen['code']}';

        return ListView(
          padding: const EdgeInsets.all(Space.md),
          children: [
            DropdownButtonFormField<String>(
                  key: const ValueKey('key-pool-reader'),
                  initialValue: code,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Reader',
                    helperText: 'Each reader keeps its own pool.',
                  ),
                  items: [
                    for (final r in keyed)
                      DropdownMenuItem(
                        value: '${r['code']}',
                        child: Text(
                          '${r['name'] ?? r['code']}'
                          '${r['is_active'] == true ? '' : ' — switched off'}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
              onChanged: (v) => setState(() => _provider = v),
            ),
            // Said here rather than left to be discovered: a reader
            // switched off in the catalog takes no scans whatever its
            // pool holds, and somebody filling a pool to fix a stopped
            // scan needs to know that is not the problem.
            if (chosen['is_active'] != true)
              Padding(
                padding: const EdgeInsets.only(top: Space.sm),
                child: Text(
                  '${chosen['name'] ?? code} is switched off in the '
                  'catalog, so no company can choose it and these keys '
                  'are not being used. The Readers screen is where it '
                  'is turned on.',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.colors.warning,
                  ),
                ),
              ),
            const SizedBox(height: Space.md),
            // The platform's pool: a null org id. The same editor the
            // tenant's Settings card draws for its own.
            OcrKeyPoolEditor(provider: code),
          ],
        );
      },
    );
  }
}
