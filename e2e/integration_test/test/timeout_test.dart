// A library-level `@Timeout` replaces Bazel's limit for every case: this one
// is meant to fail, a case that outlives it.
@Timeout(Duration(milliseconds: 500))
library;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a case that outlives the timeout', () async {
    await Future<void>.delayed(const Duration(seconds: 30));
  });
}
