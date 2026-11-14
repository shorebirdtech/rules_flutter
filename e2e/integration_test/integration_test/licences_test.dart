import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// The framework's licence registry reads the app's `NOTICES` (`NOTICES.Z`
/// outside the web) from its bundle. The test bindings register no licences
/// (`flutter_test` leaves them out), so this checks that the app can load the
/// asset the registry would, under the name and in the form the platform's
/// framework reads: plain text on the web, gzip elsewhere.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the app loads the NOTICES asset the framework reads', (
    tester,
  ) async {
    if (kIsWeb) {
      final text = await rootBundle.loadString('NOTICES', cache: false);
      expect(text, contains('skia'));

      // An entry names the packages it covers on its first lines: the app's
      // own package:flutter is one, beside the engine's.
      final entries = text.split('\n${'-' * 80}\n');
      final named = [
        for (final e in entries) ...e.split('\n\n').first.split('\n'),
      ];
      expect(
        named,
        contains('flutter'),
        reason: 'an entry for package:flutter',
      );
    } else {
      final bytes = (await rootBundle.load('NOTICES.Z')).buffer.asUint8List();
      expect(bytes.length, greaterThan(1000));
      expect(bytes.sublist(0, 2), [0x1f, 0x8b], reason: 'a gzip stream');
    }
  });
}
