/// The phases of a long command, said in the log as they happen.
///
/// A reload that is stuck and a reload that is slow look the same from outside
/// unless each phase says when it ends, and says so while it is still going. A
/// phase line carries the phase name and how long it took; a phase that has
/// run longer than [PhaseLog.stillRunningAfter] says it is still running, every
/// interval, until it ends. The last line in the log then names the phase a
/// stuck command is in.
///
/// Observation only: [PhaseLog.run] returns the very future the body returned,
/// so wrapping a step in it adds no wait to the path it sits on.
library;

import 'dart:async';

import 'logging.dart';

final _logger = Logger('dev_tool.reload_phase');

/// A duration in the unit a person reads: `340ms`, `1.2s`, `2m 05s`.
String formatElapsed(Duration d) {
  if (d.inMilliseconds < 1000) return '${d.inMilliseconds}ms';
  if (d.inSeconds < 60) {
    return '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
  }
  final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '${d.inMinutes}m ${seconds}s';
}

/// Say one phase line.
///
/// [event] is `finished`, `failed`, `running` (still going) or `waiting`.
/// The sentence is the human log; the fields are what `LOG_FORMAT=json` and a
/// test read.
void logPhase({
  required String verb,
  required String phase,
  required String event,
  required String text,
  Duration? took,
  Logger? logger,
}) {
  (logger ?? _logger).info({
    'message': 'reload_phase',
    'text': text,
    'verb': verb,
    'phase': phase,
    'event': event,
    if (took != null) 'ms': took.inMilliseconds,
  });
}

class PhaseLog {
  /// What the command is called in its lines: `Hot reload`, `Restart`.
  final String verb;

  /// How long a phase runs before it says it is still running, and how often it
  /// says so after that.
  final Duration stillRunningAfter;

  final Logger? _logger;

  /// Also told every line, for a `--machine` client that reads `app.progress`
  /// and not the tool's stderr. `finished` is true on the last line only.
  final void Function(String text, {required bool finished})? _mirror;

  final Stopwatch _total = Stopwatch()..start();

  PhaseLog(
    this.verb, {
    this.stillRunningAfter = const Duration(seconds: 5),
    void Function(String text, {required bool finished})? mirror,
    Logger? logger,
  }) : _mirror = mirror,
       _logger = logger;

  void _say(
    String phase,
    String event,
    String text, {
    required Duration took,
    bool finished = false,
  }) {
    logPhase(
      verb: verb,
      phase: phase,
      event: event,
      text: text,
      took: took,
      logger: _logger,
    );
    _mirror?.call(text, finished: finished);
  }

  /// Run [body] as the phase [phase], saying how it ended and how long it took.
  ///
  /// Returns the future [body] returned, untouched: the lines are written from
  /// a listener on it, which runs before the caller's own continuation.
  Future<T> run<T>(String phase, Future<T> Function() body) {
    final clock = Stopwatch()..start();
    final Future<T> future;
    try {
      future = body();
    } catch (e) {
      _failed(phase, clock, e);
      rethrow;
    }
    final ticker = Timer.periodic(stillRunningAfter, (_) {
      _say(
        phase,
        'running',
        '$verb: $phase still running after ${formatElapsed(clock.elapsed)}',
        took: clock.elapsed,
      );
    });
    future
        .then<void>(
          (_) {
            ticker.cancel();
            _say(
              phase,
              'finished',
              '$verb: $phase finished in ${formatElapsed(clock.elapsed)}',
              took: clock.elapsed,
            );
          },
          onError: (Object e, StackTrace _) {
            ticker.cancel();
            _failed(phase, clock, e);
          },
        )
        .ignore();
    return future;
  }

  void _failed(String phase, Stopwatch clock, Object error) {
    _say(
      phase,
      'failed',
      '$verb: $phase failed after ${formatElapsed(clock.elapsed)}: $error',
      took: clock.elapsed,
    );
  }

  /// The command's last line: how long it took altogether. Its absence from the
  /// log is what a command that never ended looks like.
  void finish() {
    _total.stop();
    _say(
      'total',
      'finished',
      '$verb finished in ${formatElapsed(_total.elapsed)}',
      took: _total.elapsed,
      finished: true,
    );
  }
}
