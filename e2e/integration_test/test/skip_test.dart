// A library-level `@Skip`: every case is skipped, as `flutter test` skips
// them, and a case body that ran would fail the suite.
@Skip('skipped for the outcome test')
library;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a skipped case', () => fail('the library is skipped'));
}
