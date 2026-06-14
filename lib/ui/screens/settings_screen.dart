// settings — port of design_reference/v2/.../simplified_settings.
//
// Three sections only (Step F-2):
//   EMERGENCY   — Emergency Contacts (→ EmergencyContactsScreen)
//                 Emergency Phone   (TODO F-3 SMS dispatch)
//   GLOBAL      — App Language       (TODO F-3 i18n)
//   NAVIGATION  — Precise Location   (toggle, persisted via prefs)
//
// The VOICE SETTINGS section is removed — TTS rate / voice picker were
// stubs and shipping a half-wired control creates more confusion than
// value. Voice tuning will return as part of F-3 if there's user demand.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../services/audio/tts_service.dart';
import '../../services/preferences_service.dart';
import '../../services/sms_service.dart';
import '../../theme/app_theme.dart';
import '../widgets/sos_gesture_wrapper.dart';
import '../widgets/wf_app_bar.dart';
import 'emergency_contacts_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with WidgetsBindingObserver {
  bool _loaded = false;

  // Current values (loaded from prefs in initState; UI is optimistic and
  // saves on toggle / SAVE).
  String? _emergencyPhone;
  String _language = 'English (US)';
  bool _preciseLocation = true;
  SmsPermissionState _smsState = SmsPermissionState.denied;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // ignore: discarded_futures
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // User may have changed SMS permission in system settings while we
      // were backgrounded — refresh the status row.
      // ignore: discarded_futures
      _refreshSmsState();
    }
  }

  Future<void> _refreshSmsState() async {
    final s = await ref.read(smsServiceProvider).getSmsPermissionState();
    if (!mounted) return;
    setState(() => _smsState = s);
  }

  Future<void> _load() async {
    final prefs = ref.read(preferencesServiceProvider);
    final phone = await prefs.getEmergencyPhone();
    final precise = await prefs.getPreciseLocation();
    final lang = await prefs.getAppLanguage();
    final smsState =
        await ref.read(smsServiceProvider).getSmsPermissionState();
    if (!mounted) return;
    setState(() {
      _emergencyPhone = phone;
      _preciseLocation = precise;
      _language = _languageLabelFor(lang);
      _smsState = smsState;
      _loaded = true;
    });
  }

  // Supported languages — kept tiny on purpose; the TTS wiring for non-en
  // locales is deferred (see _editLanguage docstring).
  static const Map<String, String> _kLanguages = {
    'en-US': 'English (US)',
    'en-GB': 'English (UK)',
  };
  String _languageLabelFor(String tag) =>
      _kLanguages[tag] ?? _kLanguages['en-US']!;
  String _languageTagFor(String label) => _kLanguages.entries
      .firstWhere((e) => e.value == label,
          orElse: () => _kLanguages.entries.first)
      .key;

  Future<void> _editEmergencyPhone() async {
    final ctrl = TextEditingController(text: _emergencyPhone ?? '');
    try {
      final newValue = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surfaceContainer,
          title: const Text('Emergency Phone'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.phone,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9 +\-()]')),
            ],
            style: const TextStyle(color: AppColors.onSurface),
            decoration: const InputDecoration(
              hintText: 'e.g. +20 100 000 0000',
              prefixIcon: Icon(Icons.phone,
                  color: AppColors.primaryContainer),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: const Text('Save'),
            ),
          ],
        ),
      );

      // Guard 1: widget may have unmounted while the dialog was open
      // (the framework "_dependents.isEmpty" assertion fires otherwise).
      if (!mounted) return;
      if (newValue == null) return; // user cancelled

      await ref
          .read(preferencesServiceProvider)
          .setEmergencyPhone(newValue);

      // Guard 2: setState across the await above.
      if (!mounted) return;
      setState(() => _emergencyPhone = newValue.isEmpty ? null : newValue);

      // TTS doesn't touch widget state — safe to fire-and-forget.
      unawaited(
          ref.read(ttsServiceProvider).speak(kPromptEmergencyPhoneSaved));
    } finally {
      // Controller MUST be disposed even when the dialog is dismissed
      // mid-flow or the screen unmounts during the showDialog await.
      ctrl.dispose();
    }
  }

  // TODO: wire selected language into TtsService.setLanguage() at app
  // start — deferred until we have non-English TTS coverage tested.
  Future<void> _editLanguage() async {
    final newLabel = await showDialog<String>(
      context: context,
      builder: (ctx) {
        var selected = _language;
        return StatefulBuilder(
          builder: (_, setLocal) => AlertDialog(
            backgroundColor: AppColors.surfaceContainer,
            title: const Text('App Language'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: _kLanguages.values
                  .map((label) => ListTile(
                        leading: Icon(
                          selected == label
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          color: AppColors.primaryContainer,
                        ),
                        title: Text(label,
                            style: const TextStyle(
                                color: AppColors.onSurface)),
                        onTap: () => setLocal(() => selected = label),
                      ))
                  .toList(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(selected),
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );

    // Guard across the dialog await — see _editEmergencyPhone for context.
    if (!mounted) return;
    if (newLabel == null) return;

    final tag = _languageTagFor(newLabel);
    await ref.read(preferencesServiceProvider).setAppLanguage(tag);

    if (!mounted) return;
    setState(() => _language = newLabel);
    unawaited(
        ref.read(ttsServiceProvider).speak(kPromptAppLanguageSaved));
  }

  Future<void> _openContacts() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const EmergencyContactsScreen()),
    );
    // Reload counts when returning so the row sub-text could reflect any
    // new state we may add later. Cheap; safe.
    if (mounted) await _load();
  }

  Future<void> _togglePrecise(bool v) async {
    setState(() => _preciseLocation = v);
    await ref.read(preferencesServiceProvider).setPreciseLocation(v);
  }

  Future<void> _onSmsStatusTap() async {
    final sms = ref.read(smsServiceProvider);
    switch (_smsState) {
      case SmsPermissionState.granted:
        unawaited(
            ref.read(ttsServiceProvider).speak(kPromptSmsStatusEnabled));
        return;
      case SmsPermissionState.denied:
        // In-app request — works on stock Android; on MIUI/Samsung the
        // status may transition straight to permanentlyDenied after this.
        await sms.requestSendSmsPermission();
        await _refreshSmsState();
        return;
      case SmsPermissionState.permanentlyDenied:
        unawaited(ref
            .read(ttsServiceProvider)
            .speak(kPromptSmsStatusOpenSettings));
        await sms.openAppSettingsPage();
        return;
    }
  }

  void _save() {
    // All toggles persist eagerly; this is a synchronous confirmation
    // for users who expect a "save" button. No await → no mounted guard
    // needed.
    unawaited(ref.read(ttsServiceProvider).speak('Preferences saved.'));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      duration: Duration(seconds: 2),
      backgroundColor: AppColors.surfaceContainer,
      content: Text('Preferences saved.',
          style: TextStyle(color: AppColors.primaryContainer)),
    ));
  }

  Future<void> _reset() async {
    final prefs = ref.read(preferencesServiceProvider);
    await prefs.setPreciseLocation(true);
    await prefs.setAppLanguage('en-US');
    if (!mounted) return;
    setState(() {
      _preciseLocation = true;
      _language = 'English (US)';
    });
    unawaited(
        ref.read(ttsServiceProvider).speak('Settings reset to defaults.'));
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
                            _Section(
                              title: 'EMERGENCY',
                              children: [
                                _SmsStatusRow(
                                  state: _smsState,
                                  onTap: _onSmsStatusTap,
                                ),
                                _NavRow(
                                  icon: Icons.contact_emergency,
                                  label: 'Emergency Contacts',
                                  value: '',
                                  onTap: _openContacts,
                                ),
                                _NavRow(
                                  icon: Icons.call,
                                  label: 'Emergency Phone',
                                  value: _emergencyPhone ?? 'Not set',
                                  onTap: _editEmergencyPhone,
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.stackMargin),
                            _Section(
                              title: 'GLOBAL',
                              children: [
                                _NavRow(
                                  icon: Icons.language,
                                  label: 'App Language',
                                  value: _language,
                                  onTap: _editLanguage,
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.stackMargin),
                            _Section(
                              title: 'NAVIGATION',
                              children: [
                                _ToggleRow(
                                  icon: Icons.near_me,
                                  label: 'Precise Location',
                                  value: _preciseLocation,
                                  onChanged: _togglePrecise,
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.stackMargin),
                            Semantics(
                              button: true,
                              label: 'Save preferences',
                              child: SizedBox(
                                height: AppSpacing.touchTargetMin,
                                child: ElevatedButton(
                                  onPressed: _save,
                                  child: const Text('SAVE PREFERENCES'),
                                ),
                              ),
                            ),
                            const SizedBox(height: AppSpacing.elementGap),
                            Semantics(
                              button: true,
                              label: 'Reset to defaults',
                              child: SizedBox(
                                height: AppSpacing.touchTargetMin,
                                child: OutlinedButton(
                                  onPressed: _reset,
                                  child: const Text('RESET TO DEFAULTS'),
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

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8, bottom: AppSpacing.elementGap),
          child: Text(
            title,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 16,
              fontWeight: FontWeight.w800,
              letterSpacing: 2.0,
              color: AppColors.onSurfaceVariant,
            ),
          ),
        ),
        for (var i = 0; i < children.length; i++) ...[
          children[i],
          if (i < children.length - 1) const SizedBox(height: 4),
        ],
      ],
    );
  }
}

class _NavRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;
  const _NavRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: value.isEmpty ? label : '$label: $value',
      child: Material(
        color: AppColors.cardSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: onTap,
          child: Container(
            constraints:
                const BoxConstraints(minHeight: AppSpacing.touchTargetMin),
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.screenPadding, vertical: 16),
            child: Row(
              children: [
                ExcludeSemantics(
                  child:
                      Icon(icon, color: AppColors.primaryContainer, size: 24),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 18,
                      color: AppColors.onSurface,
                    ),
                  ),
                ),
                if (value.isNotEmpty)
                  Text(
                    value,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 16,
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(width: 4),
                const ExcludeSemantics(
                  child: Icon(Icons.chevron_right,
                      color: AppColors.primaryContainer, size: 24),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ToggleRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.cardSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.screenPadding, vertical: 8),
        child: Row(
          children: [
            ExcludeSemantics(
              child: Icon(icon, color: AppColors.primaryContainer, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 18,
                  color: AppColors.onSurface,
                ),
              ),
            ),
            Semantics(
              toggled: value,
              label: label,
              child: Switch(
                value: value,
                onChanged: onChanged,
                activeThumbColor: AppColors.primaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// SMS Auto-Send Status row. Visual + tap behaviour key off the current
// SmsPermissionState. Refreshes on AppLifecycleState.resumed so the user
// who toggles permission in system settings sees the change on return.
class _SmsStatusRow extends StatelessWidget {
  final SmsPermissionState state;
  final VoidCallback onTap;
  const _SmsStatusRow({required this.state, required this.onTap});

  @override
  Widget build(BuildContext context) {
    late final IconData icon;
    late final Color iconColor;
    late final String label;
    late final String hint;

    switch (state) {
      case SmsPermissionState.granted:
        icon = Icons.check_circle;
        iconColor = AppColors.primaryContainer;
        label = 'SMS Auto-Send: Enabled';
        hint = '';
        break;
      case SmsPermissionState.denied:
        icon = Icons.warning_amber;
        iconColor = AppColors.primaryContainer;
        label = 'SMS Auto-Send: Disabled';
        hint = 'tap to enable';
        break;
      case SmsPermissionState.permanentlyDenied:
        icon = Icons.error;
        iconColor = AppColors.error;
        label = 'SMS Auto-Send: Blocked';
        hint = 'tap to open settings';
        break;
    }

    return Semantics(
      button: true,
      label: hint.isEmpty ? label : '$label, $hint',
      child: Material(
        color: AppColors.cardSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: onTap,
          child: Container(
            constraints:
                const BoxConstraints(minHeight: AppSpacing.touchTargetMin),
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.screenPadding, vertical: 16),
            child: Row(
              children: [
                ExcludeSemantics(
                    child: Icon(icon, color: iconColor, size: 24)),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 18,
                          color: AppColors.onSurface,
                        ),
                      ),
                      if (hint.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            hint,
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 13,
                              color: AppColors.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (state != SmsPermissionState.granted)
                  const ExcludeSemantics(
                    child: Icon(Icons.chevron_right,
                        color: AppColors.primaryContainer, size: 24),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
