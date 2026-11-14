/// How the host reaches the suite of a launched app, per kind of device: each
/// way it cannot is a failure that names its cause, within the ceiling Bazel's
/// own timeout gives and not at it.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/integration/suite_connectors.dart';
import 'package:test/test.dart';

import 'fake_cdp_page.dart';
import 'fakes.dart';

const _ceiling = Duration(seconds: 30);

void main() {
  group('a web app\'s page', () {
    late FakeCdpPage page;
    late FakeProcess chrome;
    late AppInstance instance;
    setUp(() {
      page = FakeCdpPage();
      chrome = FakeProcess();
      instance = AppInstance(process: chrome);
    });

    SuiteConnector connector() => chromePageConnector(open: (_) async => page);

    test('is reached once its bridge is installed', () async {
      page.bridgeInstalled.complete();

      final transport = await connector()(
        WebDevice(),
        instance,
        ceiling: _ceiling,
      );

      expect(transport, isNotNull);
      expect(page.methods, contains('Runtime.addBinding'));
    });

    test('that never installs its bridge fails at the ceiling, saying the '
        'bootstrap was never reached, and lets go of the page', () {
      fakeAsync((async) {
        Object? failure;
        connector()(
          WebDevice(),
          instance,
          ceiling: _ceiling,
        ).then<void>((_) {}, onError: (Object e) => failure = e);

        async.elapse(_ceiling + const Duration(seconds: 1));

        expect(
          failure,
          isA<SuiteUnreachable>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('did not install the integration test bridge'),
              contains('within 30s'),
              contains('runIntegrationSuite'),
            ),
          ),
        );
        expect(page.isClosed, isTrue);
      });
    });

    test('that never installs its bridge says how far the page got: where it '
        'is, whether it loaded, and what it fetched', () {
      fakeAsync((async) {
        Object? failure;
        connector()(
          WebDevice(),
          instance,
          ceiling: _ceiling,
        ).then<void>((_) {}, onError: (Object e) => failure = e);

        async.elapse(_ceiling + const Duration(seconds: 1));

        expect(
          failure,
          isA<SuiteUnreachable>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('http://127.0.0.1:8080/'),
              contains('complete'),
              contains('main.dart.mjs 200'),
            ),
          ),
        );
      });
    });

    test('that never installs its bridge and does not answer is said to have '
        'a main thread that does not answer', () {
      fakeAsync((async) {
        page.pageState = null;
        Object? failure;
        connector()(
          WebDevice(),
          instance,
          ceiling: _ceiling,
        ).then<void>((_) {}, onError: (Object e) => failure = e);

        async.elapse(_ceiling + const Duration(seconds: 10));

        expect(
          failure,
          isA<SuiteUnreachable>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('did not install the integration test bridge'),
              contains('main thread'),
            ),
          ),
        );
        expect(page.isClosed, isTrue);
      });
    });

    test('that is lost before its bridge is installed fails with the '
        'browser\'s account of how it ended', () async {
      final result = connector()(WebDevice(), instance, ceiling: _ceiling);
      final outcome = expectLater(
        result,
        throwsA(
          isA<SuiteUnreachable>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('lost before it installed'),
              contains('exited with code 139'),
            ),
          ),
        ),
      );

      chrome.complete(139);
      await page.vanish();
      await outcome;
    });

    test('whose DevTools connection cannot be made fails saying so', () async {
      final connect = chromePageConnector(
        open: (_) async => throw StateError('connection refused'),
      );

      await expectLater(
        connect(WebDevice(), instance, ceiling: _ceiling),
        throwsA(
          isA<SuiteUnreachable>().having(
            (e) => e.message,
            'message',
            allOf(contains('DevTools'), contains('connection refused')),
          ),
        ),
      );
    });

    test('is not reached on a device that is not a browser', () async {
      await expectLater(
        connector()(MacOSDevice(), instance, ceiling: _ceiling),
        throwsA(
          isA<SuiteUnreachable>().having(
            (e) => e.message,
            'message',
            contains('reaches a web app'),
          ),
        ),
      );
    });
  });
}
