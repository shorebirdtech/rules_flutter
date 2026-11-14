// A library-level `@Skip` in an integration test: the suite's cases are
// skipped, and one that ran would fail it. The outcome tests in BUILD.bazel
// run it.
@Skip('skipped for the outcome test')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a skipped case', (tester) async {
    fail('the library is skipped');
  });
}
