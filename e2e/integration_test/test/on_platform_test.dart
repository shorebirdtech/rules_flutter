// A library-level `@OnPlatform` that matches the host, whichever it is, and
// skips: a case body that ran would fail the suite.
@OnPlatform({'mac-os || linux || windows': Skip('skipped on this host')})
library;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a case skipped by platform', () => fail('skipped on this host'));
}
