// Tag selection, as `flutter_test` applies it: the library's tag reaches every
// case, and `tags:` on a test reaches that test (`flutter_test`'s `group` takes
// no tags). Run whole, all three cases pass; the outcome tests in
// BUILD.bazel run it with a selection and name the cases that remain.
@Tags(['library_tag'])
library;

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('golden group', () {
    test('a golden case', () {}, tags: 'golden');
  });

  test('a slow case', () {}, tags: ['slow']);

  test('an untagged case', () {});
}
