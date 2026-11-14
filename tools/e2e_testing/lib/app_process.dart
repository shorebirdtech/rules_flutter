/// A launched app whose output a test reads.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A running app binary, started directly rather than through `open`.
///
/// Starting `Contents/MacOS/<exe>` means the test owns the process and can
/// address it by [pid], never by the bundle's name: LaunchServices activates
/// an already-running instance of the same bundle id instead of starting a
/// new one, so a leftover instance could answer for the build under test.
///
/// Both output streams are drained for the life of the process, since an
/// undrained pipe can block the app on a write, and kept for the failure
/// report.
class AppProcess {
  AppProcess._(this._process, {required bool mirror}) {
    final done = <Future<void>>[];
    for (final (stream, mirrorTo) in [
      (_process.stdout, stdout),
      (_process.stderr, stderr),
    ]) {
      done.add(
        stream.transform(utf8.decoder).transform(const LineSplitter()).listen((
          line,
        ) {
          _output.writeln(line);
          if (mirror) mirrorTo.writeln(line);
          _lines.add(line);
          _lineAdded.add(null);
        }).asFuture<void>(),
      );
    }
    _streamsClosed = Future.wait(done);
    unawaited(_process.exitCode.then((code) => _exitCode = code));
  }

  /// Starts [executable] with [environment] added to the test's own, and
  /// copies its output to the test log if [mirror].
  ///
  /// Throws a [FileSystemException] if there is no such binary.
  static Future<AppProcess> start(
    String executable, {
    Map<String, String> environment = const {},
    bool mirror = false,
  }) async {
    if (!File(executable).existsSync()) {
      throw FileSystemException('runner binary not found', executable);
    }
    stdout.writeln('Launching $executable ...');
    final process = await Process.start(
      executable,
      const [],
      environment: {...Platform.environment, ...environment},
    );
    stdout.writeln('PID: ${process.pid}');
    return AppProcess._(process, mirror: mirror);
  }

  final Process _process;
  final StringBuffer _output = StringBuffer();
  final List<String> _lines = [];
  final StreamController<void> _lineAdded = StreamController.broadcast();
  late final Future<void> _streamsClosed;

  /// The process id.
  int get pid => _process.pid;

  int? _exitCode;

  /// The exit code, or null while the app is running.
  int? get exitCode => _exitCode;

  /// Whether the app has exited.
  bool get exited => _exitCode != null;

  /// Everything the app has printed to stdout and stderr, a line each.
  String get output => _output.toString();

  /// Completes with the exit code when the app exits.
  Future<int> get whenExited => _process.exitCode;

  /// The first line the app printed that contains [pattern], waiting up to
  /// [timeout] for it. Null if the time runs out or the app exits without
  /// printing one.
  ///
  /// A line printed before the call counts, so a test can wait for one after
  /// the app has already moved on.
  Future<String?> waitForLine(
    Pattern pattern, {
    required Duration timeout,
  }) async {
    String? find() {
      for (final line in _lines) {
        if (line.contains(pattern)) return line;
      }
      return null;
    }

    final found = Completer<String?>();
    void look() {
      final line = find();
      if (line != null && !found.isCompleted) found.complete(line);
    }

    final subscription = _lineAdded.stream.listen((_) => look());
    unawaited(
      _streamsClosed.then((_) {
        look();
        if (!found.isCompleted) found.complete(null);
      }),
    );
    look();
    try {
      return await found.future.timeout(timeout, onTimeout: () => null);
    } finally {
      await subscription.cancel();
    }
  }

  /// Writes the app's output to stderr under a heading, for a failure report.
  void dumpOutput() {
    stderr
      ..writeln('--- app output ---')
      ..write(output);
  }

  /// Ends the app: asks it to quit, and kills it if it has not by [grace].
  Future<void> stop({Duration grace = const Duration(seconds: 2)}) async {
    if (exited) return;
    _process.kill();
    final quit = await _process.exitCode
        .then<bool>((_) => true)
        .timeout(grace, onTimeout: () => false);
    if (!quit) {
      _process.kill(ProcessSignal.sigkill);
      await _process.exitCode;
    }
  }
}
