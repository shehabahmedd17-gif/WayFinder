// place_results — phase ∈ {searching, presentingOptions, awaitingChoice}.
// Port of design_reference/.../place_results.
//   - "I found these places" (28 px Inter 700 white) — or "Searching…" while
//     places call is in-flight.
//   - Cards: huge amber number "1"/"2"/"3"/"4" on left + name (22 px Inter
//     700) + address (16 px on-surface-variant) on right. min-h 100, full
//     width, cardSurface bg, rounded-xl 12 px.
//   - Footer prompt: "Say a number or tap a card" (20 px Inter 700 amber)
//     + 64 px filled amber mic disc.
//
// Tapping a card submits the corresponding option number through the same
// `submitTranscript` seam STT uses — no separate code path.

import 'package:flutter/material.dart';

import '../../../models/place.dart';
import '../../../state/navigation_notifier.dart';
import '../../../theme/app_theme.dart';

class PlaceResultsView extends StatelessWidget {
  final OutdoorState state;
  final void Function(int oneBased) onPickIndex;

  const PlaceResultsView({
    super.key,
    required this.state,
    required this.onPickIndex,
  });

  @override
  Widget build(BuildContext context) {
    final isSearching = state.phase == OutdoorPhase.searching;
    final title = isSearching
        ? 'Searching for ${state.query}…'
        : 'I found these places';

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.screenPadding, 24,
          AppSpacing.screenPadding, AppSpacing.screenPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            liveRegion: true,
            label: title,
            child: Text(
              title,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 28,
                height: 32 / 28,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.28,
                color: AppColors.onSurface,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.stackMargin),
          if (isSearching)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: CircularProgressIndicator(
                    color: AppColors.primaryContainer),
              ),
            )
          else
            ..._resultCards(),
          const SizedBox(height: AppSpacing.stackMargin),
          // Footer prompt
          Center(
            child: Column(
              children: [
                Text(
                  state.phase == OutdoorPhase.awaitingChoice
                      ? 'Say a number or tap a card'
                      : 'Listening…',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 20,
                    height: 24 / 20,
                    fontWeight: FontWeight.w800,
                    color: AppColors.primaryContainer,
                  ),
                ),
                const SizedBox(height: AppSpacing.elementGap),
                _MicChip(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _resultCards() {
    final items = <Widget>[];
    for (var i = 0; i < state.options.length; i++) {
      final p = state.options[i];
      final n = i + 1;
      // Voice-first: option cards are VISUAL ONLY — taps on them fall
      // through to the OutdoorScreen body GestureDetector, which kicks
      // off STT for the choice. IgnorePointer + onTap kept as a callable
      // for the debug text input that still calls onPickIndex directly.
      items.add(IgnorePointer(
        child: _ResultCard(
          number: n,
          place: p,
          onTap: () => onPickIndex(n),
        ),
      ));
      if (i < state.options.length - 1) {
        items.add(const SizedBox(height: AppSpacing.elementGap));
      }
    }
    return items;
  }
}

class _ResultCard extends StatelessWidget {
  final int number;
  final Place place;
  final VoidCallback onTap;
  const _ResultCard({
    required this.number,
    required this.place,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Option $number: ${place.name}. ${place.address}',
      child: Material(
        color: AppColors.cardSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: const BorderSide(color: Colors.transparent, width: 2),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.screenPadding, vertical: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 76),
              child: Row(
                children: [
                  // Huge amber number — 48 px Inter 800
                  SizedBox(
                    width: 48,
                    child: Center(
                      child: Text(
                        '$number',
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 48,
                          height: 1.0,
                          fontWeight: FontWeight.w800,
                          color: AppColors.primaryContainer,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          place.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 22,
                            height: 26 / 22,
                            fontWeight: FontWeight.w700,
                            color: AppColors.onSurface,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          place.address,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 16,
                            height: 22 / 16,
                            color: AppColors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MicChip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: 64,
        height: 64,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.primaryContainer,
        ),
        child: const Icon(Icons.mic, color: Colors.black, size: 32),
      ),
    );
  }
}
