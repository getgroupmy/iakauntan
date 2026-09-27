import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error_text.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

/// Where the claim approval chain becomes the full chain.
///
/// A claim goes to the employee's manager, then the department head,
/// then HR, then finance. That is four people for a parking receipt,
/// which is why the threshold exists: below it the manager decides
/// alone. Until this card there was nowhere to set it, so every company
/// ran on the default of zero and every claim asked all four.
///
/// Stated in money rather than as a switch because that is the decision
/// being made — "we do not need finance to look at anything under fifty
/// ringgit" — and because zero is a meaningful value on the same scale
/// rather than a separate mode.
class ClaimApprovalCard extends ConsumerStatefulWidget {
  const ClaimApprovalCard({
    super.key,
    required this.org,
    required this.canAdmin,
  });

  final Organization org;
  final bool canAdmin;

  @override
  ConsumerState<ClaimApprovalCard> createState() => ClaimApprovalCardState();
}

class ClaimApprovalCardState extends ConsumerState<ClaimApprovalCard> {
  final _amount = TextEditingController();

  /// What the field was loaded with, so an untouched card does not offer
  /// to save and a reverted edit stops offering.
  double? _loaded;
  bool _saving = false;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  double? get _entered {
    final text = _amount.text.trim();
    if (text.isEmpty) return null;
    return double.tryParse(text.replaceAll(',', ''));
  }

  Future<void> _save() async {
    final value = _entered;
    if (value == null || value < 0) return;

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.setClaimApprovalThreshold(value),
      successMessage: 'Approval threshold saved',
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) _loaded = value;
    });
    if (ok) ref.invalidate(claimApprovalThresholdProvider);
  }

  @override
  Widget build(BuildContext context) {
    final threshold = ref.watch(claimApprovalThresholdProvider);
    final currency = widget.org.baseCurrency;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'Claim approvals',
              subtitle: 'How far up the line a claim has to go',
            ),
            threshold.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) =>
                  Text(errorText(e), style: TextStyle(color: context.colors.warning)),
              data: (value) {
                // Fill the field the first time the amount arrives, and
                // never again — re-filling on every rebuild would wipe
                // what is being typed.
                if (_loaded == null && _amount.text.isEmpty) {
                  _loaded = value ?? 0;
                  _amount.text = (value ?? 0).toStringAsFixed(2);
                }

                final entered = _entered;
                final dirty = entered != null && entered != _loaded;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 220,
                          child: TextField(
                            key: const ValueKey('claim-threshold'),
                            controller: _amount,
                            enabled: widget.canAdmin && !_saving,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(
                              labelText: 'Full chain from',
                              prefixText: Fmt.prefix(currency),
                              helperText: 'Below this, the manager alone',
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        if (widget.canAdmin)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: FilledButton(
                              onPressed: dirty && !_saving ? _save : null,
                              child: const Text('Save'),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _explain(entered ?? _loaded ?? 0, currency),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (entered != null && entered < 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'A threshold cannot be negative.',
                          style: TextStyle(color: context.colors.warning),
                        ),
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

  /// Says what the number does in the words somebody setting it would
  /// use. Zero is the case worth spelling out, because it looks like
  /// "off" and means the opposite.
  String _explain(double value, String currency) {
    if (value <= 0) {
      return 'Every claim goes to the manager, the department head, HR '
          'and finance. Stages with nobody to fill them are skipped.';
    }
    return 'A claim of ${Fmt.money(value, currency: currency)} or more goes '
        'to the manager, the department head, HR and finance. Anything '
        'smaller needs only the manager — unless the employee has no '
        'manager on file, in which case it goes up the full chain rather '
        'than getting stuck.';
  }
}
