/// The host's side of a golden: compares or writes the picture an app sent.
///
/// The comparison needs `dart:ui`, which this program has not, so it is made by
/// a `flutter_tester` the host starts for the purpose (`flutter/private/goldens/service.dart`,
/// built as a `flutter_test`), as `flutter test` starts one for the tool. It is
/// started when the first golden is asked for, and ended with the run, so a
/// test that compares none pays nothing.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'golden_requests.dart';

/// Compares or writes one golden at a time.
abstract interface class GoldenComparator {
  /// Compares [bytes], the picture the app made, with the golden file [key].
  Future<GoldenAnswer> compare(String key, Uint8List bytes);

  /// Writes [bytes] as the golden file [key].
  Future<GoldenAnswer> update(String key, Uint8List bytes);

  /// Ends the comparator: nothing more is asked of it.
  Future<void> close();
}

/// Answers every golden by saying there is nothing to compare with: what a test
/// that was not given a golden comparator gets.
class NoGoldenComparator implements GoldenComparator {
  /// A comparator that has none, [why].
  const NoGoldenComparator(this.why);

  /// What is missing, in words that name the remedy.
  final String why;

  @override
  Future<GoldenAnswer> compare(String key, Uint8List bytes) async =>
      GoldenAnswer.failed('Golden "$key" cannot be compared: $why');

  @override
  Future<GoldenAnswer> update(String key, Uint8List bytes) =>
      compare(key, bytes);

  @override
  Future<void> close() async {}
}

/// Takes what the app asks of the host about its goldens and answers it with
/// [comparator].
///
/// In update mode every request writes the picture: the app is not told to
/// update, as `autoUpdateGoldenFiles` is a switch of the app's own process
/// that an app on a device cannot be handed, and `flutter test`'s web platform
/// makes the same choice on the host (`_goldenFileHandler`). The golden files it
/// writes are named to [log].
class GoldenHost {
  /// Answers the requests of [channel] with [comparator], writing goldens when
  /// [update].
  GoldenHost(
    GoldenRequests channel,
    this._comparator, {
    required this.update,
    void Function(String message)? log,
  }) : _channel = channel,
       _log = log {
    // One at a time, in the order asked: the app's `expect` awaits each.
    _serving = channel.goldenRequests.asyncMap(_serve).drain<void>();
  }

  final GoldenRequests _channel;
  final GoldenComparator _comparator;
  final void Function(String message)? _log;

  /// Whether goldens are written instead of compared.
  final bool update;

  late final Future<void> _serving;

  Future<void> _serve(GoldenRequest request) async {
    GoldenAnswer answer;
    try {
      answer = update || request.operation == GoldenOperation.update
          ? await _comparator.update(request.key, request.bytes)
          : await _comparator.compare(request.key, request.bytes);
    } on Object catch (e) {
      answer = GoldenAnswer.failed(
        'Golden "${request.key}" could not be '
        '${update || request.operation == GoldenOperation.update ? 'written' : 'compared'}: $e',
      );
    }
    // Named because a golden that is written reports as a passing test, and
    // which files it rewrote is what a person needs before committing them.
    final wrote = answer.wrote;
    if (wrote != null) _log?.call('wrote golden $wrote');
    try {
      await _channel.answerGolden(request.id, answer);
    } on Object {
      // The app is gone: the run's own end says why, and there is nobody to
      // tell.
    }
  }

  /// Ends the comparator once the requests the app has made are answered.
  Future<void> close() async {
    await _serving;
    await _comparator.close();
  }
}

/// A started golden service: what the host needs to know of its process.
abstract interface class RunningGoldenService {
  /// How the process ended.
  Future<int> get exitCode;

  /// What it prints, line by line, in order; done once it has printed all.
  Stream<String> get output;

  /// Ends the process.
  void kill();
}

/// Starts the golden service with [environment].
typedef GoldenServiceLauncher = Future<RunningGoldenService> Function(
  Map<String, String> environment,
);

/// The variable the service is told the host's port in.
const goldenServicePortVariable = 'RULES_FLUTTER_GOLDEN_SERVICE_PORT';

/// The variable the service is told the test's source in.
const goldenServiceTestPathVariable = 'FLUTTER_TEST_PATH';

/// How long a service gets to end once its connection is closed.
const _exitBound = Duration(seconds: 30);

/// How many of the service's last lines say why it died.
const _outputTail = 40;

/// A [GoldenComparator] that is a golden service, started on the first request.
class GoldenServiceComparator implements GoldenComparator {
  /// A comparator served by what [launch] starts, within [ceiling] of being
  /// asked, for the test whose source has the `short_path` [testPath]. Each
  /// line the service prints is given to [log] as it is printed.
  GoldenServiceComparator({
    required GoldenServiceLauncher launch,
    required this.testPath,
    required this.ceiling,
    this.environment = const {},
    void Function(String line)? log,
  }) : _launch = launch,
       _log = log;

  final GoldenServiceLauncher _launch;
  final void Function(String line)? _log;

  /// The `short_path` of the test's source, which goldens are relative to the
  /// directory of.
  final String testPath;

  /// The bound on the service connecting, which has no other end than the
  /// service starting or ending.
  final Duration ceiling;

  /// What the service is started with besides what this says.
  final Map<String, String> environment;

  Future<_Connection>? _connection;
  var _closed = false;

  /// The requests in flight, one after another.
  Future<void> _asking = Future.value();
  var _nextId = 0;

  @override
  Future<GoldenAnswer> compare(String key, Uint8List bytes) =>
      _ask('compare', key, bytes);

  @override
  Future<GoldenAnswer> update(String key, Uint8List bytes) =>
      _ask('update', key, bytes);

  Future<GoldenAnswer> _ask(String operation, String key, Uint8List bytes) {
    final answer = _asking.then((_) async {
      if (_closed) {
        throw StateError('the golden comparator is closed');
      }
      final connection = await (_connection ??= _connect());
      return connection.ask({
        'id': ++_nextId,
        'op': operation,
        'key': key,
        'bytes': base64.encode(bytes),
      });
    });
    _asking = answer.then<void>((_) {}, onError: (Object _) {});
    return answer;
  }

  Future<_Connection> _connect() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _Service? service;
    try {
      service = _Service(
        await _launch({
          ...environment,
          goldenServicePortVariable: '${server.port}',
          goldenServiceTestPathVariable: testPath,
        }),
        _log,
      );
      final running = service;
      final ended = running.exitCode.then<Socket?>((_) => null);
      final Socket? socket = await Future.any([
        server.first,
        ended,
      ]).timeout(ceiling, onTimeout: () => throw _noConnection(running));
      if (socket == null) {
        throw StateError(
          'the golden comparator ended before it connected: '
          '${await _because(running)}',
        );
      }
      return _Connection(socket, running);
    } on Object {
      service?.kill();
      rethrow;
    } finally {
      await server.close();
    }
  }

  StateError _noConnection(_Service service) {
    service.kill();
    return StateError(
      'the golden comparator did not connect within ${ceiling.inSeconds}s: '
      '${_tail(service)}',
    );
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _asking;
    final connection = _connection;
    if (connection == null) return;
    try {
      await (await connection).close();
    } on Object {
      // It never connected: the request that wanted it has said why.
    }
  }
}

/// A started service whose output is logged as it comes, and whose last lines
/// are kept for the message that says why it died.
class _Service {
  _Service(this._running, void Function(String line)? log) {
    _printed = _running.output.listen((line) {
      log?.call(line);
      _last.add(line);
      if (_last.length > _outputTail) _last.removeFirst();
    }).asFuture<void>();
  }

  final RunningGoldenService _running;
  final _last = Queue<String>();
  late final Future<void> _printed;

  /// How the process ended, once all it printed has been read.
  Future<int> get exitCode async {
    final code = await _running.exitCode;
    await _printed;
    return code;
  }

  void kill() => _running.kill();
}

/// Why a service that is not answering is not: how it ended and what it said.
Future<String> _because(_Service service) async {
  final code = await service.exitCode;
  return 'it exited with code $code. ${_tail(service)}';
}

String _tail(_Service service) {
  if (service._last.isEmpty) return 'It printed nothing.';
  return 'Its output:\n${service._last.join('\n')}';
}

/// The connection to a started service, which answers one request at a time.
class _Connection {
  _Connection(this._socket, this._service) {
    _lines = _socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onDone: _onDone);
  }

  final Socket _socket;
  final _Service _service;
  late final StreamSubscription<String> _lines;
  var _closing = false;
  Completer<Map<String, Object?>>? _waiting;
  Object? _ended;

  void _onLine(String line) {
    final waiting = _waiting;
    _waiting = null;
    waiting?.complete(json.decode(line) as Map<String, Object?>);
  }

  Future<void> _onDone() async {
    if (_closing) return;
    final waiting = _waiting;
    final why = StateError(
      'the golden comparator went away: ${await _because(_service)}',
    );
    _ended = why;
    _waiting = null;
    waiting?.completeError(why);
  }

  Future<GoldenAnswer> ask(Map<String, Object?> request) async {
    final ended = _ended;
    if (ended != null) throw ended;
    final waiting = _waiting = Completer<Map<String, Object?>>();
    _socket.writeln(json.encode(request));
    final response = await waiting.future;
    if (response['id'] != request['id']) {
      throw StateError(
        'the golden comparator answered request ${response['id']}, not '
        '${request['id']}',
      );
    }
    final error = response['error'];
    if (error is String) return GoldenAnswer.failed(error);
    final matched = response['matched'];
    if (matched is! bool) {
      throw StateError(
        'the golden comparator answered with neither "matched" nor "error": '
        '${json.encode(response)}',
      );
    }
    final wrote = response['wrote'];
    return GoldenAnswer.matched(matched, wrote: wrote is String ? wrote : null);
  }

  /// Ends the connection, which ends the service, and waits for it to.
  Future<void> close() async {
    _closing = true;
    await _lines.cancel();
    await _socket.close();
    _socket.destroy();
    // The service ends as its connection does; one that does not is ended, as
    // `flutter_test`'s runner ends a tester that outlives its suite.
    await _service.exitCode.timeout(
      _exitBound,
      onTimeout: () {
        _service.kill();
        return -1;
      },
    );
  }
}
