// emergency_contacts_setup — port of design_reference/v2/.../emergency_contacts_setup.
//
// Persists an ordered list in SharedPreferences via PreferencesService.
// Index 0 is the primary contact, index 1 is the secondary; additional
// numbers added via "ADD NEW NUMBER" are appended after.
//
// All text-input fields are accessible (Semantics.textField + clear label).
// SOS gesture is intentionally available here — the user might need it
// while configuring.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/audio/tts_service.dart';
import '../../services/preferences_service.dart';
import '../../theme/app_theme.dart';
import '../widgets/sos_gesture_wrapper.dart';
import '../widgets/wf_app_bar.dart';

class EmergencyContactsScreen extends ConsumerStatefulWidget {
  const EmergencyContactsScreen({super.key});

  @override
  ConsumerState<EmergencyContactsScreen> createState() =>
      _EmergencyContactsScreenState();
}

class _EmergencyContactsScreenState
    extends ConsumerState<EmergencyContactsScreen> {
  // Always at least 2 controllers — primary + secondary. Index >= 2 are the
  // user-added extras.
  final List<TextEditingController> _ctrls = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _ctrls.add(TextEditingController());
    _ctrls.add(TextEditingController());
    // ignore: discarded_futures
    _loadFromPrefs();
  }

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadFromPrefs() async {
    final stored = await ref
        .read(preferencesServiceProvider)
        .getEmergencyContacts();
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < stored.length; i++) {
        if (i < _ctrls.length) {
          _ctrls[i].text = stored[i];
        } else {
          _ctrls.add(TextEditingController(text: stored[i]));
        }
      }
      _loaded = true;
    });
  }

  void _addNumber() {
    setState(() => _ctrls.add(TextEditingController()));
  }

  void _removeNumber(int index) {
    if (index < 2) return; // primary + secondary are non-removable
    setState(() {
      _ctrls[index].dispose();
      _ctrls.removeAt(index);
    });
  }

  Future<void> _save() async {
    final values = _ctrls.map((c) => c.text).toList(growable: false);
    await ref
        .read(preferencesServiceProvider)
        .setEmergencyContacts(values);
    // ignore: discarded_futures
    ref.read(ttsServiceProvider).speak('Contacts saved.');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      duration: Duration(seconds: 2),
      backgroundColor: AppColors.surfaceContainer,
      content: Text('Emergency contacts saved.',
          style: TextStyle(color: AppColors.primaryContainer)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SosGestureWrapper(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              WfAppBar(
                onMenu: () => Navigator.of(context).pop(),
                trailingIcon: Icons.account_circle,
                trailingLabel: 'Account',
              ),
              Expanded(
                child: !_loaded
                    ? const Center(
                        child: CircularProgressIndicator(
                            color: AppColors.primaryContainer),
                      )
                    : SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.screenPadding,
                          AppSpacing.stackMargin,
                          AppSpacing.screenPadding,
                          AppSpacing.stackMargin,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const _PageHeading(),
                            const SizedBox(height: AppSpacing.stackMargin),
                            for (var i = 0; i < _ctrls.length; i++) ...[
                              _ContactField(
                                index: i,
                                controller: _ctrls[i],
                                onRemove: i >= 2
                                    ? () => _removeNumber(i)
                                    : null,
                              ),
                              if (i < _ctrls.length - 1)
                                const SizedBox(
                                    height: AppSpacing.elementGap),
                            ],
                            const SizedBox(height: AppSpacing.stackMargin),
                            _AddNumberButton(onTap: _addNumber),
                            const SizedBox(height: AppSpacing.elementGap),
                            Semantics(
                              button: true,
                              label: 'Save contacts',
                              child: SizedBox(
                                height: AppSpacing.touchTargetMin,
                                child: ElevatedButton(
                                  onPressed: _save,
                                  child: const Text('SAVE CONTACTS'),
                                ),
                              ),
                            ),
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

class _PageHeading extends StatelessWidget {
  const _PageHeading();
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: const Text(
            'Emergency Contacts',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 32,
              height: 40 / 32,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.32,
              color: AppColors.onSurface,
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'These numbers receive your location when you trigger an emergency alert.',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 16,
            height: 22 / 16,
            color: AppColors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _ContactField extends StatelessWidget {
  final int index;
  final TextEditingController controller;
  final VoidCallback? onRemove;
  const _ContactField({
    required this.index,
    required this.controller,
    this.onRemove,
  });

  String get _label {
    switch (index) {
      case 0:
        return 'Primary contact';
      case 1:
        return 'Secondary contact';
      default:
        return 'Contact ${index + 1}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenPadding, 16, AppSpacing.screenPadding, 16),
      decoration: BoxDecoration(
        color: AppColors.cardSurface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _label,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                    color: AppColors.onSurfaceVariant,
                  ),
                ),
              ),
              if (onRemove != null)
                Semantics(
                  button: true,
                  label: 'Remove $_label',
                  child: IconButton(
                    icon: const Icon(Icons.close,
                        color: AppColors.onSurfaceVariant),
                    onPressed: onRemove,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Semantics(
            textField: true,
            label: _label,
            child: TextField(
              controller: controller,
              style: const TextStyle(color: AppColors.onSurface),
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9 +\-()]')),
              ],
              decoration: const InputDecoration(
                hintText: 'e.g. +20 100 000 0000',
                prefixIcon: Icon(Icons.phone,
                    color: AppColors.primaryContainer),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddNumberButton extends StatelessWidget {
  final VoidCallback onTap;
  const _AddNumberButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Add new number',
      child: SizedBox(
        height: AppSpacing.touchTargetMin,
        child: OutlinedButton.icon(
          onPressed: onTap,
          icon: const Icon(Icons.add, color: AppColors.primaryContainer),
          label: const Text('ADD NEW NUMBER'),
        ),
      ),
    );
  }
}
