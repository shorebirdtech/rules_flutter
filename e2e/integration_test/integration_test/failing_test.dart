import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:integration_test_example/main.dart' as app;

/// A test that is wrong: it expects the counter to read 99 after one tap. It
/// runs only under `:macos_red_twin_test`, which checks that a failing
/// integration test fails its target.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('counter reads 99 after one tap', (tester) async {
    app.main();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('increment')));
    await tester.pumpAndSettle();

    expect(find.text('99'), findsOneWidget);
  });
}
