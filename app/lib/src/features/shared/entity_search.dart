import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/safe_link.dart';
import '../../core/theme.dart';
import '../../data/search_registers_repository.dart';
import '../../data/ssm_repository.dart';
import 'ssm_entity_picker.dart';

/// Entity Search: which register, then the search itself.
///
/// This used to be one button reading "Check the SSM register", which
/// was the only register it knew. A contact can as easily be an audit
/// firm or a law firm as a company, and the register that knows about
/// each of those is a different one.
///
/// `0606` made the list a table, so the choices here are whatever a
/// platform administrator has put on it.
///
/// ## Two kinds of register
///
/// `canSearch` decides which half of this runs, and it is a fact about
/// the register rather than about how much has been built. SSM answers
/// — `0589` reaches ssmsearch.com and `0604` added SSM's own API behind
/// the same seam — so picking it opens the search. MIA's register is a
/// form behind Cloudflare's bot challenge with no API, so picking it
/// opens MIA's own page in a tab, which is what somebody would do
/// anyway and is how `0603` has had them verify a member since.
///
/// Returns the chosen entity where a register could be searched and
/// something was picked, and null otherwise. It writes nothing: what a
/// caller does with a match differs, and deciding that here would be
/// deciding it in the wrong place.
Future<SsmEntity?> showEntitySearch(
  BuildContext context, {
  String? initialQuery,
}) async {
  final register = await showDialog<SearchRegister>(
    context: context,
    builder: (_) => const _RegisterPicker(),
  );
  if (register == null || !context.mounted) return null;

  if (register.canSearch) {
    // Only SSM has a live provider today. A register marked searchable
    // that this does not know how to search would otherwise open
    // nothing at all, so the fallback is the same as an unsearchable
    // one: send them to the register itself.
    if (register.code == 'ssm') {
      return showSsmEntityPicker(context, initialQuery: initialQuery);
    }
  }
  await _openRegister(context, register);
  return null;
}

/// Opens the register's own site, or says why it could not.
Future<void> _openRegister(
  BuildContext context,
  SearchRegister register,
) async {
  final ok = await launchExternal(register.url);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not open ${register.name}.')),
    );
  }
}

class _RegisterPicker extends ConsumerWidget {
  const _RegisterPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(offeredSearchRegistersProvider);
    final registers = async.valueOrNull ?? const <SearchRegister>[];
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: context.scheme.onSurfaceVariant,
    );

    return AlertDialog(
      title: const Text('Where should I look?'),
      content: SizedBox(
        width: 460,
        child: async.isLoading && registers.isEmpty
            // Not "no registers". An answer that has not arrived is not
            // an answer of none, and this dialog exists to offer a
            // choice.
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: Space.lg),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : registers.isEmpty
            ? Text(
                'No registers are switched on. A platform administrator '
                'sets them up.',
                key: const ValueKey('entity-search-none'),
                style: muted,
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final r in registers)
                    ListTile(
                      key: ValueKey('entity-search-${r.code}'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(r.name),
                      subtitle: Text(
                        [
                          if (r.registers != null) r.registers!,
                          // Said on the row, because the two do
                          // different things and somebody choosing
                          // should know which they are getting.
                          if (!r.canSearch) 'opens their own site',
                        ].join(' · '),
                        style: muted,
                      ),
                      trailing: Icon(
                        r.canSearch ? Icons.search : Icons.open_in_new,
                        size: 18,
                      ),
                      onTap: () => Navigator.of(context).pop(r),
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
