// A library-level `@TestOn` that no host matches in an integration test: the
// app is never launched and the suite passes, as `flutter test` does not load
// it.
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a case on another platform', (tester) async {
    fail('not run on the vm');
  });
}
