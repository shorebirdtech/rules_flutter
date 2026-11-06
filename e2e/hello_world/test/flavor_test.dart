// A `flutter_test` with `flavor = "paid"` is that flavor, as under
// `flutter test --flavor paid`: `appFlavor` is `paid`. `package:flutter` is
// compiled as a module of its own, so this also shows the flavor reaches it.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('appFlavor is the flavor of the test target', () {
    expect(appFlavor, 'paid');
  });
}
