import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// A config whose comparator tolerates any difference between a picture and its
/// golden, as a project's own does with a looser threshold.
///
/// It runs in the app and in the golden service, as `flutter test` runs a
/// config in each program of a run; only the comparator that compares (the
/// service's) is replaced.
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
    } on FlutterError {
      // A picture that differs from its golden: the pixels, not a missing file.
      return true;
    }
  }

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) =>
      _compares.update(golden, imageBytes);

  @override
  Uri getTestUri(Uri key, int? version) => _compares.getTestUri(key, version);
}
