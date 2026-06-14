// Unit tests for lib/services/places/option_parser.dart
// Pure-Dart port of py:839-873 _extract_option_number.

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_nav/services/places/option_parser.dart';

void main() {
  group('extractOptionNumber — in choice context (default)', () {
    test('1. bare digit "2" → 2', () {
      expect(extractOptionNumber('2'), 2);
    });

    test('2. embedded digit "I want 3" → 3', () {
      expect(extractOptionNumber('I want 3'), 3);
    });

    test('3. "option 4" → 4', () {
      expect(extractOptionNumber('option 4'), 4);
    });

    test('4. ordinal "first" → 1', () {
      expect(extractOptionNumber('first'), 1);
    });

    test('5. "the second one" → 2', () {
      expect(extractOptionNumber('the second one'), 2);
    });

    test('6. "2nd" → 2', () {
      expect(extractOptionNumber('2nd'), 2);
    });

    test('7. "the third place" → 3', () {
      expect(extractOptionNumber('the third place'), 3);
    });

    test('8. "fourth" → 4', () {
      expect(extractOptionNumber('fourth'), 4);
    });

    test('9. bare number word "one" → 1', () {
      expect(extractOptionNumber('one'), 1);
    });

    test('10. "go with number 2" → 2', () {
      expect(extractOptionNumber('go with number 2'), 2);
    });

    test('11. "I want two" (has "want" keyword) → 2', () {
      expect(extractOptionNumber('I want two'), 2);
    });

    test('12. false positive: "two cars on the street" → null', () {
      expect(extractOptionNumber('two cars on the street'), isNull);
    });

    test('13. false positive: "I see three people" → null', () {
      expect(extractOptionNumber('I see three people'), isNull);
    });

    test('14. out of range: "option 5" → null', () {
      expect(extractOptionNumber('option 5'), isNull);
    });

    test('15. out of range: bare "5" → null', () {
      expect(extractOptionNumber('5'), isNull);
    });

    test('16. out of range: "fifth" → null', () {
      expect(extractOptionNumber('fifth'), isNull);
    });

    test('17. empty / whitespace → null', () {
      expect(extractOptionNumber(''), isNull);
      expect(extractOptionNumber('   '), isNull);
    });

    test('18. nonsense → null', () {
      expect(extractOptionNumber('uhh maybe the cafe place'), isNull);
    });
  });

  group('extractOptionNumber — NOT in choice context (strict)', () {
    test('19. "option 2" still works', () {
      expect(extractOptionNumber('option 2', inChoiceContext: false), 2);
    });

    test('20. "number three" still works', () {
      expect(extractOptionNumber('number three', inChoiceContext: false), 3);
    });

    test('21. "option first" works (ordinal token)', () {
      expect(extractOptionNumber('option first', inChoiceContext: false), 1);
    });

    test('22. bare "two" → null (not explicit enough)', () {
      expect(extractOptionNumber('two', inChoiceContext: false), isNull);
    });

    test('23. bare digit "3" → null', () {
      expect(extractOptionNumber('3', inChoiceContext: false), isNull);
    });

    test('24. bare ordinal "second" → null', () {
      expect(extractOptionNumber('second', inChoiceContext: false), isNull);
    });

    test('25. strict out-of-range: "option 5" → null', () {
      expect(extractOptionNumber('option 5', inChoiceContext: false), isNull);
    });
  });
}
