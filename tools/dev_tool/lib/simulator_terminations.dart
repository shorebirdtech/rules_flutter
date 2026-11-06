/// How an app on the iOS Simulator ended, as the simulator itself records it.
///
/// The tool does not start a simulator app's process (`launchd_sim` does), so
/// it never sees the exit status a desktop app's parent reads. The simulator's
/// RunningBoard does: when launchd reports an app's process gone, it logs
///
/// ```
/// [app<com.example.app((null))>:4242] termination reported by launchd (0, 0, 0)
/// ```
///
/// with launchd's reason namespace, reason code and the process's wait status.
/// That one record, logged as the process goes, tells a close from a crash.
/// Seen on an iOS 27.2 simulator:
///
/// | how it ended                          | record                     |
/// |---|---|
/// | closed from the app switcher          | `(0, 0, 0)`, after RunningBoard logs "Setting intended exit status" to FrontBoard's user-quit |
/// | `xcrun simctl terminate`              | `(10, 0xfbfbfbfb, 9)`      |
/// | killed by a signal (a crash, `kill`)  | `(2, <signal>, <signal>)`  |
/// | the app calling `exit(3)`             | wait status 3 << 8         |
///
/// A close from the app switcher lets the app exit by itself; one that does
/// not would be killed under FrontBoard's user-quit code, `(10, 0xdeadfa11,
/// 9)`, which reads as a close too.
///
/// Namespace 10 is FrontBoard's, whose codes 0xdeadfa11 ("User Initiated
/// Quit") and 0xfbfbfbfb ("Force Quit", the explanation reading "Termination
/// requested by simulator host") are its own words for a quit someone asked
/// for. A crash report under `~/Library/Logs/DiagnosticReports` also marks a
/// crash, but it is written many seconds later and never for a close, so its
/// absence could only be read off a clock.
library;

import 'dart:async';

import 'simulator_log_stream.dart';

/// The `log stream` predicate selecting the termination records of the app
/// [bundleId], and nothing else.
String simulatorTerminationPredicate(String bundleId) =>
    'subsystem == "com.apple.runningboard" AND ('
    '(eventMessage BEGINSWITH "[app<$bundleId(" AND '
    'eventMessage CONTAINS "] termination reported by launchd (") OR '
    'eventMessage BEGINSWITH "Setting intended exit status on [app<$bundleId(")';

final _record = RegExp(
  r'^\[app<([^(>]+)\(.*\)>:(\d+)\] termination reported by launchd '
  r'\((\d+), (\d+), (\d+)\)',
);

/// RunningBoard noting, before it asks the app to go, the status the app is
/// to be recorded as ending with. A close from the app switcher lets the app
/// exit by itself, with status 0, and this is what says it was a close.
final _intent = RegExp(
  r'^Setting intended exit status on \[app<[^(>]+\(.*\)>:(\d+)\] to '
  r'<RBSProcessExitStatus\| domain:[^(]*\((\d+)\) code:[^(]*\((0x[0-9a-f]+|\d+)\)',
);

/// FrontBoard's reason namespace in launchd's report.
const _frontBoard = 10;

/// launchd's reason namespace for a process ended by a signal.
const _signalNamespace = 2;

/// FrontBoard's code for a quit the user made from the app switcher.
const _userQuitCode = 0xdeadfa11;

/// FrontBoard's code for a quit the simulator's host asked for, which is what
/// `xcrun simctl terminate` is.
const _hostForceQuit = 0xfbfbfbfb;

const _signalNames = {
  1: 'SIGHUP',
  2: 'SIGINT',
  3: 'SIGQUIT',
  4: 'SIGILL',
  5: 'SIGTRAP',
  6: 'SIGABRT',
  8: 'SIGFPE',
  9: 'SIGKILL',
  10: 'SIGBUS',
  11: 'SIGSEGV',
  12: 'SIGSYS',
  13: 'SIGPIPE',
  15: 'SIGTERM',
};

/// One app process's end, as the simulator's RunningBoard logged it.
class SimulatorTermination {
  const SimulatorTermination({
    required this.bundleId,
    required this.pid,
    required this.namespace,
    required this.code,
    required this.status,
    this.intendedNamespace,
    this.intendedCode,
  });

  final String bundleId;
  final int pid;

  /// launchd's reason namespace: 0 for none, 2 for a signal, 10 FrontBoard's.
  final int namespace;

  /// The reason code within [namespace].
  final int code;

  /// The process's wait status, as `waitpid` gives it.
  final int status;

  /// The namespace and code RunningBoard meant the end to be recorded with,
  /// when it asked the app to go; null when nothing asked.
  final int? intendedNamespace;
  final int? intendedCode;

  SimulatorTermination _intended(({int namespace, int code})? intent) =>
      intent == null
      ? this
      : SimulatorTermination(
          bundleId: bundleId,
          pid: pid,
          namespace: namespace,
          code: code,
          status: status,
          intendedNamespace: intent.namespace,
          intendedCode: intent.code,
        );

  bool get _userQuit =>
      (namespace == _frontBoard && code == _userQuitCode) ||
      (namespace == 0 &&
          status == 0 &&
          intendedNamespace == _frontBoard &&
          intendedCode == _userQuitCode);

  /// The record in one line of `log stream --style ndjson`, or null if the
  /// line is not one.
  static SimulatorTermination? parse(String line) {
    final message = ndjsonEventMessage(line);
    if (message == null) return null;
    final match = _record.firstMatch(message);
    if (match == null) return null;
    return SimulatorTermination(
      bundleId: match.group(1)!,
      pid: int.parse(match.group(2)!),
      namespace: int.parse(match.group(3)!),
      code: int.parse(match.group(4)!),
      status: int.parse(match.group(5)!),
    );
  }

  /// Whether this is a quit someone asked for, or the app ending itself with
  /// code 0, rather than a crash.
  bool get closed {
    if (namespace == _frontBoard) {
      return code == _userQuitCode || code == _hostForceQuit;
    }
    return namespace == 0 && status == 0;
  }

  bool get _signalled => status & 0x7f != 0;

  /// What happened to the process, as a verb phrase: "was closed from the app
  /// switcher", "was killed by signal 11 (SIGSEGV)".
  String get how {
    if (_userQuit) return 'was closed from the app switcher';
    if (namespace == _frontBoard && code == _hostForceQuit) {
      return 'was terminated by the simulator host, as '
          '`xcrun simctl terminate` does';
    }
    final String ended;
    if (_signalled) {
      final signal = status & 0x7f;
      final named = _signalNames[signal];
      ended = 'was killed by signal $signal${named == null ? '' : ' ($named)'}';
    } else {
      ended = 'exited with code ${status >> 8}';
    }
    if (namespace == 0 || namespace == _signalNamespace) return ended;
    return '$ended (launchd reason namespace $namespace, code '
        '0x${code.toRadixString(16)})';
  }
}

/// The termination records of one app, read off a `log stream` of
/// [simulatorTerminationPredicate] as they arrive.
class SimulatorTerminations {
  SimulatorTerminations(Stream<String> lines) {
    _subscription = lines.listen(_onLine);
  }

  late final StreamSubscription<String> _subscription;
  final _byPid = <int, Completer<SimulatorTermination>>{};
  final _intents = <int, ({int namespace, int code})>{};

  /// The record of [pid]'s end, once the simulator logs it.
  Future<SimulatorTermination> of(int pid) =>
      _byPid.putIfAbsent(pid, Completer.new).future;

  void _onLine(String line) {
    final intent = _parseIntent(line);
    if (intent != null) {
      _intents[intent.pid] = (namespace: intent.namespace, code: intent.code);
      return;
    }
    final record = SimulatorTermination.parse(line);
    if (record == null) return;
    final ended = _byPid.putIfAbsent(record.pid, Completer.new);
    if (!ended.isCompleted) {
      ended.complete(record._intended(_intents.remove(record.pid)));
    }
  }

  static ({int pid, int namespace, int code})? _parseIntent(String line) {
    final message = ndjsonEventMessage(line);
    if (message == null) return null;
    final match = _intent.firstMatch(message);
    if (match == null) return null;
    final code = match.group(3)!;
    return (
      pid: int.parse(match.group(1)!),
      namespace: int.parse(match.group(2)!),
      code: code.startsWith('0x')
          ? int.parse(code.substring(2), radix: 16)
          : int.parse(code),
    );
  }

  Future<void> close() => _subscription.cancel();
}
