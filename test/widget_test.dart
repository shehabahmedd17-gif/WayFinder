// Smoke test — verifies app builds without crashing.
// Full integration tests are added in later steps.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_nav/app.dart';

void main() {
  testWidgets('App builds without error', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: SmartNavApp()));
    expect(find.byType(SmartNavApp), findsOneWidget);
  });
}
