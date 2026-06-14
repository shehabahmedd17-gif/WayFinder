// permissions_setup — port of design_reference/.../permissions_setup.
// Not yet wired into the main navigation flow; the runtime permission
// flow (permission_handler) is still triggered lazily by the camera +
// STT services on first use. This screen exists as a Stitch-faithful
// shell so the design is ready when we add an "onboarding" flow.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../theme/app_theme.dart';

class PermissionsScreen extends ConsumerStatefulWidget {
  final VoidCallback onContinue;
  const PermissionsScreen({super.key, required this.onContinue});

  @override
  ConsumerState<PermissionsScreen> createState() =>
      _PermissionsScreenState();
}

class _PermissionsScreenState extends ConsumerState<PermissionsScreen> {
  Map<Permission, PermissionStatus> _status = {};

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _refresh();
  }

  Future<void> _refresh() async {
    final perms = [
      Permission.camera,
      Permission.microphone,
      Permission.location,
    ];
    final next = <Permission, PermissionStatus>{};
    for (final p in perms) {
      next[p] = await p.status;
    }
    if (!mounted) return;
    setState(() => _status = next);
  }

  Future<void> _request(Permission p) async {
    await p.request();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final cards = <Widget>[
      _PermCard(
        icon: Icons.photo_camera,
        label: 'Camera',
        status: _status[Permission.camera] ?? PermissionStatus.denied,
        onTap: () => _request(Permission.camera),
      ),
      _PermCard(
        icon: Icons.mic,
        label: 'Microphone',
        status: _status[Permission.microphone] ?? PermissionStatus.denied,
        onTap: () => _request(Permission.microphone),
      ),
      _PermCard(
        icon: Icons.location_on,
        label: 'Location',
        status: _status[Permission.location] ?? PermissionStatus.denied,
        onTap: () => _request(Permission.location),
      ),
    ];

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.screenPadding,
              vertical: AppSpacing.stackMargin),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'WayFinder needs a few permissions',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 28,
                  height: 34 / 28,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.28,
                  color: AppColors.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'To provide the best navigation experience, please allow the following access.',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 18,
                  height: 28 / 18,
                  color: AppColors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.stackMargin),
              Expanded(
                child: ListView.separated(
                  itemCount: cards.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: AppSpacing.elementGap),
                  itemBuilder: (_, i) => cards[i],
                ),
              ),
              const SizedBox(height: AppSpacing.elementGap),
              Semantics(
                button: true,
                label: 'Continue',
                child: SizedBox(
                  height: AppSpacing.touchTargetMin,
                  child: ElevatedButton(
                    onPressed: widget.onContinue,
                    child: const Text('Continue'),
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

class _PermCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final PermissionStatus status;
  final VoidCallback onTap;
  const _PermCard({
    required this.icon,
    required this.label,
    required this.status,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final granted = status.isGranted;
    return Semantics(
      button: !granted,
      label: granted ? '$label granted' : '$label required',
      child: Material(
        color: AppColors.cardSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: BorderSide(
            color: granted
                ? Colors.transparent
                : AppColors.primaryContainer.withValues(alpha: 0.30),
            width: 2,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: granted ? null : onTap,
          child: Container(
            constraints:
                const BoxConstraints(minHeight: AppSpacing.touchTargetMin),
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.screenPadding, vertical: 14),
            child: Row(
              children: [
                ExcludeSemantics(
                  child: Icon(icon, color: AppColors.primaryContainer, size: 32),
                ),
                const SizedBox(width: AppSpacing.elementGap),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: AppColors.onSurface,
                    ),
                  ),
                ),
                _StatusPill(granted: granted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final bool granted;
  const _StatusPill({required this.granted});
  @override
  Widget build(BuildContext context) {
    final bg = granted ? const Color(0xFF1B5E20) : AppColors.primaryContainer;
    final fg = granted ? Colors.white : AppColors.onPrimaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Text(
        granted ? 'Granted' : 'Required',
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 14,
          fontWeight: FontWeight.w800,
          color: fg,
        ),
      ),
    );
  }
}
