// A program loads a dependency's assets under `packages/<name>/`, as
// `flutter test` and `flutter build` key them; the same assets are bare in the
// package's own test (`//asset_keys:own_asset_keys_test`).
import 'package:asset_keys/asset_keys.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("a dependency's assets are keyed under its package", () async {
    expect((await rootBundle.loadString(ownAsset)).trim(), 'k');
    expect((await rootBundle.loadString(listedAsset)).trim(), 'p');
  });

  test("a dependency's asset is not one of the program's own", () async {
    await expectLater(
      rootBundle.loadString('assets/k.txt'),
      throwsA(isA<FlutterError>()),
    );
  });
}
