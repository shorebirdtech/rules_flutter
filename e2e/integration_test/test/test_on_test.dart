// A library-level `@TestOn` that no host matches: `flutter test` does not load
// the suite, so it neither runs nor fails for having no tests.
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a case on another platform', () => fail('not run on the vm'));
}
