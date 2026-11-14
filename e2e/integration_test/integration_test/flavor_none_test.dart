import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Run by a target whose application has no `flavor`: as with `flutter build`
/// without `--flavor`, there is none.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('appFlavor is null without a flavor', (_) async {
    expect(appFlavor, isNull);
  });
}
