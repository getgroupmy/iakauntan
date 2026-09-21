import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/my_profile_repository.dart';
import '../../data/signup_reference_repository.dart';
import '../auth/phone_number.dart' show salutationFieldLabel, salutationSublabel;
import 'my_profile.dart';

/// Your own details, on a screen of their own.
///
/// See `my_profile.dart` for what belongs here and what deliberately
/// does not. The short version: the fields are the person, the buttons
/// at the foot are the account, and email is shown rather than edited.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _fullName = TextEditingController();
  final _phone = TextEditingController();
  String _salutation = '';

  /// The draft as it was when the row landed.
  ///
  /// Held so that Save can be disabled until something actually
  /// changes, and so that a save sends only what was edited. Null until
  /// the row arrives, which is also how `_fill` knows not to overwrite
  /// somebody's typing when the provider re-emits.
  ProfileDraft? _loaded;

  bool _saving = false;

  @override
  void dispose() {
    _fullName.dispose();
    _phone.dispose();
    super.dispose();
  }

  /// Put the row into the boxes, ONCE.
  ///
  /// `myProfileProvider` can re-emit -- it is invalidated after every
  /// save, and it is also rebuilt when the signed-in user changes. A
  /// `build` that copied the row into the controllers every time would
  /// throw away whatever was half-typed the moment anything else on the
  /// screen moved, which is the classic form-in-a-builder defect.
  void _fill(Map<String, dynamic>? row) {
    if (_loaded != null) return;
    final draft = profileDraftFrom(row);
    _fullName.text = draft.fullName;
    _phone.text = draft.phone;
    _salutation = draft.salutation;
    _loaded = draft;
  }

  ProfileDraft get _draft => (
    fullName: _fullName.text,
    salutation: _salutation,
    phone: _phone.text,
  );

  bool get _dirty =>
      _loaded != null && profileChanged(_loaded!, _draft);

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final messenger = ScaffoldMessenger.of(context);
    final before = _loaded;
    if (before == null) return;

    final changes = profileChanges(before, _draft);
    if (changes.isEmpty) return;

    setState(() => _saving = true);
    try {
      await saveMyProfile(
        ref,
        fullName: changes['fullName'],
        salutation: changes['salutation'],
        phone: changes['phone'],
      );
      if (!mounted) return;
      // The new baseline. Without this the Save button stays live after
      // a successful save and pressing it again sends the same change,
      // which is harmless and looks like the first press did nothing.
      setState(() => _loaded = _draft);
      messenger.showSnackBar(const SnackBar(content: Text('Saved')));
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(profileSaveProblem(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(myProfileProvider);
    final user = ref.watch(currentUserProvider);
    final role = ref.watch(memberRoleProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Your details'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              key: const ValueKey('profile-save'),
              // Disabled until something has changed, which is what
              // makes the button honest: a form whose Save is always
              // live teaches people to press it and hope.
              onPressed: _saving || !_dirty ? null : _save,
              child: _saving
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ),
        ],
      ),
      body: profile.when(
        // The shape is a form of three boxes and it is decided before
        // the row arrives, which is when `skeletons.dart` says an
        // outline is the honest thing to draw.
        loading: () => const SingleChildScrollView(
          child: PageBody(
            maxWidth: 560,
            child: Padding(
              padding: EdgeInsets.only(top: Space.lg),
              child: FormSkeleton(fields: 3),
            ),
          ),
        ),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(Space.xl),
            child: Text('Could not read your details: $e'),
          ),
        ),
        data: (row) {
          _fill(row);
          return SingleChildScrollView(
            child: PageBody(
              maxWidth: 560,
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SectionHeader(
                      'You',
                      subtitle: 'What this product calls you, and how to '
                          'reach you. Nothing here is about a company.',
                    ),

                    Consumer(
                      builder: (context, ref, _) {
                        final titles =
                            ref
                                .watch(signupReferenceProvider)
                                .valueOrNull
                                ?.salutations ??
                            const <Map<String, dynamic>>[];
                        // The same picker the sign-up form uses, and
                        // the same reason: there are more than a
                        // hundred of these and somebody looking for
                        // Datuk Seri Panglima should be able to type it.
                        return SearchablePicker<String>(
                          key: const ValueKey('profile-salutation'),
                          label: salutationFieldLabel,
                          value: _salutation.isEmpty ? null : _salutation,
                          options: [
                            for (final t in titles)
                              PickerOption(
                                value: '${t['name']}',
                                label: '${t['name']}',
                                sublabel: salutationSublabel(t),
                                keywords: [
                                  '${t['grouping'] ?? ''}',
                                  '${t['note'] ?? ''}',
                                  '${t['code'] ?? ''}',
                                ],
                              ),
                          ],
                          // NOT required here, unlike on the sign-up
                          // form. That form asks because a registration
                          // with a blank title leaves a column null on
                          // half the rows; this one is somebody
                          // correcting a record that already exists,
                          // and refusing to save their name because
                          // they have no title on file would be a form
                          // arguing about a field they did not come to
                          // change.
                          onChanged: (v) =>
                              setState(() => _salutation = v ?? ''),
                        );
                      },
                    ),
                    const SizedBox(height: Space.md),

                    TextFormField(
                      key: const ValueKey('profile-full-name'),
                      controller: _fullName,
                      decoration: const InputDecoration(
                        labelText: 'Full name *',
                        prefixIcon: Icon(Icons.person_outline),
                        helperText: 'The name on letters and on anything '
                            'you approve.',
                      ),
                      textCapitalization: TextCapitalization.words,
                      onChanged: (_) => setState(() {}),
                      validator: (v) => profileNameProblem(v ?? ''),
                    ),
                    const SizedBox(height: Space.md),

                    TextFormField(
                      key: const ValueKey('profile-phone'),
                      controller: _phone,
                      decoration: const InputDecoration(
                        labelText: 'Telephone',
                        prefixIcon: Icon(Icons.phone_outlined),
                        helperText: 'Leave it empty to remove it.',
                      ),
                      keyboardType: TextInputType.phone,
                      onChanged: (_) => setState(() {}),
                    ),

                    const SizedBox(height: Space.xl),
                    const SectionHeader(
                      'Your account',
                      subtitle: 'How you sign in. These go through the '
                          'authentication service and each one verifies '
                          'the change.',
                    ),
                    // Shown, not edited. `profiles.email` is a COPY of
                    // the auth address and `0649` refuses to write it:
                    // changing it here would move what this row says
                    // and leave the address that actually signs you in
                    // -- and receives your reset link -- exactly as it
                    // was. The real change is the button under it.
                    FieldRow(
                      label: 'Signed in as',
                      value: user?.email ?? '—',
                    ),
                    if (role != null)
                      FieldRow(label: 'Role here', value: Fmt.label(role)),
                    const SizedBox(height: Space.sm),
                    Text(
                      'Your password, email address and mobile number are '
                      'changed under Settings › Your account, which is '
                      'also where you can join another company or close '
                      'this login.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: Space.sm),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        key: const ValueKey('profile-to-settings'),
                        onPressed: () => context.go('/settings'),
                        icon: const Icon(Icons.settings_outlined, size: 18),
                        label: const Text('Open account settings'),
                      ),
                    ),
                    const SizedBox(height: Space.xxl),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
