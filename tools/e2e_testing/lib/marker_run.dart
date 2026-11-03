/// Launching a built app and waiting for it to report that it ran.
library;

import 'dart:io';

/// Launches [binary] with [environment] added to the process's own, waits up
/// to [timeout] for the app to write [markerFile], and exits 1 unless the file
/// holds exactly [expected].
///
/// The app writes the marker from `main()`; the test points its temp
/// directory at the marker's directory. [forwardOutput] copies the app's
/// stdout and stderr to the test log, to surface loader errors.
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
      stderr.writeln(
        'FAIL: app never wrote ${markerFile.path} — it likely '
        'crashed before main() completed (native library failed to load?).',
      );
      exit(1);
    }
    stdout.writeln('App recorded: "$contents"');
    if (contents != expected) {
      stderr.writeln('FAIL: expected "$expected" but got "$contents".');
      exit(1);
    }
  } finally {
    app?.kill();
  }
}
