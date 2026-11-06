// Tag selection in an integration test: the library's tag reaches every case
// and `tags:` reaches the case it is given to. Run whole, both cases pass; the
// outcome tests in BUILD.bazel run it with a selection.
@Tags(['library_tag'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a golden case', (tester) async {}, tags: 'golden');

  testWidgets('an untagged case', (tester) async {});
}
