// A package's own test loads the package's assets by the keys `flutter test`
// gives them there: the paths its pubspec lists, with no `packages/<name>/`.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an asset is keyed by its path in the package', () async {
    expect((await rootBundle.loadString('assets/k.txt')).trim(), 'k');
    expect((await rootBundle.loadString('assets/p.txt')).trim(), 'p');
  });

  test('the package is not one of its own dependencies', () async {
    await expectLater(
      rootBundle.loadString('packages/asset_keys/assets/k.txt'),
      throwsA(isA<FlutterError>()),
    );
  });
}
