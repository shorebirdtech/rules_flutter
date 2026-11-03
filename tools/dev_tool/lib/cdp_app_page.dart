/// Waiting for a launched browser to show the app's page, on Chrome's word.
///
/// Right after launch the browser's tab is an `about:blank` that has not
/// navigated, and the page the app ends up on can be replaced under the
/// wait (cross-origin isolation swaps the browsing context group, and for a
/// moment the app's page is listed with no URL). How long that takes is the
/// machine's business — a cold Chrome on a loaded CI runner took longer than
/// any deadline that was comfortable on a workstation — so nothing here fails
/// on a clock. The wait ends when the page is there, when Chrome exits or
/// closes the connection, or when whoever called it stops waiting.
///
/// What it listens to is the browser's own target events: with
/// `Target.setDiscoverTargets` the browser reports every target that exists
/// (`Target.targetCreated`), every change to one's URL
/// (`Target.targetInfoChanged`) and every one that goes
/// (`Target.targetDestroyed`). Polling `/json` answers the same question, but
/// by sampling a listing that is not a settled fact at any instant.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';

import 'cdp_console.dart';
import 'logging.dart';

final _logger = Logger('dev_tool.cdp_app_page');

/// Starts the timer behind the slow-progress notice. Injectable so a test can
/// run the notice without waiting for it.
typedef NoticeTimer = Timer Function(Duration delay, void Function() callback);

/// Opens the browser-level CDP connection. Injectable for tests.
typedef CdpConnect = Future<WebSocket> Function(String url);

/// Wait until the browser shows a page on [appUrl]'s origin, and return the
/// page's CDP WebSocket URL, in the form the browser's `/json` listing gives.
///
/// [browserEndpoint] is the browser-level endpoint Chrome announces on stderr
/// (`ws://127.0.0.1:PORT/devtools/browser/ID`). [browserExit] completes when
/// the browser process exits; [lastWords] renders what it said before it did.
/// Throws a [StateError] when the browser exits or drops the connection first.
///
/// After [slowNotice] a warning says the page has not appeared and what the
/// browser does have open. That changes nothing about the wait.
Future<String> waitForAppPage({
  required Uri browserEndpoint,
  required String appUrl,
  required Future<int> browserExit,
  required String Function() lastWords,
  required Duration slowNotice,
  CdpConnect connect = WebSocket.connect,
  NoticeTimer startNotice = Timer.new,
}) async {
  final cdpPort = browserEndpoint.port;
  final sinceStart = clock.stopwatch()..start();
  final targets = <String, Map<String, Object?>>{};
  final found = Completer<String>();

  void fail(String message) {
    if (!found.isCompleted) found.completeError(StateError(message));
  }

  // The listing the app's page is picked from: the same shape and the same
  // rule (`pickCdpPageTarget`) as the `/json` listing every other CDP consumer
  // here uses, so there is one definition of "the app's page".
  List<Map<String, Object?>> listing() => [
    for (final t in targets.values)
      {
        'type': t['type'],
        'url': t['url'],
        'webSocketDebuggerUrl':
            'ws://127.0.0.1:$cdpPort/devtools/page/${t['targetId']}',
      },
  ];

  void look() {
    final page = pickCdpPageTarget(listing(), appUrl: appUrl);
    if (page != null && !found.isCompleted) found.complete(page);
  }

  final WebSocket socket;
  try {
    socket = await connect(browserEndpoint.toString());
  } on IOException catch (e) {
    // Chrome announced the endpoint and then would not take a connection on
    // it: it is exiting, or is not the browser it said it was.
    throw StateError(
      'Could not connect to Chrome\'s DevTools at $browserEndpoint: $e. '
      '${lastWords()}',
    );
  }
  var noticeGiven = false;
  final notice = startNotice(slowNotice, () {
    noticeGiven = true;
    _logger.warning({
      'message': 'browser_page_slow_to_appear',
      'text':
          'Chrome is running but has not shown $appUrl '
          '${sinceStart.elapsed.inSeconds}s after launch; still waiting. '
          'It has open: ${describeCdpTargets(listing())}.',
      'elapsedMs': sinceStart.elapsedMilliseconds,
      'appUrl': appUrl,
    });
  });

  final subscription = socket.listen(
    (data) {
      final Object? message;
      try {
        message = json.decode(data as String);
      } on FormatException {
        return;
      }
      if (message is! Map) return;
      final params = message['params'];
      switch (message['method']) {
        case 'Target.targetCreated' || 'Target.targetInfoChanged':
          final info = params is Map ? params['targetInfo'] : null;
          if (info is Map && info['targetId'] is String) {
            targets[info['targetId'] as String] = Map.of(
              info.cast<String, Object?>(),
            );
            look();
          }
        case 'Target.targetDestroyed':
          if (params is Map) targets.remove(params['targetId']);
      }
    },
    onDone: () => fail(
      'Chrome closed its DevTools connection before showing $appUrl. '
      '${lastWords()}',
    ),
    onError: (Object e) => fail(
      'The connection to Chrome\'s DevTools failed before it showed $appUrl: '
      '$e. ${lastWords()}',
    ),
  );
  unawaited(
    browserExit.then(
      (code) => fail(
        'Chrome exited (status $code) before showing $appUrl. ${lastWords()}',
      ),
    ),
  );

  try {
    socket.add(
      json.encode({
        'id': 1,
        'method': 'Target.setDiscoverTargets',
        'params': {'discover': true},
      }),
    );
    final page = await found.future;
    final shown = {
      'message': 'browser_page_shown',
      'text':
          'Chrome showed $appUrl ${sinceStart.elapsedMilliseconds}ms after '
          'launch.',
      'elapsedMs': sinceStart.elapsedMilliseconds,
    };
    noticeGiven ? _logger.info(shown) : _logger.fine(shown);
    return page;
  } finally {
    notice.cancel();
    await subscription.cancel();
    await socket.close();
  }
}
