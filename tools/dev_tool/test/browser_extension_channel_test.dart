import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_bazel_dev_tool/app_extension_channel.dart';
import 'package:flutter_bazel_dev_tool/agent_command.dart';
import 'package:flutter_bazel_dev_tool/browser_extension_channel.dart';
import 'package:flutter_bazel_dev_tool/command_failure.dart';
import 'package:flutter_bazel_dev_tool/command_runner.dart';
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/machine_protocol.dart';
import 'package:flutter_bazel_dev_tool/session.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

import 'fakes.dart';

/// A page's CDP connection that answers `Runtime.evaluate` from [onEvaluate],
/// which sees the expression text.
class _FakePage implements CdpSender {
  _FakePage(this.onEvaluate);

  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();

  final Future<Object?> Function(String expression) onEvaluate;
  final expressions = <String>[];
  final evaluateParams = <Map<String, dynamic>>[];
  var _closed = false;

  @override
  bool get isClosed => _closed;

  void drop() => _closed = true;

  @override
  Future<void> close() async => _closed = true;

  @override
  Future<Map<String, dynamic>> send(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    expect(method, 'Runtime.evaluate');
    if (_closed) throw StateError('the page\'s CDP connection closed');
    expressions.add(params['expression'] as String);
    evaluateParams.add(params);
    final value = await onEvaluate(params['expression'] as String);
    return {
      'result': {
        'result': {'type': 'string', 'value': value},
      },
    };
  }
}

String _result(Map<String, dynamic> result) => jsonEncode({'result': result});

/// A channel whose connections are [pages], in order; `connects` counts dials.
({BrowserExtensionChannel channel, List<int> connects}) _channelOver(
  List<_FakePage> pages, {
  Duration bridgeTimeout = const Duration(seconds: 30),
}) {
  final connects = <int>[];
  final channel = BrowserExtensionChannel(
    connect: () async {
      connects.add(connects.length);
      return pages[connects.length - 1];
    },
    bridgeTimeout: bridgeTimeout,
  );
  return (channel: channel, connects: connects);
}

void main() {
  group('the agent commands over a browser session', () {
    DeviceSession sessionOver(_FakePage page) {
      final device = WebDevice()
        ..browserChannel = BrowserExtensionChannel(connect: () async => page);
      return DeviceSession(
        device: device,
        appInstance: AppInstance(process: FakeProcess()),
        vmClient: null,
        appId: 'app',
      )..drivable.signalReady();
    }

    test('app.getText is answered with no VM service', () async {
      final page = _FakePage(
        (e) async => e.contains('agent.call(')
            ? _result({
                'text': 'hello',
                'type': '_extensionType',
                'method': 'x',
              })
            : true,
      );
      final session = sessionOver(page);
      final cr = CommandRunner();
      setUpAgentCommands(cr, (_) => session);

      expect(await cr.run('app.getText', {'appId': 'app', 'key': 'k'}), {
        'text': 'hello',
      });
      expect(
        page.expressions.any((e) => e.contains('agent.bindingReady()')),
        isTrue,
      );
    });

    test('an app refusal is a refusal carrying the app\'s text', () async {
      final page = _FakePage(
        (e) async => e.contains('agent.call(')
            ? jsonEncode({
                'error': {'code': -32602, 'detail': 'no widget matching k'},
              })
            : true,
      );
      final session = sessionOver(page);
      final cr = CommandRunner();
      setUpAgentCommands(cr, (_) => session);

      await expectLater(
        cr.run('app.tap', {'appId': 'app', 'key': 'k'}),
        throwsA(
          isA<CommandFailure>().having(
            (e) => e.message,
            'message',
            'no widget matching k',
          ),
        ),
      );
    });

    test('a page that never installs the bridge is refused saying so', () {
      fakeAsync((async) {
        final page = _FakePage((e) => Completer<Object?>().future);
        final session = sessionOver(page);
        final cr = CommandRunner();
        setUpAgentCommands(cr, (_) => session);
        Object? error;
        cr
            .run('app.getText', {'appId': 'app', 'key': 'k'})
            .then<void>((_) {}, onError: (Object e) => error = e);

        async.elapse(const Duration(seconds: 31));

        expect(
          error,
          isA<CommandFailure>().having(
            (e) => e.message,
            'message',
            contains('never installed the rules_flutter agent bridge'),
          ),
        );
      });
    });

    test('the drivable gate settles on the first frame', () async {
      final page = _FakePage((e) async => true);
      final device = WebDevice()
        ..browserChannel = BrowserExtensionChannel(connect: () async => page);
      final session = DeviceSession(
        device: device,
        appInstance: AppInstance(process: FakeProcess()),
        vmClient: null,
        appId: 'app',
      );

      await session.waitUntilDrivable(MachineProtocol(enabled: false));

      expect(session.drivable.isReady, isTrue);
    });
  });
  group('callServiceExtension', () {
    test('returns the extension\'s result object', () async {
      final page = _FakePage(
        (e) async => e.contains('agent.call(')
            ? _result({'text': 'hello', 'type': '_extensionType'})
            : true,
      );
      final c = _channelOver([page]).channel;

      final got = await c.callServiceExtension(
        'ext.rules_flutter.getText',
        args: {'key': 'greeting'},
      );

      expect(got, {'text': 'hello', 'type': '_extensionType'});
    });

    test(
      'passes method and params as JSON literals, after the bridge',
      () async {
        final page = _FakePage((e) async => _result({}));
        final c = _channelOver([page]).channel;

        await c.callServiceExtension(
          'ext.rules_flutter.enterText',
          args: {'text': 'say "hi"\n  \$x'},
        );

        final expression = page.expressions.last;
        // Waits on the event, not a poll, and only if the bridge is absent.
        expect(expression, contains(r'globalThis.$rulesFlutterAgent'));
        expect(expression, contains('rulesflutteragentready'));
        expect(expression, contains('{once: true}'));
        expect(
          expression,
          contains(
            'agent.call("ext.rules_flutter.enterText", '
            '${jsonEncode(jsonEncode({'text': 'say "hi"\n  \$x'}))})',
          ),
        );
        expect(page.evaluateParams.last['awaitPromise'], isTrue);
        expect(page.evaluateParams.last['returnByValue'], isTrue);
      },
    );

    test(
      'an app error is an RPCError whose details are the app\'s text',
      () async {
        final page = _FakePage(
          (e) async => e.contains('agent.call(')
              ? jsonEncode({
                  'error': {'code': -32602, 'detail': 'no widget matching key'},
                })
              : true,
        );
        final c = _channelOver([page]).channel;

        await expectLater(
          c.callServiceExtension('ext.rules_flutter.tap'),
          throwsA(
            isA<RPCError>()
                .having((e) => e.details, 'details', 'no widget matching key')
                .having((e) => e.code, 'code', -32602),
          ),
        );
      },
    );

    test('an unregistered method is method-not-found', () async {
      final page = _FakePage(
        (e) async => e.contains('agent.call(')
            ? jsonEncode({'unregistered': true})
            : true,
      );
      final c = _channelOver([page]).channel;

      await expectLater(
        c.callServiceExtension('ext.rules_flutter.nope'),
        throwsA(
          isA<RPCError>().having((e) => e.code, 'code', -32601),
        ),
      );
    });

    test('an exception in the page is a channel failure naming it', () async {
      final page = _FakePage((e) async => true);
      final c = BrowserExtensionChannel(
        connect: () async => _ThrowingPage(),
      );
      await expectLater(
        c.callServiceExtension('ext.rules_flutter.tap'),
        throwsA(
          isA<AppChannelException>().having(
            (e) => e.message,
            'message',
            contains('ReferenceError: agent is not defined'),
          ),
        ),
      );
      expect(page.expressions, isEmpty);
    });
  });

  group('a page with no document yet', () {
    test('is waited for, on its context, and then evaluated in', () async {
      final page = _LoadingPage();
      final channel = BrowserExtensionChannel(connect: () async => page);
      expect(
        await channel.waitForServiceExtension('ext.rules_flutter.tap'),
        isTrue,
      );
      expect(page.methods, [
        'Runtime.evaluate',
        'Runtime.disable',
        'Runtime.enable',
        'Runtime.disable',
        'Runtime.evaluate',
        'Runtime.evaluate',
      ]);
    });
  });

  group('a page that navigates', () {
    test('is retried once on the new document', () async {
      var calls = 0;
      final page = _FakePage((e) async {
        if (!e.contains('agent.call(')) return true;
        if (calls++ == 0) {
          throw StateError(
            'CDP Runtime.evaluate failed: {code: -32000, message: '
            'Inspected target navigated or closed}',
          );
        }
        return _result({'ok': true});
      });
      final c = _channelOver([page]).channel;

      expect(await c.callServiceExtension('ext.rules_flutter.tap'), {
        'ok': true,
      });
      expect(calls, 2);
    });

    test('is retried only once', () async {
      var calls = 0;
      final page = _FakePage((e) async {
        if (!e.contains('agent.call(')) return true;
        calls++;
        throw StateError(
          'CDP Runtime.evaluate failed: {message: Execution context was '
          'destroyed.}',
        );
      });
      final c = _channelOver([page]).channel;

      await expectLater(
        c.callServiceExtension('ext.rules_flutter.tap'),
        throwsA(isA<AppChannelException>()),
      );
      expect(calls, 2);
    });
  });

  group('the connection', () {
    test('is kept for the session', () async {
      final page = _FakePage((e) async => _result({}));
      final (:channel, :connects) = _channelOver([page]);

      await channel.callServiceExtension('ext.rules_flutter.tap');
      await channel.callServiceExtension('ext.rules_flutter.tap');

      expect(connects, hasLength(1));
    });

    test('is dialled again after it drops', () async {
      final first = _FakePage((e) async => _result({'from': 1}));
      final second = _FakePage((e) async => _result({'from': 2}));
      final (:channel, :connects) = _channelOver([first, second]);

      expect(
        await channel.callServiceExtension('ext.rules_flutter.tap'),
        {'from': 1},
      );
      first.drop();
      expect(
        await channel.callServiceExtension('ext.rules_flutter.tap'),
        {'from': 2},
      );
      expect(connects, hasLength(2));
    });

    test('that drops mid-call is replaced and the call retried', () async {
      late _FakePage first;
      first = _FakePage((e) async {
        if (!e.contains('agent.call(')) return true;
        first.drop();
        throw StateError('the page\'s CDP connection closed');
      });
      final second = _FakePage((e) async => _result({'from': 2}));
      final (:channel, :connects) = _channelOver([first, second]);

      expect(
        await channel.callServiceExtension('ext.rules_flutter.tap'),
        {'from': 2},
      );
      expect(connects, hasLength(2));
    });

    test('that cannot be made is a channel failure', () async {
      final c = BrowserExtensionChannel(
        connect: () async => throw StateError('No debuggable CDP page target'),
      );
      await expectLater(
        c.callServiceExtension('ext.rules_flutter.tap'),
        throwsA(
          isA<AppChannelException>().having(
            (e) => e.message,
            'message',
            contains('No debuggable CDP page target'),
          ),
        ),
      );
    });
  });

  group('a bridge that is never installed', () {
    test('ends with a message saying so', () {
      fakeAsync((async) {
        final page = _FakePage((e) => Completer<Object?>().future);
        final c = _channelOver([
          page,
        ], bridgeTimeout: const Duration(seconds: 5)).channel;
        Object? error;
        c
            .waitForServiceExtension('ext.rules_flutter.tap')
            .then<void>((_) {}, onError: (Object e) => error = e);

        async.elapse(const Duration(seconds: 4));
        expect(error, isNull);
        async.elapse(const Duration(seconds: 2));

        expect(
          error,
          isA<AppChannelException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('never installed the rules_flutter agent bridge'),
              contains('non-debug build'),
            ),
          ),
        );
      });
    });
  });

  group('waits', () {
    test('registered answers the bridge\'s boolean', () async {
      final page = _FakePage(
        (e) async => e.contains('agent.registered("ext.flutter.inspector.x")')
            ? false
            : true,
      );
      final c = _channelOver([page]).channel;

      expect(
        await c.waitForServiceExtension('ext.rules_flutter.tap'),
        isTrue,
      );
      expect(
        await c.waitForServiceExtension('ext.flutter.inspector.x'),
        isFalse,
      );
    });

    test('the binding wait is false when it does not come in time', () {
      fakeAsync((async) {
        final page = _FakePage(
          (e) => e.contains('agent.bindingReady()')
              ? Completer<Object?>().future
              : Future.value(true),
        );
        final c = _channelOver([
          page,
        ], bridgeTimeout: const Duration(seconds: 5)).channel;
        bool? got;
        c.waitForBinding().then((v) => got = v);

        async.elapse(const Duration(seconds: 4));
        expect(got, isNull);
        async.elapse(const Duration(seconds: 2));
        expect(got, isFalse);
      });
    });

    test('the first frame is true when it arrives', () async {
      final page = _FakePage((e) async => true);
      final c = _channelOver([page]).channel;

      expect(
        await c.waitForFirstFrame(timeout: const Duration(seconds: 5)),
        isTrue,
      );
      expect(page.expressions.last, contains('agent.firstFrame()'));
    });

    test('the first frame is false when it does not come in time', () {
      fakeAsync((async) {
        final page = _FakePage(
          (e) => e.contains('agent.firstFrame()')
              ? Completer<Object?>().future
              : Future.value(true),
        );
        final c = _channelOver([page]).channel;
        bool? got;
        c
            .waitForFirstFrame(timeout: const Duration(seconds: 90))
            .then((v) => got = v);

        async.elapse(const Duration(seconds: 89));
        expect(got, isNull);
        async.elapse(const Duration(seconds: 2));
        expect(got, isFalse);
      });
    });

    test('the first frame gives up when the run ends', () {
      fakeAsync((async) {
        final page = _FakePage(
          (e) => e.contains('agent.firstFrame()')
              ? Completer<Object?>().future
              : Future.value(true),
        );
        final c = _channelOver([page]).channel;
        final end = Completer<void>();
        bool? got;
        c
            .waitForFirstFrame(
              timeout: const Duration(minutes: 5),
              until: end.future,
            )
            .then((v) => got = v);

        async.flushMicrotasks();
        expect(got, isNull);
        end.complete();
        async.flushMicrotasks();
        expect(got, isFalse);
      });
    });
  });

  group('without a debugger', () {
    test(
      'never reports a pause, and says what an unanswered page may be',
      () async {
        final c = _channelOver([]).channel;

        expect(await c.pausedReason(), isNull);
        expect(
          await c.unansweredNote(const Duration(seconds: 1)),
          allOf(contains('did not answer'), contains('resume it')),
        );
      },
    );
  });
}

/// A connection whose evaluation reports a page exception.
class _ThrowingPage implements CdpSender {
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}

  @override
  Future<Map<String, dynamic>> send(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 10),
  }) async => {
    'result': {
      'exceptionDetails': {
        'text': 'Uncaught',
        'exception': {'description': 'ReferenceError: agent is not defined'},
      },
    },
  };
}

/// A page with no document until `Runtime.enable` is sent, which reports the
/// new default context as CDP does; evaluations before that fail as Chrome's
/// do between two documents.
class _LoadingPage implements CdpSender {
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final methods = <String>[];
  var _hasDocument = false;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}

  @override
  Future<Map<String, dynamic>> send(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    methods.add(method);
    switch (method) {
      case 'Runtime.enable':
        _hasDocument = true;
        scheduleMicrotask(
          () => _events.add({
            'method': 'Runtime.executionContextCreated',
            'params': {
              'context': {
                'id': 7,
                'auxData': {'isDefault': true},
              },
            },
          }),
        );
        return {'result': {}};
      case 'Runtime.disable':
        return {'result': {}};
      case 'Runtime.evaluate':
        if (!_hasDocument) {
          throw StateError(
            'CDP Runtime.evaluate failed: {code: -32000, message: Cannot '
            'find default execution context}',
          );
        }
        return {
          'result': {
            'result': {'type': 'boolean', 'value': true},
          },
        };
    }
    throw StateError('unexpected $method');
  }
}
