import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

// The snapshot hash of the pinned release's Dart. It changes with the Flutter
// version this repository pins: update it with the pin. A release whose
// binaries hold a second hex constant that fits the scan fails this test
// instead of a user's build.
const _pinnedSnapshotHash = '0451907c2eaa8467e848c0067bfe8ed4';

void main() {
  // The check over every stock artifact of one host and mode: the engine, the
  // gen_snapshot (AOT modes), the platform kernel, the Dart SDK and its
  // runtime. They must agree, and on the pinned release's hash.
  for (final mode in ['debug', 'profile', 'release']) {
    test('the stock $mode artifacts pass the check', () {
      final file = Runfiles.create().rlocation(
        '_main/flutter/private/tools/stock_record_${mode}_check/flutter_sdk.json',
      );
      final record =
          jsonDecode(File(file).readAsStringSync()) as Map<String, Object?>;
      expect(record['snapshot_hash'], _pinnedSnapshotHash);
      expect(record['kernel'], containsPair('format', isA<int>()));
      expect(record['sdk'], 'flutter');
      expect(record['framework'], containsPair('origin', 'release'));
      for (final piece in (record['engine'] as Map).values) {
        expect(piece, containsPair('origin', 'release'));
      }
    });
  }
}
