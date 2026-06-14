// Renders YOLO bounding boxes over the camera preview.
//
// v2 (Step F-3 follow-up): boxes are amber rounded rectangles with a
// Stitch-style pill label floating above the top-left edge — switched
// from CustomPainter to a Stack of Positioned `_DetectionBox` widgets
// so the pill can be a real Material widget with proper text rendering,
// padding, and a coloured border, instead of hand-drawn TextPainter.
//
// Coordinate-space contract (unchanged from v1):
//   - Detection.{x1,y1,x2,y2}    — normalized [0,1] to CAMERA pixel space
//                                   (after un-letterbox in the pipeline).
//   - Detection.{yoloX1..yoloY2} — normalized [0,1] to YOLO 640 input
//                                   space (debug-only, cyan overlay).
//   - imgW / imgH                — camera image pixel dims (e.g. 720×480).
//
// Camera → widget mapping uses BoxFit.cover math (preserve aspect ratio,
// center-crop the long axis) — same as v1, factored out into _coverFit.

import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../models/detection.dart';
import '../../theme/app_theme.dart';

class DetectionOverlay extends StatelessWidget {
  final List<Detection> detections;
  final int imgW;
  final int imgH;
  final bool showTestRect;
  final bool showRawYoloBoxes; // cyan debug A/B overlay (kDebugUI-gated)

  const DetectionOverlay({
    super.key,
    required this.detections,
    this.imgW = 0,
    this.imgH = 0,
    this.showTestRect = false,
    this.showRawYoloBoxes = false,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, constraints) {
      final size = constraints.biggest;
      final fit = _coverFit(size, imgW.toDouble(), imgH.toDouble());

      return Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.hardEdge,
        children: [
          // ── Cyan debug overlay (raw YOLO-space) ────────────────────────
          if (showRawYoloBoxes && kDebugUI)
            CustomPaint(
              painter: _RawYoloBoxesPainter(detections),
              child: const SizedBox.expand(),
            ),

          // ── Magenta PAINTER-OK test rect (debug) ───────────────────────
          if (showTestRect && kDebugUI)
            CustomPaint(
              painter: _TestRectPainter(),
              child: const SizedBox.expand(),
            ),

          // ── Detection boxes + pill labels ──────────────────────────────
          ..._boxes(size, fit),
        ],
      );
    });
  }

  List<Widget> _boxes(Size size, _CoverFit fit) {
    final out = <Widget>[];
    for (final d in detections) {
      final risk = kRiskWeights[d.label];
      final isRiskClass = risk != null;
      // Production: only draw risk-bearing detections — non-risk classes
      // never reach the announcer either, so they shouldn't clutter the
      // visual either. Show everything when kDebugUI is on.
      if (!isRiskClass && !kDebugUI) continue;

      final rect = fit.mapNorm(d.x1, d.y1, d.x2, d.y2);
      // Clamp to widget bounds — a partially-off-screen box would otherwise
      // place its label off-screen too.
      final left = rect.left.clamp(0.0, size.width);
      final top = rect.top.clamp(0.0, size.height);
      final right = rect.right.clamp(0.0, size.width);
      final bottom = rect.bottom.clamp(0.0, size.height);
      final width = (right - left).clamp(0.0, size.width);
      final height = (bottom - top).clamp(0.0, size.height);
      if (width < 8 || height < 8) continue; // too small to render usefully

      final isHigh = _isHighPriority(d, risk);
      final label = _labelText(d, isHigh);
      // If the box's top edge is within the pill height of the screen top,
      // tuck the pill INSIDE the box instead of floating above it.
      final pillAboveTop = top >= 36;

      out.add(Positioned(
        left: left,
        top: top,
        width: width,
        height: height,
        child: _DetectionBox(
          label: label,
          isHighPriority: isHigh,
          pillAboveTop: pillAboveTop,
        ),
      ));
    }
    return out;
  }

  // ── Priority classification (visual only — TTS priority is separate) ──
  // HIGH: risk weight ≥ 2.5 (person/car/bus/truck/motorcycle/bicycle/dog)
  // AND the obstacle is close (depth bin ≠ "far").
  static bool _isHighPriority(Detection d, double? risk) {
    if (risk == null || risk < 2.5) return false;
    return d.distLabel == 'extremely close' ||
        d.distLabel == 'very close' ||
        d.distLabel == 'close';
  }

  // Coarse distance bins for the LOW-priority label.
  // MiDaS is relative depth, so this is a heuristic — we map the depth
  // bucket the pipeline already computes (distLabel) onto a small set
  // of approximate metres for display.
  static String _distanceMetres(Detection d) {
    switch (d.distLabel) {
      case 'extremely close':
        return '<2m';
      case 'very close':
        return '2m';
      case 'close':
        return '3m';
      case 'far':
      default:
        return '5m+';
    }
  }

  // HIGH: "{class} — {proximity} — {direction}"
  //   proximity = distLabel ('extremely close' / 'very close' / 'close')
  //   direction = position with the "on " prefix stripped ('left' / 'ahead' / 'right')
  // LOW:  "{class} — {Nm}"
  static String _labelText(Detection d, bool isHigh) {
    if (isHigh) {
      final dir = d.position.replaceFirst('on ', '');
      return '${d.label} — ${d.distLabel} — $dir';
    }
    return '${d.label} — ${_distanceMetres(d)}';
  }
}

// ── BoxFit.cover transform ──────────────────────────────────────────────
class _CoverFit {
  final double displayedW;
  final double displayedH;
  final double offsetX;
  final double offsetY;
  const _CoverFit(
      this.displayedW, this.displayedH, this.offsetX, this.offsetY);

  Rect mapNorm(double x1, double y1, double x2, double y2) => Rect.fromLTRB(
        x1 * displayedW + offsetX,
        y1 * displayedH + offsetY,
        x2 * displayedW + offsetX,
        y2 * displayedH + offsetY,
      );
}

_CoverFit _coverFit(Size widget, double imgW, double imgH) {
  if (imgW <= 0 || imgH <= 0) {
    return _CoverFit(widget.width, widget.height, 0, 0);
  }
  final cameraAR = imgW / imgH;
  final widgetAR = widget.width / widget.height;
  if (cameraAR > widgetAR) {
    final h = widget.height;
    final w = h * cameraAR;
    return _CoverFit(w, h, (widget.width - w) / 2, 0);
  } else {
    final w = widget.width;
    final h = w / cameraAR;
    return _CoverFit(w, h, 0, (widget.height - h) / 2);
  }
}

// ── One bounding box (amber rounded rectangle) + label pill ─────────────
class _DetectionBox extends StatelessWidget {
  final String label;
  final bool isHighPriority;
  // false → label tucked just inside the top of the box (the box hugs
  // the screen top, so a floating pill would render off-screen).
  final bool pillAboveTop;

  const _DetectionBox({
    required this.label,
    required this.isHighPriority,
    required this.pillAboveTop,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(
                    color: AppColors.primaryContainer, width: 3),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        Positioned(
          // -32 floats the pill above the top edge; +4 tucks it just
          // inside the top of the box when there's no room above.
          top: pillAboveTop ? -32 : 4,
          left: 4,
          child: ExcludeSemantics(
            child: _LabelPill(text: label, isHighPriority: isHighPriority),
          ),
        ),
      ],
    );
  }
}

class _LabelPill extends StatelessWidget {
  final String text;
  final bool isHighPriority;
  const _LabelPill({required this.text, required this.isHighPriority});

  @override
  Widget build(BuildContext context) {
    if (isHighPriority) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.primaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          text,
          style: const TextStyle(
            fontFamily: 'Inter',
            color: AppColors.onPrimaryFixed,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer,
        border: Border.all(color: AppColors.primaryContainer, width: 1.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: 'Inter',
          color: AppColors.primaryContainer,
          fontSize: 14,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

// ── Debug-only painters ─────────────────────────────────────────────────
class _RawYoloBoxesPainter extends CustomPainter {
  final List<Detection> detections;
  const _RawYoloBoxesPainter(this.detections);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF00E0FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final d in detections) {
      canvas.drawRect(
        Rect.fromLTRB(
          d.yoloX1 * size.width,
          d.yoloY1 * size.height,
          d.yoloX2 * size.width,
          d.yoloY2 * size.height,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_RawYoloBoxesPainter old) =>
      old.detections != detections;
}

class _TestRectPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFFF00FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    final r = Rect.fromCenter(
      center: Offset(size.width * 0.5, size.height * 0.5),
      width: 80,
      height: 80,
    );
    canvas.drawRect(r, paint);
    final tp = TextPainter(
      text: const TextSpan(
        text: 'PAINTER OK',
        style: TextStyle(
          color: Color(0xFFFF00FF),
          fontSize: 10,
          fontWeight: FontWeight.bold,
          shadows: [Shadow(color: Colors.black, blurRadius: 2)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(r.left, r.top - 12));
  }

  @override
  bool shouldRepaint(_TestRectPainter old) => false;
}
