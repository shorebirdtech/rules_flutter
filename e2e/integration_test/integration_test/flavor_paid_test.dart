import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Run by a target whose application has `flavor = "paid"`: the app is that
/// flavor, as `flutter build --flavor paid` makes it.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('appFlavor is the flavor the target was built for', (_) async {
    expect(appFlavor, 'paid');
  });
}
