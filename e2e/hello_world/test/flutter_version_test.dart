// A `flutter_test` is compiled with the defines `flutter test` adds, so
// `FlutterVersion` and `appBuildName` read what they would under `flutter test`
// instead of null. `package:flutter` is compiled as a module of its own, so
// this also shows the defines reach it.
//
// The BUILD file passes what the pinned release should report as
// `EXPECTED_*`, and the target sets `build_name` and `build_number`.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

String expected(String name) {
  final value = Platform.environment['EXPECTED_$name'];
  if (value == null) {
    throw StateError('the BUILD file did not pass EXPECTED_$name');
  }
  return value;
}

void main() {
  test('FlutterVersion is the pinned release', () {
    expect(FlutterVersion.version, expected('FLUTTER_VERSION'));
    expect(FlutterVersion.channel, 'stable');
    expect(FlutterVersion.gitUrl, 'https://github.com/flutter/flutter.git');
    expect(
      FlutterVersion.frameworkRevision,
      expected('FLUTTER_FRAMEWORK_REVISION'),
    );
    expect(
      FlutterVersion.engineRevision,
      expected('FLUTTER_ENGINE_REVISION'),
    );
  });

  test('FlutterVersion.dartVersion is the Dart the engine runs', () {
    expect(FlutterVersion.dartVersion, isNotNull);
    expect(Platform.version, startsWith(FlutterVersion.dartVersion!));
  });

  test("appBuildName and appBuildNumber are the target's", () {
    expect(appBuildName, '2.3.4');
    expect(appBuildNumber, '7');
  });
}
