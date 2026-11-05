/// The Chrome DevTools Protocol transport of an integration test's suite, against
/// a fake page connection that records every command and can send the events a
/// page and a browser send.
///
/// The properties are the ones the transport's design rests on: the host
/// speaks first, so the page's binding must exist before anything is sent to
/// it, and a page that is gone is reported with its reason instead of a wait
/// that ends at Bazel's timeout.
library;

import 'dart:async';

import 'package:flutter_bazel_dev_tool/integration/cdp_suite_transport.dart';
import 'package:test/test.dart';

import 'fake_cdp_page.dart';

const _gone = 'Chrome exited with code 139.';

/// Lets everything already queued run, so that "has not happened yet" can be
/// asserted without waiting a fixed time.
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeCdpPage page;
  setUp(() => page = FakeCdpPage());

  Future<CdpSuiteTransport> connect() =>
      CdpSuiteTransport.connect(page, whyLost: () async => _gone);

  Future<CdpSuiteTransport> connected() async {
    page.bridgeInstalled.complete();
    return connect();
  }

  group('connecting', () {
    test('adds the binding before it evaluates anything in the page, since '
        'the host speaks first and the page posts only in answer', () async {
      page.bridgeInstalled.complete();
      await connect();

      final binding = page.commands.singleWhere(
        (c) => c.method == 'Runtime.addBinding',
      );
      expect(binding.params, {'name': cdpBindingName});
      expect(
        page.methods.indexOf('Runtime.addBinding'),
        lessThan(page.methods.indexOf('Runtime.evaluate')),
      );
    });

    test('enables the Runtime domain before it adds the binding, and adds it '
        'before it looks for the bridge: Chrome installs a binding only in '
        'the contexts an enabled domain knows, and reports its calls only to '
        'it', () async {
      page.bridgeInstalled.complete();
      await connect();

      expect(
        page.methods.where((m) => m.startsWith('Runtime.')),
        ['Runtime.enable', 'Runtime.addBinding', 'Runtime.evaluate'],
      );
    });

    test('does not evaluate in a page that has no execution context yet: a '
        'page still loading answers "Cannot find default execution context", '
        'so the host waits for the context to exist', () async {
      page.hasContextAtEnable = false;
      page.bridgeInstalled.complete();
      var connectedYet = false;
      final transport = connect().whenComplete(() => connectedYet = true);

      await _settle();
      expect(page.methods, isNot(contains('Runtime.evaluate')));

      // A context that is not the main frame's (an extension's, a worker's) is
      // not the one the page's bridge is in.
      page.emitDefaultContext(id: 5, isDefault: false);
      await _settle();
      expect(page.methods, isNot(contains('Runtime.evaluate')));
      expect(connectedYet, isFalse);

      page.emitDefaultContext();
      await transport;
      expect(page.methods, contains('Runtime.evaluate'));
    });

    test('asks again in the next context when the one it asked in went away '
        'under the evaluation, as a page does that navigates', () async {
      page.waitFailsOnce = 'Execution context was destroyed.';
      page.bridgeInstalled.complete();
      var connectedYet = false;
      final transport = connect().whenComplete(() => connectedYet = true);

      await _settle();
      expect(connectedYet, isFalse, reason: 'no context to ask in yet');
      expect(
        page.methods.where((m) => m == 'Runtime.evaluate'),
        hasLength(1),
      );

      page.emitContextDestroyed();
      page.emitDefaultContext(id: 2);
      await transport;

      expect(
        page.methods.where((m) => m == 'Runtime.evaluate'),
        hasLength(2),
      );
    });

    test('waits for the page to install its bridge, in the page and on its '
        'event, with no polling and no time spent', () async {
      var connectedYet = false;
      final transport = connect().whenComplete(() => connectedYet = true);

      await _settle();
      expect(connectedYet, isFalse, reason: 'the page has no bridge yet');

      final wait = page.commands.singleWhere(
        (c) => c.method == 'Runtime.evaluate',
      );
      final expression = wait.params['expression'] as String;
      expect(expression, contains(r'globalThis.$rulesFlutterIntegration'));
      expect(expression, contains('rulesflutterintegrationready'));
      expect(wait.params['awaitPromise'], isTrue);

      page.bridgeInstalled.complete();
      expect(await transport, isNotNull);
    });

    test('listens for the page\'s calls before the binding exists, so the '
        'first message cannot fall between the two', () async {
      page.bridgeInstalled.complete();
      final transport = await connect();
      final seen = <String>[];
      final sub = transport.incoming.listen(seen.add);

      page.callBinding(cdpBindingName, '"first"');
      await _settle();
      await sub.cancel();

      expect(seen, ['"first"']);
    });

    test('a page that is gone before it installs its bridge is reported with '
        'the browser\'s account of why', () async {
      final connecting = connect();
      final outcome = expectLater(
        connecting,
        throwsA(
          isA<PageLostBeforeSuite>().having((e) => e.reason, 'reason', _gone),
        ),
      );

      await _settle();
      await page.vanish();
      await outcome;
    });

    test('a page that crashes before it installs its bridge is reported as '
        'crashed', () async {
      final connecting = connect();
      final outcome = expectLater(
        connecting,
        throwsA(
          isA<PageLostBeforeSuite>().having(
            (e) => e.reason,
            'reason',
            contains('crashed'),
          ),
        ),
      );

      await _settle();
      page.emit('Inspector.targetCrashed', {});
      await outcome;
    });
  });

  group('a connected suite', () {
    late CdpSuiteTransport transport;
    setUp(() async => transport = await connected());

    test('carries the host\'s messages to the page\'s bridge, in the order '
        'they were sent', () async {
      for (final message in ['"a"', '"b"', '"c"']) {
        transport.send(message);
      }
      await transport.close();

      expect(page.delivered, ['"a"', '"b"', '"c"']);
    });

    test('hands the bridge each message as exactly the text it was sent as, '
        'whatever characters it holds', () async {
      const awkward = '["x", {"s": "quote \' \\" back\\\\slash\\n  é 日本"}]';
      transport.send(awkward);
      await transport.close();

      expect(page.delivered, [awkward]);
    });

    test('carries the page\'s calls of the binding to the host, and nothing '
        'else the page or the browser says', () async {
      final seen = <String>[];
      final sub = transport.incoming.listen(seen.add);

      page.emit('Runtime.consoleAPICalled', {'type': 'log'});
      page.callBinding('someOtherBinding', '"not ours"');
      page.callBinding(cdpBindingName, '[1,{"type":"x"}]');
      page.callBinding(cdpBindingName, '"second"');
      await _settle();
      await sub.cancel();

      expect(seen, ['[1,{"type":"x"}]', '"second"']);
    });

    test('reports a crashed page, with the crash as the reason', () async {
      final lost = transport.lostReason;

      page.emit('Inspector.targetCrashed', {});

      expect(await lost, contains('crashed'));
    });

    test('reports a page the browser detached, with the browser\'s '
        'reason', () async {
      final lost = transport.lostReason;

      page.emit('Inspector.detached', {'reason': 'target_closed'});

      expect(
        await lost,
        allOf(contains('detached'), contains('target_closed')),
      );
    });

    test('reports the browser closing the connection, in the device\'s '
        'words', () async {
      final lost = transport.lostReason;

      await page.vanish();

      expect(await lost, _gone);
    });

    test('and says so when the device cannot say why', () async {
      page = FakeCdpPage();
      final unknown = await (() async {
        page.bridgeInstalled.complete();
        return CdpSuiteTransport.connect(page, whyLost: () async => null);
      })();

      await page.vanish();

      expect(
        await unknown.lostReason,
        allOf(contains('connection'), contains('could not say why')),
      );
    });

    test('reports a page whose bridge throws on a message, which nothing '
        'after it can recover from', () async {
      page.bridgeThrows = 'TypeError: send is not a function';

      transport.send('"x"');

      expect(
        await transport.lostReason,
        allOf(contains('refused a message'), contains('TypeError')),
      );
    });

    test('a polite close is not the page being lost', () async {
      var lost = false;
      unawaited(transport.lostReason.then((_) => lost = true));

      await transport.close();
      await _settle();

      expect(lost, isFalse);
    });

    test('abandoning a wedged page closes the connection without waiting '
        'for the page to answer', () async {
      var lost = false;
      unawaited(transport.lostReason.then((_) => lost = true));

      await transport.abandon('did not finish');
      await _settle();

      expect(page.isClosed, isTrue);
      expect(lost, isFalse, reason: 'the driver already knows why');
    });
  });
}
