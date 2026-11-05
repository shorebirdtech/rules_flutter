import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:web_example/main.dart' as app;

/// The render check of docs/TESTING.md § 5, run in headless Chrome by
/// `:render_test`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the app draws its screen from the framework', (tester) async {
    app.main();
    await tester.pumpAndSettle();

    // Text read back out of the widget tree: the engine booted, the framework
    // built the tree, and what it built is the app's.
    expect(
      find.text('You have pushed the button this many times:'),
      findsOneWidget,
    );
    expect(find.text('0'), findsOneWidget);
  });

  testWidgets('the app resolved its asset bundle', (tester) async {
    app.main();
    await tester.pumpAndSettle();

    // `FutureBuilder` over `assets/message.txt`: a bundle that boots and paints
    // but cannot resolve its assets shows an empty label here, and so does an
    // asset the build left out.
    final label = tester.widget<Text>(
      find.byKey(const ValueKey('e2e_asset_label')),
    );
    expect(label.data, 'web asset v1');
  });

  testWidgets('a tap reaches the app', (tester) async {
    app.main();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Increment'));
    await tester.pumpAndSettle();

    expect(find.text('1'), findsOneWidget);
  });
}
