/// [SourceWatcher] over the platform's own file watcher: an edit to a Dart
/// source on disk arrives as a [SourceChange] naming it.
///
/// Everything downstream of the watcher is covered with a fake watcher, in
/// `source_watcher_test.dart` and `run_command_lifecycle_test.dart`. This is
/// the one place the real one is used, and it is in the `deep` tier because
/// its verdict rests on the OS: macOS FSEvents delivers nothing for a minute
/// or more, to any client, while other processes write heavily, and some of
/// the events it holds back then never arrive. A full `bazel test //...` is
/// such a load.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/hot_reload/source_watcher.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('an edit to a Dart source on disk arrives as a change', () async {
    final tmp = await Directory.systemTemp.createTemp('source_watcher_fs_');
    final lib = Directory(p.join(tmp.path, 'lib'))..createSync();
    final main = File(p.join(lib.path, 'main.dart'))..writeAsStringSync('v1');
    final primer = File(p.join(lib.path, 'primer.dart'));

    final watcher = SourceWatcher(
      root: tmp.path,
      debounce: const Duration(milliseconds: 50),
    );
    try {
      await watcher.start();

      final primed = Completer<void>();
      final edited = Completer<SourceChange>();
      final sub = watcher.changes.listen((change) {
        if (change.paths.any((path) => path.endsWith('primer.dart'))) {
          if (!primed.isCompleted) primed.complete();
        }
        if (change.paths.any((path) => path.endsWith('main.dart'))) {
          if (!edited.isCompleted) edited.complete(change);
        }
      });

      // `ready` does not mean events are being delivered: on macOS,
      // package:watcher completes it a fixed 200ms after starting the native
      // watch, and a write made just after can be lost. So prove the stream
      // live first, rewriting a primer until a change for it arrives. Each
      // write is a fresh event, so this waits on delivery, not on a guess at
      // how long setup takes.
      for (var n = 0; !primed.isCompleted; n++) {
        primer.writeAsStringSync('// $n');
        await Future.any([
          primed.future,
          Future<void>.delayed(const Duration(milliseconds: 500)),
        ]);
      }

      main.writeAsStringSync('v2 longer');
      final change = await edited.future;
      await sub.cancel();

      expect(change.paths, contains(endsWith(p.join('lib', 'main.dart'))));
    } finally {
      await watcher.stop();
      await tmp.delete(recursive: true);
    }
  });
}
