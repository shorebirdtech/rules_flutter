// A `flutter_test` without a `flavor` has none, as `flutter test` without
// `--flavor`: `appFlavor` is null.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('appFlavor is null without a flavor', () {
    expect(appFlavor, isNull);
  });
}
