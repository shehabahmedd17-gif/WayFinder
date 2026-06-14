// Pure-Dart port of Python's _extract_option_number (py:839-873).
//
// Pulls an option number 1..4 out of free-form speech when the user is
// choosing among the (at most 4) Places results. There are exactly 4 options
// so anything > 4 is rejected.
//
// `inChoiceContext`:
//   true  (default) — user was just asked to pick an option. Accept digits,
//                      ordinals, and number words (with a guard against
//                      false positives like "two cars on the street").
//   false           — we are NOT expecting a choice. Only the most explicit
//                      forms are accepted: "option N" / "number N". A bare
//                      "two" in normal speech must NOT select anything.
//
// Returns the 1-based option index, or null if no confident match.

const int _kMaxOption = 4; // we only ever present 4 Places results

const Map<String, int> _kWords = {
  'one': 1,
  'two': 2,
  'three': 3,
  'four': 4,
};

const Map<String, int> _kOrdinals = {
  'first': 1,
  'second': 2,
  'third': 3,
  'fourth': 4,
  '1st': 1,
  '2nd': 2,
  '3rd': 3,
  '4th': 4,
};

// Strong selection keywords. NOTE: "the" is deliberately NOT here — it's far
// too common ("two cars on **the** street") and would defeat the guard.
const List<String> _kChoiceKeywords = [
  'option',
  'number',
  'choose',
  'pick',
  'select',
  'want',
  'go with',
];

int? extractOptionNumber(String userInput, {bool inChoiceContext = true}) {
  if (userInput.trim().isEmpty) return null;
  final t = userInput.toLowerCase().trim();

  // ── Strict mode: only "option N" / "number N" (N = digit | word | ordinal)
  if (!inChoiceContext) {
    final m = RegExp(
      r'\b(?:option|number)\s+'
      r'(1|2|3|4|one|two|three|four|first|second|third|fourth|'
      r'1st|2nd|3rd|4th)\b',
    ).firstMatch(t);
    if (m == null) return null;
    return _tokenToInt(m.group(1)!);
  }

  // ── 1. Digits (most reliable) — standalone 1..4 token ──────────────────
  for (final m in RegExp(r'\b([1-9])\b').allMatches(t)) {
    final n = int.parse(m.group(1)!);
    if (n >= 1 && n <= _kMaxOption) return n;
    if (n > _kMaxOption) return null; // "5" → no such option
  }

  // ── 2. Ordinals (strongly imply a selection) ───────────────────────────
  for (final e in _kOrdinals.entries) {
    if (RegExp('\\b${e.key}\\b').hasMatch(t)) {
      return e.value <= _kMaxOption ? e.value : null;
    }
  }

  // ── 3. Number words — guarded against false positives ──────────────────
  // Accept only when a strong choice keyword is present OR the whole
  // utterance is very short (≤ 3 words: "two", "number two", "the two").
  // "two cars on the street" (5 words, no kw) and "I see three people"
  // (4 words, no kw) are correctly rejected.
  final hasKeyword = _kChoiceKeywords.any((k) => t.contains(k));
  final wordCount = t.split(RegExp(r'\s+')).length;
  for (final e in _kWords.entries) {
    if (RegExp('\\b${e.key}\\b').hasMatch(t)) {
      if (hasKeyword || wordCount <= 3) {
        return e.value <= _kMaxOption ? e.value : null;
      }
      return null; // number word present but no choice intent
    }
  }

  return null;
}

int? _tokenToInt(String tok) {
  final d = int.tryParse(tok);
  if (d != null) return d <= _kMaxOption ? d : null;
  final w = _kWords[tok] ?? _kOrdinals[tok];
  if (w == null) return null;
  return w <= _kMaxOption ? w : null;
}
