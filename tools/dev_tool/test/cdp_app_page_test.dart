/// `waitForAppPage`: the launch's wait for the browser to show the app, driven
/// by the browser's own target events.
///
/// The browser is a [FakeBrowserCdp], which sends the events Chrome sends. The
/// slow-progress notice is fired by hand through the injectable timer, so no
/// test here waits for time to pass or asserts on how long anything took.
library;

import 'dart:async';

import 'package:flutter_bazel_dev_tool/cdp_app_page.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  const appUrl = 'http://localhost:8080';

  late FakeBrowserCdp browser;
  late Completer<int> browserExit;
  late List<LogRecord> records;

  setUp(() async {
    browser = await FakeBrowserCdp.start();
    browserExit = Completer<int>();
    records = [];
    Logger.root.level = Level.ALL;
    final sub = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      await sub.cancel();
      await browser.close();
    });
  });

  /// Starts the wait; [notices] collects the slow-progress timers it starts.
  Future<String> wait({
    List<(Duration, void Function())>? notices,
    Uri? endpoint,
  }) => waitForAppPage(
    browserEndpoint: endpoint ?? browser.browserEndpoint,
    appUrl: appUrl,
    browserExit: browserExit.future,
    lastWords: () => 'It last said: nothing useful.',
    slowNotice: const Duration(seconds: 10),
    startNotice: (delay, callback) {
      notices?.add((delay, callback));
      return Timer(const Duration(days: 1), () {});
    },
  );

  test('returns the app page that already exists when it connects', () async {
    browser.target(
      'ext',
      type: 'background_page',
      url: 'chrome-extension://x/',
    );
    browser.target('app', type: 'page', url: '$appUrl/index.html');

    expect(await wait(), browser.pageEndpoint('app'));
  });

  test('ignores a page on another origin, including a neighbouring port', () async {
    // `http://localhost:80801` has `http://localhost:8080` as a string prefix.
    browser.target('other', type: 'page', url: 'http://localhost:80801/');
    browser.target('blank', type: 'page', url: 'about:blank');
    final result = wait();
    var done = false;
    unawaited(result.then((_) => done = true));
    await browser.discovering;
    await pumpEventQueue();
    expect(done, isFalse);

    browser.target('app', type: 'page', url: '$appUrl/');
    expect(await result, browser.pageEndpoint('app'));
  });

  test(
    'takes a tab that navigates to the app after it was listed blank',
    () async {
      browser.target('tab', type: 'page', url: 'about:blank');
      final result = wait();
      await browser.discovering;

      browser.target('tab', type: 'page', url: '$appUrl/');
      expect(await result, browser.pageEndpoint('tab'));
    },
  );

  test('does not take a page that was destroyed', () async {
    // The target is gone from the browser's own table, so a later change event
    // for something else must not resurrect it.
    browser.target('old', type: 'page', url: '');
    final result = wait();
    await browser.discovering;
    browser.destroy('old');
    browser.target('new', type: 'page', url: '$appUrl/');

    expect(await result, browser.pageEndpoint('new'));
  });

  test('the slow-progress notice warns, names what is open, and does not '
      'end the wait', () async {
    final notices = <(Duration, void Function())>[];
    browser.target('tab', type: 'page', url: 'about:blank');
    final result = wait(notices: notices);
    var done = false;
    unawaited(result.then((_) => done = true, onError: (_) => done = true));
    await browser.discovering;

    expect(notices.map((n) => n.$1), [const Duration(seconds: 10)]);
    // The notice names what the browser has open as of when it fires, and the
    // events that tell it arrive on the socket, not at a point the test can
    // see: fire until one has landed.
    String? text;
    for (var attempt = 0; attempt < 100 && text == null; attempt++) {
      notices.single.$2();
      await pumpEventQueue();
      for (final record in records.where((r) => r.level == Level.WARNING)) {
        final candidate = (record.object as Map)['text'] as String;
        if (candidate.contains('page:about:blank')) text = candidate;
      }
    }
    expect(text, isNotNull);
    expect(text, contains(appUrl));
    expect(done, isFalse, reason: 'a slow browser is waited for, not failed');

    browser.target('tab', type: 'page', url: '$appUrl/');
    expect(await result, browser.pageEndpoint('tab'));
  });

  test('fails when the browser exits, with what it said', () async {
    final result = wait();
    await browser.discovering;
    browserExit.complete(139);

    await expectLater(
      result,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('139'), contains('It last said: nothing useful.')),
        ),
      ),
    );
  });

  test('fails when the browser drops the debugging connection', () async {
    final result = wait();
    await browser.discovering;
    await browser.dropBrowserConnections();

    await expectLater(
      result,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('closed its DevTools connection'),
        ),
      ),
    );
  });

  test('fails with the browser\'s last words when it will not take a '
      'connection', () async {
    final endpoint = browser.browserEndpoint;
    await browser.close();

    await expectLater(
      wait(endpoint: endpoint),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('Could not connect'),
            contains('It last said: nothing useful.'),
          ),
        ),
      ),
    );
  });
}
