/// `ChromeSession`: one launched Chrome, its profile, and the waits that end
/// its launch.
///
/// The browser is faked at both ends the launch touches: its process (a
/// [FakeProcess] that prints what Chrome prints) and its DevTools endpoint (a
/// [FakeBrowserCdp] that sends the target events Chrome sends).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/chrome_profile.dart';
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/web_options.dart';
import 'package:test/test.dart';

import 'fakes.dart';

/// One `ChromeSession.launch` against a [FakeProcess].
class _ChromeLaunch {
  final FakeProcess proc = FakeProcess();
  late final List<String> args;
  late final Future<ChromeSession> result;

  _ChromeLaunch(
    ChromeProfiles profiles, {
    required String url,
    BrowserLaunchOptions options = const BrowserLaunchOptions(),
    Future<void>? abandoned,
    Timer Function(Duration, void Function())? startNotice,
    Duration stopBound = const Duration(seconds: 5),
  }) {
    result = ChromeSession.launch(
      url: url,
      chromePath: '/fake/chrome',
      options: options,
      profiles: profiles,
      abandoned: abandoned,
      startNotice: startNotice ?? Timer.new,
      stopBound: stopBound,
      startProcess: (exe, a) async {
        args = a;
        return proc;
      },
    );
  }

  /// The profile directory the launch created, recovered from its argv.
  Directory get profileDir => Directory(
    args
        .firstWhere((a) => a.startsWith('--user-data-dir='))
        .substring('--user-data-dir='.length),
  );
}

void main() {
  group('ChromeSession', () {
    const appUrl = 'http://localhost:8080';

    late FakeBrowserCdp browser;
    late Directory profileRoot;
    late ChromeProfiles profiles;

    setUp(() async {
      browser = await FakeBrowserCdp.start();
      profileRoot = await Directory.systemTemp.createTemp(
        'chrome_session_test_',
      );
      profiles = ChromeProfiles(parent: profileRoot);
    });

    tearDown(() async {
      await browser.close();
      await profileRoot.delete(recursive: true);
    });

    _ChromeLaunch start({
      String url = appUrl,
      BrowserLaunchOptions options = const BrowserLaunchOptions(),
      Future<void>? abandoned,
      Timer Function(Duration, void Function())? startNotice,
      Duration stopBound = const Duration(seconds: 5),
    }) => _ChromeLaunch(
      profiles,
      url: url,
      options: options,
      abandoned: abandoned,
      startNotice: startNotice,
      stopBound: stopBound,
    );

    /// The tab, once the browser has navigated it to the app.
    void showApp([String id = 'app']) =>
        browser.target(id, type: 'page', url: '$appUrl/index.html');

    /// What a just-launched browser has open besides the app.
    void showStartupTargets() {
      browser.target(
        'ext',
        type: 'background_page',
        url: 'chrome-extension://x/bg.html',
      );
    }

    /// The launch has announced its port and is waiting on the page.
    Future<void> announce(_ChromeLaunch launch) async {
      await launch.proc.outputAttached;
      launch.proc.emitStderr(browser.announcement);
    }

    test(
      'launches with the debug flags, a fresh profile, and the app URL',
      () async {
        showStartupTargets();
        browser.target('blank', type: 'page', url: 'about:blank');
        showApp();

        final launch = start();
        await announce(launch);
        final session = await launch.result;
        addTearDown(session.profile.release);

        expect(launch.args.first, '--remote-debugging-port=0');
        expect(launch.args, containsAll(chromeDebugFlags));
        expect(
          launch.args.last,
          appUrl,
          reason: 'the app URL is what the launched tab must navigate to',
        );
        expect(
          await launch.profileDir.exists(),
          isTrue,
          reason: 'the launch owns a real, fresh profile directory',
        );
        expect(session.cdpPort, browser.port);
        expect(session.appUrl, appUrl);
        // What the run announces for a client that drives Chrome itself: the
        // app's page, not the extension or the blank tab listed beside it.
        expect(session.pageWebSocketDebuggerUrl, browser.pageEndpoint('app'));
      },
    );

    test('waits for the tab to navigate to the app page', () async {
      // The states a just-launched browser passes through before the app page
      // exists: nothing but an extension, then a tab still on about:blank.
      showStartupTargets();
      final launch = start();
      var finished = false;
      unawaited(launch.result.then((_) => finished = true, onError: (_) {}));
      await announce(launch);
      await browser.discovering;

      browser.target('tab', type: 'page', url: 'about:blank');
      await pumpEventQueue();
      expect(
        finished,
        isFalse,
        reason: 'a tab that has not navigated is not the app page',
      );

      // The same tab, now at the app: Chrome says so with a change event.
      browser.target('tab', type: 'page', url: '$appUrl/index.html');
      final session = await launch.result;
      addTearDown(session.profile.release);
      expect(session.pageWebSocketDebuggerUrl, browser.pageEndpoint('tab'));
    });

    test('waits out a page replaced under the wait', () async {
      // Cross-origin isolation swaps the browsing context group: the app's
      // page is listed with no URL for a moment, then replaced by another
      // target. The first is not the app's page; the second is.
      final launch = start();
      var finished = false;
      unawaited(launch.result.then((_) => finished = true, onError: (_) {}));
      await announce(launch);
      await browser.discovering;

      browser.target('first', type: 'page', url: '');
      await pumpEventQueue();
      expect(finished, isFalse);
      browser.destroy('first');
      browser.target('second', type: 'page', url: '$appUrl/index.html');

      final session = await launch.result;
      addTearDown(session.profile.release);
      expect(session.pageWebSocketDebuggerUrl, browser.pageEndpoint('second'));
    });

    test('fails the launch when Chrome exits before showing the app page, '
        'quoting what it said, and cleans up', () async {
      showStartupTargets();
      final launch = start();
      await announce(launch);
      await browser.discovering;
      launch.proc.emitStderr('The GPU process crashed.\n');
      launch.proc.complete(9);

      await expectLater(
        launch.result,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains(appUrl),
              contains('exited'),
              contains('9'),
              contains('The GPU process crashed.'),
            ),
          ),
        ),
      );
      expect(await launch.profileDir.exists(), isFalse);
    });

    test('fails the launch when Chrome closes its debugging connection '
        'before showing the app page, and cleans up', () async {
      final launch = start();
      await announce(launch);
      await browser.discovering;
      await browser.dropBrowserConnections();

      await expectLater(
        launch.result,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains(appUrl), contains('closed its DevTools connection')),
          ),
        ),
      );
      expect(
        await launch.proc.exitCode,
        isNotNull,
        reason: 'the failed launch must not leave the browser running',
      );
      expect(await launch.profileDir.exists(), isFalse);
    });

    test('fails the launch when Chrome exits without announcing a port, '
        'quoting what it said, and cleans up', () async {
      final launch = start();
      await launch.proc.outputAttached;
      // The shape this actually takes on a CI runner: Chrome refuses its
      // sandbox, says why, and exits. The reason exists only on stderr — the
      // exit status is a bare 1 — so an error that does not carry it forward
      // reports a symptom and destroys the cause.
      launch.proc.emitStderr(
        'Running as root without --no-sandbox is not supported.',
      );
      launch.proc.complete(1);

      await expectLater(
        launch.result,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('exited'),
              contains('debugging port'),
              contains('Running as root without --no-sandbox'),
            ),
          ),
        ),
      );
      expect(await launch.profileDir.exists(), isFalse);
    });

    test('says so when Chrome exits having printed nothing', () async {
      // The other half: silence is a diagnosis too — it rules out every cause
      // that announces itself. Rendering an empty tail as nothing at all would
      // read as if the quoting had been forgotten.
      final launch = start();
      await launch.proc.outputAttached;
      launch.proc.complete(1);

      await expectLater(
        launch.result,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('printed nothing at all'),
          ),
        ),
      );
      expect(await launch.profileDir.exists(), isFalse);
    });

    test('waits out a slow Chrome rather than failing it', () async {
      // The CI failure this shape stands for: a cold browser on a loaded
      // runner taking far longer than a workstation's. Only the browser
      // answering, exiting or the run ending may end a wait; the notice that
      // it is slow must not. The notice is fired by hand — no time passes.
      final notices = <(Duration, void Function())>[];
      final launch = start(
        startNotice: (delay, callback) {
          notices.add((delay, callback));
          return Timer(const Duration(days: 1), () {});
        },
      );
      await launch.proc.outputAttached;
      expect(notices, hasLength(1));
      notices.single.$2();

      // The port wait outlived its notice; the page wait gets its own.
      launch.proc.emitStderr(browser.announcement);
      await browser.discovering;
      expect(notices, hasLength(2));
      notices.last.$2();

      showApp();
      final session = await launch.result;
      addTearDown(session.profile.release);
      expect(session.cdpPort, browser.port);
    });

    test('fails at once when Chrome cannot open its debugging server, '
        'quoting it, and cleans up', () async {
      final launch = start(
        options: const BrowserLaunchOptions(debugPort: 9222),
      );
      await launch.proc.outputAttached;
      // What Chrome prints with the port taken on both loopback addresses —
      // and then it keeps running, so nothing else would end the wait.
      launch.proc.emitStderr(
        '[1:2:ERROR:net/socket/socket_posix.cc:175] bind() failed: '
        'Address already in use (48)\n'
        '[1:2:ERROR:content/browser/devtools/devtools_http_handler.cc:322] '
        'Cannot start http server for devtools.\n',
      );

      await expectLater(
        launch.result,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('could not open its DevTools debugging server'),
              contains('--web-browser-debug-port 9222'),
              contains('Address already in use'),
            ),
          ),
        ),
      );
      expect(await launch.proc.exitCode, isNotNull);
      expect(await launch.profileDir.exists(), isFalse);
    });

    test('a failed launch lets go of the browser\'s output pipes', () async {
      // A helper of the browser can outlive it holding the write ends of
      // these pipes; a reader still attached then keeps the tool's process
      // from exiting.
      final launch = start(
        options: const BrowserLaunchOptions(debugPort: 9222),
      );
      await launch.proc.outputAttached;
      launch.proc.emitStderr('Cannot start http server for devtools.\n');
      await expectLater(launch.result, throwsA(isA<StateError>()));

      expect(launch.proc.stdoutHasListener, isFalse);
      expect(launch.proc.stderrHasListener, isFalse);
    });

    test('refuses a debugging server that is not on 127.0.0.1', () async {
      // Chrome falls back to [::1] when 127.0.0.1:port is taken; every CDP
      // consumer here would then dial whatever holds 127.0.0.1:port.
      final launch = start(
        options: const BrowserLaunchOptions(debugPort: 9222),
      );
      await launch.proc.outputAttached;
      launch.proc.emitStderr(
        'DevTools listening on ws://[::1]:9222/devtools/browser/x\n',
      );

      await expectLater(
        launch.result,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('[::1]:9222'), contains('127.0.0.1')),
          ),
        ),
      );
      expect(await launch.proc.exitCode, isNotNull);
      expect(await launch.profileDir.exists(), isFalse);
    });

    test(
      'an abandoned launch stops waiting on a silent Chrome and cleans up',
      () async {
        final abandoned = Completer<void>();
        final launch = start(abandoned: abandoned.future);
        await launch.proc.outputAttached;
        // The browser stays up and says nothing; the run ends.
        abandoned.complete();

        await expectLater(
          launch.result,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('abandoned'),
            ),
          ),
        );
        expect(await launch.proc.exitCode, isNotNull);
        expect(await launch.profileDir.exists(), isFalse);
      },
    );

    test('an abandoned launch stops waiting for a page that never comes, '
        'and cleans up', () async {
      final abandoned = Completer<void>();
      showStartupTargets();
      final launch = start(abandoned: abandoned.future);
      await announce(launch);
      await browser.discovering;
      abandoned.complete();

      await expectLater(
        launch.result,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('abandoned'),
          ),
        ),
      );
      expect(await launch.proc.exitCode, isNotNull);
      expect(await launch.profileDir.exists(), isFalse);
    });

    test('a launch abandoned before it starts starts nothing', () async {
      final abandoned = Completer<void>()..complete();
      var started = false;
      await expectLater(
        ChromeSession.launch(
          url: appUrl,
          chromePath: '/fake/chrome',
          profiles: profiles,
          abandoned: abandoned.future,
          startProcess: (exe, a) async {
            started = true;
            return FakeProcess();
          },
        ),
        throwsA(isA<StateError>()),
      );
      expect(started, isFalse);
      expect(
        profileRoot.listSync(),
        isEmpty,
        reason: 'the profile it had made was released',
      );
    });

    test('a failed launch ends a browser that ignores SIGTERM', () async {
      // A browser wedged enough to ignore SIGTERM is the one most likely to be
      // why the launch failed, and waiting on its exit forever would hold the
      // failure — and the teardown waiting on this launch — for good.
      final abandoned = Completer<void>();
      final launch = start(
        abandoned: abandoned.future,
        stopBound: const Duration(milliseconds: 20),
      );
      launch.proc.ignoresSigterm = true;
      await launch.proc.outputAttached;
      abandoned.complete();

      await expectLater(launch.result, throwsA(isA<StateError>()));
      expect(launch.proc.signals, [
        ProcessSignal.sigterm,
        ProcessSignal.sigkill,
      ]);
      expect(await launch.profileDir.exists(), isFalse);
    });

    test('the profile stays locked to the launching process until released, '
        'then goes', () async {
      showApp();
      final launch = start();
      await announce(launch);
      final session = await launch.result;

      expect(
        File(
          '${launch.profileDir.path}/${ChromeProfile.ownerFileName}',
        ).existsSync(),
        isTrue,
      );
      await session.profile.release();
      expect(await launch.profileDir.exists(), isFalse);
    });

    group('browser launch options', () {
      // Asserted on the argv rather than by launching a real browser: what a
      // flag does here IS the command line, and a mis-ordered or missing
      // switch is the whole failure mode.

      List<String> argsFor(BrowserLaunchOptions options) =>
          ChromeSession.launchArgs(appUrl, options, userDataDir: '/tmp/p');

      // Capture resolution follows the launch switch, not the CDP override: a
      // `deviceScaleFactor` in the override alone is lost once the CDP client
      // detaches, so the scale has to reach the command line. Width and height
      // must not — those stay the CDP override's, since --window-size cannot
      // express them.
      test('a viewport scale becomes --force-device-scale-factor', () {
        final args = argsFor(
          const BrowserLaunchOptions(
            viewport: WebViewport(
              width: 393,
              height: 660,
              deviceScaleFactor: 3,
            ),
          ),
        );
        expect(args, contains('--force-device-scale-factor=3.0'));
        expect(args.where((a) => a.startsWith('--window-size')), isEmpty);
      });

      test('a viewport without a scale leaves the command line alone', () {
        final args = argsFor(
          const BrowserLaunchOptions(
            viewport: WebViewport(width: 393, height: 660),
          ),
        );
        expect(
          args.where((a) => a.startsWith('--force-device-scale-factor')),
          isEmpty,
        );
      });

      test('--web-run-headless adds headless and a real window size', () {
        final args = argsFor(const BrowserLaunchOptions(headless: true));
        expect(args, contains('--headless'));
        expect(args, contains('--window-size=2400,1800'));
      });

      test('headless does not turn the sandbox off', () {
        // Upstream bundles `--no-sandbox` with headless. A launch that
        // quietly drops a security boundary is not what the flag says it
        // does; --web-browser-flag=--no-sandbox is how a run that needs it
        // asks.
        expect(
          argsFor(const BrowserLaunchOptions(headless: true)),
          isNot(contains('--no-sandbox')),
        );
        expect(
          argsFor(const BrowserLaunchOptions()),
          isNot(contains('--headless')),
        );
      });

      test('--web-browser-flag lands last, just before the URL', () {
        // Chrome resolves a repeated switch by position, so a user switch
        // that fights one of the tool's defaults has to come after it to
        // mean anything at all.
        final args = argsFor(
          const BrowserLaunchOptions(
            browserFlags: ['--mute-audio', '--lang=fr'],
          ),
        );
        expect(args.last, appUrl);
        expect(args[args.length - 3], '--mute-audio');
        expect(args[args.length - 2], '--lang=fr');
        for (final own in chromeDebugFlags) {
          expect(
            args.indexOf(own),
            lessThan(args.indexOf('--mute-audio')),
            reason: 'a user switch must be able to override $own',
          );
        }
      });

      test('--web-browser-debug-port is the port asked for', () {
        expect(
          argsFor(const BrowserLaunchOptions(debugPort: 9222)).first,
          '--remote-debugging-port=9222',
        );
        // Unset still asks explicitly, for any free port.
        expect(
          argsFor(const BrowserLaunchOptions()).first,
          '--remote-debugging-port=0',
        );
      });

      test(
        'a fixed debug port is still awaited, and taken from the browser',
        () async {
          // The announcement is the readiness signal, not merely the number: a
          // launch that trusted the flag and skipped the wait would hand every
          // CDP consumer a port before anything was listening on it.
          showApp();
          final launch = start(
            options: BrowserLaunchOptions(debugPort: browser.port),
          );
          await launch.proc.outputAttached;
          expect(launch.args.first, '--remote-debugging-port=${browser.port}');
          launch.proc.emitStderr(browser.announcement);

          final session = await launch.result;
          addTearDown(session.profile.release);
          expect(session.cdpPort, browser.port);
        },
      );

      test('a browser that takes a different port fails the launch', () async {
        // Nothing here could drive that browser: every CDP consumer dials the
        // port that was asked for.
        showApp();
        final launch = start(
          options: BrowserLaunchOptions(debugPort: browser.port + 1),
        );
        await launch.proc.outputAttached;
        launch.proc.emitStderr(browser.announcement);

        await expectLater(
          launch.result,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('--web-browser-debug-port'),
                contains('${browser.port + 1}'),
                contains('${browser.port}'),
              ),
            ),
          ),
        );
        expect(await launch.proc.exitCode, isNotNull);
        expect(await launch.profileDir.exists(), isFalse);
      });

      test('a launch URL with a route still finds the app page', () async {
        // The tab's URL and the launch URL are not the same string once the
        // app routes, so the page is matched on origin. Here the launched URL
        // carries a fragment the listed target does not.
        showApp();
        final launch = start(url: '$appUrl/#/settings');
        await launch.proc.outputAttached;
        launch.proc.emitStderr(browser.announcement);

        final session = await launch.result;
        addTearDown(session.profile.release);
        expect(launch.args.last, '$appUrl/#/settings');
        expect(session.cdpPort, browser.port);
      });
    });
  });
}
