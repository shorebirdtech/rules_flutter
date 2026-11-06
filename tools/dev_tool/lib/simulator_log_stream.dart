/// A `log stream` on an iOS Simulator, and the moment it is known to be
/// listening.
///
/// `log stream` delivers only what is logged after it attaches to the
/// simulator's log daemon; it replays nothing from before. A launch that
/// starts the app without waiting for that loses whatever the app logs first,
/// and the first thing a debug app logs is the VM-service announcement the
/// whole run waits on: under load the stream has been seen to start 18 ms
/// after the announcement, and the run then waited for good on an app that
/// was up and drawing.
///
/// The stream's banner ("Filtering the log data using ...") is no proof. On
/// an iOS 27.2 simulator under load, with messages logged in a tight loop
/// around each stream's start, the first message delivered and the last one
/// missed fell within tens of milliseconds of the banner, on either side of
/// it: in 9 of 20 starts a message whose logging returned after the banner
/// had been read was missed. Close, but not an ordering `log` promises.
///
/// What is proof is a message the stream delivers. Each stream's predicate
/// also admits one marker message unique to the launch, the marker is logged
/// inside the simulator (`syslog -s`), and once a stream has delivered it the
/// stream was attached before the marker was logged, so it is attached before
/// the app starts and misses nothing the app logs. The marker's record is kept
/// from the stream's readers.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// A message no app logs, for one launch's streams to show they are listening.
String newListeningMarker() {
  final random = Random.secure();
  final id = [
    for (var i = 0; i < 8; i++)
      random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
  return 'flutter_bazel log stream listening $id';
}

/// [predicate], widened to also admit [marker].
String listeningPredicate(String predicate, String marker) =>
    '($predicate) OR eventMessage == "$marker"';

/// The message of one record of `log stream --style ndjson`, or null for any
/// other line (the banner, which quotes the predicate, among them).
String? ndjsonEventMessage(String line) {
  if (!line.startsWith('{')) return null;
  final Object? record;
  try {
    record = json.decode(line);
  } on FormatException {
    return null;
  }
  if (record is! Map) return null;
  final message = record['eventMessage'];
  return message is String ? message : null;
}

/// One `log stream` helper, watched for its marker.
///
/// [process] is the helper as its readers should see it: everything it prints
/// but the marker's message.
class SimulatorLogStream {
  /// Watch [helper]'s output for [marker], reading each line's message with
  /// [messageOf] (the stream's `--style` decides how).
  SimulatorLogStream(
    Process helper, {
    required String marker,
    required String? Function(String line) messageOf,
  }) {
    final out = StreamController<List<int>>();
    late final StreamSubscription<String> lines;
    lines = helper.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (!_started.isCompleted) _started.complete();
            if (messageOf(line) == marker) {
              if (!_listening.isCompleted) _listening.complete();
              return;
            }
            out.add(utf8.encode('$line\n'));
          },
          onDone: out.close,
          onError: out.addError,
        );
    out.onCancel = lines.cancel;
    process = _FilteredProcess(helper, out.stream);
    unawaited(
      helper.exitCode.then((code) {
        final early = StateError(
          'The simulator\'s log stream (pid ${helper.pid}) exited with code '
          '$code before it was listening.',
        );
        if (!_started.isCompleted) _started.completeError(early);
        if (!_listening.isCompleted) _listening.completeError(early);
      }),
    );
    // Read by [waitUntilListening]; an exit nobody waited on is not an error.
    _started.future.ignore();
    _listening.future.ignore();
  }

  /// The helper, as its readers see it.
  late final Process process;

  final _started = Completer<void>();
  final _listening = Completer<void>();

  /// Completes once the helper has printed anything: its banner, which comes
  /// at about the moment it attaches.
  Future<void> get started => _started.future;

  /// Completes once the helper has delivered the marker.
  Future<void> get listening => _listening.future;
}

/// Wait until every one of [streams] is listening, logging the marker with
/// [logMarker] until each has delivered it.
///
/// The marker is first logged once every stream has printed its banner,
/// which is about when it attaches, so one is usually enough. A stream that
/// was not yet attached misses it, and it is logged again, as soon as the
/// last one has been: nothing here waits on a clock. A helper that exits
/// first ends the wait with a [StateError].
Future<void> waitUntilListening(
  List<SimulatorLogStream> streams,
  Future<void> Function() logMarker,
) async {
  final listening = Future.wait([
    for (final s in streams) s.listening,
  ], eagerError: true);
  var settled = false;
  listening.whenComplete(() => settled = true).ignore();
  await Future.any([
    Future.wait([for (final s in streams) s.started], eagerError: true),
    listening,
  ]);
  while (!settled) {
    await Future.any([logMarker(), listening]);
  }
  await listening;
}

/// [_inner] with its stdout replaced.
class _FilteredProcess implements Process {
  _FilteredProcess(this._inner, this.stdout);

  final Process _inner;

  @override
  final Stream<List<int>> stdout;

  @override
  Stream<List<int>> get stderr => _inner.stderr;

  @override
  IOSink get stdin => _inner.stdin;

  @override
  int get pid => _inner.pid;

  @override
  Future<int> get exitCode => _inner.exitCode;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      _inner.kill(signal);
}
