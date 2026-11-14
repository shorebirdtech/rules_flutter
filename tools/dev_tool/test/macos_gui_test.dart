/// What an e2e test that needs a macOS window says when it cannot get one.
///
/// System Events answers every window request with an error (`-1719`) or with
/// nothing at all when the desktop is not live, and the error reads as a
/// missing Accessibility grant whether the screen is locked, the display is
/// asleep or the grant is really missing. A test that skipped on that error
/// told the person to grant a permission the Mac had already given, and
/// reported a pass for a test that never ran. These cases pin that the failure
/// is a failure, and that it names the condition the session is really in.
@TestOn('mac-os')
library;

import 'package:rules_flutter_e2e_testing/macos_gui_session.dart';
import 'package:test/test.dart';

import 'e2e/dev_tool_e2e_harness.dart';
import 'e2e/macos_gui.dart';

GuiState _state({
  bool locked = false,
  bool asleep = false,
  bool? trusted = true,
}) => GuiState(
  screenLocked: locked,
  displayAsleep: asleep,
  accessibilityTrusted: trusted,
);

/// What `osascript` printed when System Events refused.
final _refused = BoundedRun(
  exitCode: 1,
  stdout: '',
  stderr:
      'execution error: System Events got an error: osascript is not '
      'allowed assistive access. (-1719)',
);

/// An `osascript` that never answered.
final _silent = BoundedRun(exitCode: null, stdout: '', stderr: '');

void main() {
  group('systemEventsFailure', () {
    test('a locked screen is named, not an Accessibility grant', () {
      final message = systemEventsFailure(
        'minimizing the window',
        _refused,
        _state(locked: true),
      );
      expect(message, contains(GuiSession.explain(GuiBlocker.screenLocked)));
      expect(
        message,
        isNot(contains(GuiSession.explain(GuiBlocker.accessibilityDenied))),
      );
    });

    test('a display that stayed asleep is named', () {
      final message = systemEventsFailure(
        'minimizing the window',
        _refused,
        _state(asleep: true),
      );
      expect(message, contains(GuiSession.explain(GuiBlocker.displayAsleep)));
    });

    test('an untrusted runner is named when the session is live', () {
      final message = systemEventsFailure(
        'minimizing the window',
        _refused,
        _state(trusted: false),
      );
      expect(
        message,
        contains(GuiSession.explain(GuiBlocker.accessibilityDenied)),
      );
    });

    test('silence from a live session points at Automation consent', () {
      final message = systemEventsFailure(
        'minimizing the window',
        _silent,
        _state(),
      );
      expect(message, contains('Automation'));
      expect(message, contains('timed out'));
    });

    test('says what was being done, how it failed, and what was read', () {
      final message = systemEventsFailure(
        'minimizing the window',
        _refused,
        _state(locked: true),
      );
      expect(message, contains('minimizing the window'));
      expect(message, contains('-1719'));
      expect(message, contains('screenLocked: true'));
    });

    test('a session that could not be read is said so', () {
      final message = systemEventsFailure(
        'minimizing the window',
        _refused,
        null,
      );
      expect(message, contains('could not be read'));
      expect(message, contains('-1719'));
    });
  });

  group('setMinimized', () {
    test('fails with the diagnosis when System Events refuses', () async {
      await expectLater(
        setMinimized(
          true,
          process: 'Hello World',
          run: (_, _) async => _refused,
          probe: () async => _state(locked: true),
        ),
        throwsA(
          isA<TestFailure>().having(
            (f) => f.message,
            'message',
            contains(GuiSession.explain(GuiBlocker.screenLocked)),
          ),
        ),
      );
    });

    test(
      'asks System Events to set AXMinimized of the named process',
      () async {
        List<String>? args;
        await setMinimized(
          false,
          process: 'Hello World',
          run: (executable, arguments) async {
            expect(executable, 'osascript');
            args = arguments;
            return BoundedRun(exitCode: 0, stdout: '', stderr: '');
          },
          probe: () async => fail('a call that worked reads no session'),
        );
        expect(args!.last, contains('process "Hello World"'));
        expect(args!.last, contains('AXMinimized'));
        expect(args!.last, contains('to false'));
      },
    );
  });
}
