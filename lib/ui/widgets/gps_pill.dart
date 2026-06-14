import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants.dart';
import '../../services/location/gps_service.dart';

// Small GPS coordinate pill — bottom-left corner.
// py: gps_label overlay (lines 1643-1651).
//
// Reads currentLocationProvider (LocationFix?). Before the first fix it shows
// the Cairo fallback coords greyed out. When the active fix is a fallback the
// pill turns amber so a sighted helper can see "approximate location".
class GpsPill extends ConsumerWidget {
  const GpsPill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fix = ref.watch(currentLocationProvider);

    final lat = fix?.lat ?? kGpsFallbackLat;
    final lng = fix?.lng ?? kGpsFallbackLng;
    final isFallback = fix?.isFallback ?? true;
    final color = isFallback ? Colors.amber : Colors.greenAccent;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.7), width: 1),
      ),
      child: Text(
        '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}'
        '${isFallback ? ' ~approx' : ''}',
        style: TextStyle(color: color, fontSize: 11),
      ),
    );
  }
}
