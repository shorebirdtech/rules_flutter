import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test_example/golden_tolerance.dart';

/// A config whose comparator tolerates a difference between a picture and its
/// golden when the app's own [goldensTolerateDifferences] says to, as a
/// project's does with a looser threshold.
///
/// It runs in the app and in the golden service, as `flutter test` runs a
/// config in each program of a run, and like `flutter test`'s it is compiled in
/// the app's package, so it imports the app's libraries by `package:` URI. Only
/// the comparator that compares (the service's) is replaced.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final installed = goldenFileComparator;
  if (installed is LocalFileComparator) {
    goldenFileComparator = _TolerantComparator(installed);
  }
  await testMain();
}

class _TolerantComparator extends GoldenFileComparator {
  _TolerantComparator(this._compares);

  final LocalFileComparator _compares;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    try {
      return await _compares.compare(imageBytes, golden);
      // `FlutterError` is how the comparator reports a difference.
      // ignore: avoid_catching_errors
    } on FlutterError {
      // A picture that differs from its golden: the pixels, not a missing file.
      if (goldensTolerateDifferences) return true;
      rethrow;
    }
  }

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) =>
      _compares.update(golden, imageBytes);

  @override
  Uri getTestUri(Uri key, int? version) => _compares.getTestUri(key, version);
}
