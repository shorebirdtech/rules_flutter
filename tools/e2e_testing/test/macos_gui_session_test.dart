import 'dart:io';

import 'package:rules_flutter_e2e_testing/macos_gui_session.dart';
import 'package:test/test.dart';

GuiState _state({
  bool locked = false,
  bool asleep = false,
  bool? trusted = true,
}) => GuiState(
  screenLocked: locked,
  displayAsleep: asleep,
  accessibilityTrusted: trusted,
);

void main() {
  group('GuiSession.diagnose', () {
    test('a locked screen is named first, even with the display asleep', () {
      expect(
        GuiSession.diagnose(_state(locked: true, asleep: true, trusted: false)),
        GuiBlocker.screenLocked,
      );
    });

    test('a display that stayed asleep is not blamed on Accessibility', () {
      expect(
        GuiSession.diagnose(_state(asleep: true, trusted: false)),
        GuiBlocker.displayAsleep,
      );
    });

    test('an untrusted runner is named only on a live session', () {
      expect(
        GuiSession.diagnose(_state(trusted: false)),
        GuiBlocker.accessibilityDenied,
      );
    });

    test('a live, trusted session leaves the cause unknown', () {
      expect(GuiSession.diagnose(_state()), GuiBlocker.unknown);
      expect(GuiSession.diagnose(_state(trusted: null)), GuiBlocker.unknown);
    });
  });

  group('GuiSession.explain', () {
    test('each blocker names its own remedy', () {
      expect(
        GuiSession.explain(GuiBlocker.screenLocked),
        allOf(contains('locked'), contains('Unlock')),
      );
      expect(
        GuiSession.explain(GuiBlocker.displayAsleep),
        allOf(contains('asleep'), contains('Wake')),
      );
      expect(
        GuiSession.explain(GuiBlocker.accessibilityDenied),
        contains('System Settings'),
      );
    });

    test('only the real denial tells the user to grant Accessibility', () {
      expect(
        GuiSession.explain(GuiBlocker.screenLocked),
        contains('not the problem'),
      );
      expect(
        GuiSession.explain(GuiBlocker.displayAsleep),
        contains('not the problem'),
      );
    });
  });

  test('GuiState reads the probe script output', () {
    final state = GuiState.fromJson(
      '{"locked":true,"asleep":false,"trusted":true}',
    );
    expect(state.screenLocked, isTrue);
    expect(state.displayAsleep, isFalse);
    expect(state.accessibilityTrusted, isTrue);
  });

  group('on a macOS desktop', () {
    final skip = Platform.isMacOS ? null : 'needs macOS';

    test('probe reads a session that answers', () async {
      final state = await GuiSession.probe();
      expect(state.accessibilityTrusted, isNotNull);
    }, skip: skip);

    test('hold wakes the display and release drops the assertion', () async {
      final gui = await GuiSession.hold();
      try {
        expect((await GuiSession.probe()).displayAsleep, isFalse);
      } finally {
        await gui.release();
      }
    }, skip: skip);
  });
}
