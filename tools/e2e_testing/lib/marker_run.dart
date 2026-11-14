/// Launching a built app and waiting for it to report that it ran.
library;

import 'dart:io';

/// Launches [binary] with [environment] added to the process's own, waits up
/// to [timeout] for the app to write [markerFile], and throws a [StateError]
/// unless the file holds exactly [expected].
///
/// The app writes the marker from `main()`; the test points its temp
/// directory at the marker's directory. [forwardOutput] copies the app's
/// stdout and stderr to the test log, to surface loader errors.
///
/// Returns, or throws, only once the app has exited, so the caller may delete
/// the marker's directory: on Windows a directory a running program holds a
/// file or its working directory in cannot be deleted.
Future<void> runUntilMarker({
  required String binary,
  required File markerFile,
  required String expected,
  required Duration timeout,
  Map<String, String> environment = const {},
  bool forwardOutput = false,
}) async {
  Process? app;
  try {
    stdout.writeln('Launching $binary ...');
    app = await Process.start(
      binary,
      const [],
      environment: {...Platform.environment, ...environment},
    );
    if (forwardOutput) {
      app.stdout.listen(stdout.add);
      app.stderr.listen(stderr.add);
    }

    stdout.writeln(
      'Waiting up to ${timeout.inSeconds}s for ${markerFile.path} ...',
    );
    final deadline = DateTime.now().add(timeout);
    String? contents;
    while (DateTime.now().isBefore(deadline)) {
      if (markerFile.existsSync()) {
        contents = markerFile.readAsStringSync().trim();
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    if (contents == null) {
      throw StateError(
        'app never wrote ${markerFile.path} — it likely crashed before '
        'main() completed (native library failed to load?).',
      );
    }
    stdout.writeln('App recorded: "$contents"');
    if (contents != expected) {
      throw StateError('expected "$expected" but got "$contents".');
    }
  } finally {
    if (app != null) {
      app.kill();
      await app.exitCode;
    }
  }
}
