import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_bazel_dev_tool/devicectl_screens.dart';
import 'package:flutter_bazel_dev_tool/runfiles_helper.dart';
import 'package:flutter_bazel_dev_tool/screen.dart';
import 'package:test/test.dart';

import 'fakes.dart';

/// Reads a `devicectl device info displays --json-output` recording.
///
/// Recorded with Xcode 27 (devicectl 651.32, `jsonVersion` 5): the iPhone Duo
/// simulator folded, half open and open, an iPhone 17 simulator, and a wired
/// iPhone, which reports a wireless display beside its own. Only the command
/// line and environment of the recording are scrubbed.
String recording(String name) {
  final key =
      'rules_flutter/tools/dev_tool/test/fixtures/devicectl_displays/$name.json';
  final path = resolveRunfile(key);
  if (path == null) {
    throw StateError(
      'Could not resolve $key from runfiles. These tests read recordings '
      'declared in the target\'s `data`, so they need the Bazel runfiles '
      'tree: run them with `bazel test //tools/dev_tool:screen_test`.',
    );
  }
  return File(path).readAsStringSync();
}

Screen? defaultOf(String name) {
  final choice = chooseScreen(parseDevicectlDisplays(recording(name)), null);
  return switch (choice) {
    ChosenScreen(:final screen) => screen,
    PostureNotReported() => null,
  };
}

void main() {
  group('the recorded devicectl displays', tags: 'runfiles', () {
    test('a folded Duo: the app is on LCD', () {
      final screens = parseDevicectlDisplays(recording('duo_folded'));
      expect(screens.map((s) => s.name), ['LCD', 'LCD-1']);
      expect(screens.map((s) => s.active), [true, false]);
      expect(screens.map((s) => (s.width, s.height)), [
        (1398, 2034),
        (2007, 2853),
      ]);
      expect(screens.every((s) => s.type == 'integrated'), isTrue);
      expect(defaultOf('duo_folded')!.name, 'LCD');
    });

    test('an open Duo: the app is on LCD-1', () {
      expect(defaultOf('duo_open')!.name, 'LCD-1');
    });

    test('a half-open Duo: the app is on LCD-1', () {
      expect(defaultOf('duo_half_open')!.name, 'LCD-1');
    });

    test('a one-screen simulator reports no `active` and has one screen', () {
      final screens = parseDevicectlDisplays(recording('one_screen_simulator'));
      expect(screens, hasLength(1));
      expect(screens.single.active, isNull);
      expect(defaultOf('one_screen_simulator')!.name, 'LCD');
    });

    test('a wired iPhone: its own screen, not the wireless display', () {
      final screens = parseDevicectlDisplays(recording('iphone_wired'));
      expect(screens.map((s) => (s.name, s.type)), [
        ('LCD', 'integrated'),
        ('Wireless', 'wireless'),
      ]);
      // The built-in screen has no unique id: its id is the displayId, and it
      // is captured as the primary.
      final lcd = screens.first;
      expect(lcd.id, 'displayId:1');
      expect(lcd.captureId, isNull);
      expect(lcd.primary, isTrue);
      expect(lcd.capturable, isTrue);
      expect(screens.last.captureId, isNotNull);
      expect(defaultOf('iphone_wired')!.name, 'LCD');
    });

    test('a Duo just booted has not reported its posture', () {
      // What the Duo says in its first seconds: every `active` absent. The
      // folded recording with that one key taken out of each display.
      final screens = [
        for (final s in parseDevicectlDisplays(recording('duo_folded')))
          Screen(
            id: s.id,
            name: s.name,
            type: s.type,
            displayId: s.displayId,
            primary: s.primary,
            captureId: s.captureId,
          ),
      ];
      expect(chooseScreen(screens, null), isA<PostureNotReported>());
    });
  });

  group('parseDevicectlDisplays', () {
    String displays(String list) => '{"result":{"displays":[$list]}}';

    test('refuses JSON with no displays', () {
      expect(() => parseDevicectlDisplays('{"result":{}}'), throwsStateError);
      expect(() => parseDevicectlDisplays('nope'), throwsStateError);
    });

    test('refuses a display with no type', () {
      expect(
        () => parseDevicectlDisplays(displays('{"name":"X","displayId":1}')),
        throwsStateError,
      );
    });

    test('refuses a display it cannot address at all', () {
      expect(
        () => parseDevicectlDisplays(
          displays('{"name":"X","type":{"integrated":{}}}'),
        ),
        throwsStateError,
      );
    });
  });

  group('chooseScreen', () {
    const inner = Screen(
      id: 'A',
      name: 'LCD',
      type: 'integrated',
      displayId: 1,
      primary: true,
      captureId: 'A',
    );
    const outer = Screen(
      id: 'B',
      name: 'LCD-1',
      type: 'integrated',
      displayId: 3,
      captureId: 'B',
    );
    const wireless = Screen(
      id: 'W',
      name: 'Wireless',
      type: 'wireless',
      displayId: 2,
      captureId: 'W',
    );

    Screen chosen(List<Screen> screens, [String? requested]) =>
        switch (chooseScreen(screens, requested)) {
          ChosenScreen(:final screen) => screen,
          PostureNotReported() => fail('expected a screen'),
        };

    Screen withActive(Screen s, bool? active) => Screen(
      id: s.id,
      name: s.name,
      type: s.type,
      displayId: s.displayId,
      active: active,
      primary: s.primary,
      captureId: s.captureId,
    );

    test('a device with no screen to report is an error', () {
      expect(
        () => chooseScreen([], null),
        throwsA(isA<ScreenSelectionException>()),
      );
    });

    test('the one screen of a one-screen device', () {
      expect(chosen([const Screen.only('macOS')]).id, 'main');
    });

    test('an external screen is never the default', () {
      expect(chosen([inner, wireless]), inner);
      expect(
        () => chooseScreen([wireless], null),
        throwsA(
          isA<ScreenSelectionException>().having(
            (e) => e.reason,
            'reason',
            contains('no built-in screen'),
          ),
        ),
      );
    });

    test('an external screen is captured when it is asked for', () {
      expect(chosen([inner, wireless], 'Wireless'), wireless);
    });

    test('of several built-in screens, the one that is active', () {
      expect(
        chosen([withActive(inner, false), withActive(outer, true)]).name,
        'LCD-1',
      );
    });

    test('active is read on its own, whatever else the screen says', () {
      // Neither is `active: true` and nothing else is looked at: an error,
      // not a pick of the primary.
      expect(
        () => chooseScreen(
          [withActive(inner, false), withActive(outer, false)],
          null,
        ),
        throwsA(
          isA<ScreenSelectionException>().having(
            (e) => e.reason,
            'reason',
            contains('none is active'),
          ),
        ),
      );
    });

    test('two active screens are an error', () {
      expect(
        () => chooseScreen(
          [withActive(inner, true), withActive(outer, true)],
          null,
        ),
        throwsA(
          isA<ScreenSelectionException>().having(
            (e) => e.reason,
            'reason',
            contains('2 of the device'),
          ),
        ),
      );
    });

    test('several built-in screens that have not reported: not yet', () {
      expect(chooseScreen([inner, outer], null), isA<PostureNotReported>());
    });

    test('a request names a screen by id, displayId or name', () {
      for (final request in ['B', 'displayId:3', 'LCD-1']) {
        expect(chosen([inner, outer], request), outer, reason: request);
      }
    });

    test('a request needs no posture', () {
      expect(chosen([inner, outer], 'LCD'), inner);
    });

    test('a request that names nothing, or two screens, is an error', () {
      expect(
        () => chooseScreen([inner, outer], 'nope'),
        throwsA(
          isA<ScreenSelectionException>().having(
            (e) => e.reason,
            'reason',
            contains('No screen is named "nope"'),
          ),
        ),
      );
      const twin = Screen(
        id: 'C',
        name: 'LCD',
        type: 'integrated',
        displayId: 4,
        captureId: 'C',
      );
      expect(
        () => chooseScreen([inner, twin], 'LCD'),
        throwsA(
          isA<ScreenSelectionException>().having(
            (e) => e.reason,
            'reason',
            contains('names 2 screens'),
          ),
        ),
      );
    });

    test('a screen with no unique id that is not primary cannot be taken', () {
      const bare = Screen(
        id: 'displayId:3',
        name: 'LCD-1',
        type: 'integrated',
        displayId: 3,
        active: true,
      );
      expect(
        () => chooseScreen([withActive(inner, false), bare], null),
        throwsA(isA<ScreenSelectionException>()),
      );
    });

    test('the error lists every screen with its state', () {
      try {
        chooseScreen([withActive(inner, true), withActive(outer, true)], null);
        fail('expected an error');
      } on ScreenSelectionException catch (e) {
        expect(e.message, contains('LCD (id A, integrated, active)'));
        expect(e.message, contains('LCD-1 (id B, integrated, active)'));
        expect(e.message, contains('screen=<id or name>'));
      }
    });
  });

  // Time in these is the test's: `fakeAsync` moves it only on `elapse`.
  const ms = Duration(milliseconds: 1);

  group('resolveScreenOf', () {
    const inner = Screen(
      id: 'A',
      name: 'LCD',
      type: 'integrated',
      primary: true,
      captureId: 'A',
    );
    const outer = Screen(
      id: 'B',
      name: 'LCD-1',
      type: 'integrated',
      captureId: 'B',
    );

    List<Screen> reported() => [
      const Screen(
        id: 'A',
        name: 'LCD',
        type: 'integrated',
        active: false,
        primary: true,
        captureId: 'A',
      ),
      const Screen(
        id: 'B',
        name: 'LCD-1',
        type: 'integrated',
        active: true,
        captureId: 'B',
      ),
    ];

    test('asks again every interval until the device reports', () {
      fakeAsync((async) {
        var asks = 0;
        final outcome = track(
          resolveScreenOf(
            (_) async {
              asks++;
              return asks < 4 ? [inner, outer] : reported();
            },
            null,
            deadline: ScreenshotDeadline(const Duration(seconds: 5)),
            interval: ms * 10,
          ),
        );

        async.elapse(ms * 29);
        expect(outcome.done, isFalse);
        expect(asks, 3);
        async.elapse(ms);

        expect(outcome.value?.id, 'B');
        expect(asks, 4);
      });
    });

    test('a request does not wait for posture', () {
      fakeAsync((async) {
        var asks = 0;
        final outcome = track(
          resolveScreenOf(
            (_) async {
              asks++;
              return [inner, outer];
            },
            'LCD-1',
            deadline: ScreenshotDeadline(const Duration(seconds: 5)),
            interval: const Duration(seconds: 5),
          ),
        );
        async.flushMicrotasks();

        expect(outcome.value?.id, 'B');
        expect(asks, 1);
      });
    });

    test('gives up when another interval would pass the deadline', () {
      fakeAsync((async) {
        var asks = 0;
        final outcome = track(
          resolveScreenOf(
            (_) async {
              asks++;
              return [inner, outer];
            },
            null,
            deadline: ScreenshotDeadline(ms * 100),
            interval: ms * 20,
          ),
        );

        // Asked at 0, 20, 40, 60 and 80 ms. At 80 there are 20 left, which is
        // the interval, so there is no sixth ask.
        async.elapse(ms * 79);
        expect(outcome.done, isFalse);
        async.elapse(ms);

        expect(asks, 5);
        expect(
          outcome.error,
          isA<ScreenSelectionException>()
              .having(
                (e) => e.reason,
                'reason',
                'The screenshot\'s 100ms ran out while waiting for the device '
                    'to report which of its screens is active.',
              )
              .having((e) => e.screens, 'screens', [inner, outer]),
        );
      });
    });

    test('a listing the deadline lands in is still the posture wait', () {
      fakeAsync((async) {
        var asks = 0;
        final outcome = track(
          resolveScreenOf(
            (deadline) {
              asks++;
              return deadline.within(
                'listing the screens',
                () => Future.delayed(ms * 30, () => [inner, outer]),
              );
            },
            null,
            deadline: ScreenshotDeadline(ms * 100),
            interval: ms * 5,
          ),
        );

        // Listings run 0-30, 35-65, 70-100: the third is cut off by the
        // deadline, after the posture was seen to be missing.
        async.elapse(ms * 100);

        expect(asks, 3);
        expect(
          outcome.error,
          isA<ScreenSelectionException>().having(
            (e) => e.reason,
            'reason',
            contains('waiting for the device to report'),
          ),
        );
      });
    });

    test('the first listing running out is that step, not a posture wait', () {
      fakeAsync((async) {
        final outcome = track(
          resolveScreenOf(
            (deadline) => deadline.within(
              'listing the screens',
              () => Future.delayed(ms * 500, () => [inner, outer]),
            ),
            null,
            deadline: ScreenshotDeadline(ms * 100),
            interval: ms * 5,
          ),
        );
        async.elapse(ms * 100);

        expect(
          outcome.error,
          isA<ScreenshotTimeout>().having(
            (e) => e.step,
            'step',
            'listing the screens',
          ),
        );
      });
    });
  });

  group('ScreenshotDeadline', () {
    test('counts down with the clock and hands out whole seconds', () {
      fakeAsync((async) {
        final deadline = ScreenshotDeadline(const Duration(seconds: 3));
        expect(deadline.remaining, const Duration(seconds: 3));
        expect(deadline.seconds, 3);

        async.elapse(ms * 1200);
        expect(deadline.remaining, ms * 1800);
        expect(deadline.seconds, 2);

        async.elapse(ms * 1799);
        expect(deadline.remaining, ms);
        expect(deadline.seconds, 1);
        expect(deadline.expired, isFalse);

        async.elapse(ms);
        expect(deadline.expired, isTrue);
        expect(deadline.remaining, Duration.zero);
        // Never zero: a program told zero may read it as no limit.
        expect(deadline.seconds, 1);
      });
    });

    test('a step that outlasts it is a timeout naming the step', () {
      fakeAsync((async) {
        final deadline = ScreenshotDeadline(ms * 50);
        final outcome = track(
          deadline.within(
            'listing the screens',
            () => Future<void>.delayed(const Duration(seconds: 5)),
          ),
        );

        async.elapse(ms * 49);
        expect(outcome.done, isFalse);
        async.elapse(ms);

        expect(
          outcome.error,
          isA<ScreenshotTimeout>()
              .having((e) => e.step, 'step', 'listing the screens')
              .having(
                (e) => e.message,
                'message',
                "The screenshot's 50ms ran out while listing the screens.",
              ),
        );
      });
    });

    test('a step started after it ran out does not run', () {
      fakeAsync((async) {
        final deadline = ScreenshotDeadline(ms * 10);
        async.elapse(ms * 10);
        var ran = false;
        final outcome = track(
          deadline.within('capturing', () async {
            ran = true;
          }),
        );
        async.flushMicrotasks();

        expect(ran, isFalse);
        expect(outcome.error, isA<ScreenshotTimeout>());
      });
    });

    test('a step that fails in time keeps its own error', () {
      fakeAsync((async) {
        final deadline = ScreenshotDeadline(const Duration(seconds: 5));
        final outcome = track(
          deadline.within('capturing LCD', () async => throw StateError('no')),
        );
        async.flushMicrotasks();

        expect(outcome.error, isA<StateError>());
        expect(outcome.error, isNot(isA<ScreenshotTimeout>()));
      });
    });
  });
}
