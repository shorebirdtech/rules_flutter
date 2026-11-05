import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:integration_test_example/main.dart' as app;

/// A test during which the app ends, with exit status 3. It runs only under
/// `:macos_crash_test`, which checks that the target fails and says why.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app exits during the test', (tester) async {
    app.main();
    await tester.pumpAndSettle();

    exit(3);
  });
}
