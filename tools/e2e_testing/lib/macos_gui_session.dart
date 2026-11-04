/// Keeping a macOS desktop session usable for a test that needs windows, and
/// saying why when it is not.
///
/// System Events, ScreenCaptureKit and `screencapture` all fail the same
/// misleading way when the desktop is not live: System Events answers "no
/// windows" for every process (`-1719`) and reports accessibility as enabled
/// throughout, exactly as it does for a missing Accessibility grant. Two
/// different conditions produce that, and a third is the real denial:
///
/// - the display is asleep, which the harness can fix by asserting user
///   activity ([GuiSession.hold]);
/// - the screen is locked, which only the user can fix;
/// - the test runner is not trusted for Accessibility, which only the user
///   can fix, in System Settings.
///
/// The dev tool's e2e tests use this library through `tools/dev_tool/pubspec.yaml`
/// (a path dependency) and `//tools/e2e_testing`.
///
/// `e2e/_macos_test/verify_macos_app.dart` keeps a small copy of the probe
/// and the hold: `tools/vm` copies that directory alone to bare machines, so
/// it cannot import this package. Keep the two in step.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What the desktop session looks like to a process that wants windows.
class GuiState {
  /// A reading of the session.
  const GuiState({
    required this.screenLocked,
    required this.displayAsleep,
    required this.accessibilityTrusted,
  });

  /// Reads the JSON [GuiSession.probe] gets from its script.
  factory GuiState.fromJson(String json) {
    final map = jsonDecode(json) as Map<String, Object?>;
    return GuiState(
      screenLocked: map['locked'] == true,
      displayAsleep: map['asleep'] == true,
      accessibilityTrusted: map['trusted'] as bool?,
    );
  }

  /// Whether the login window's lock is up. Windows are invisible to
  /// accessibility and capture while it is.
  final bool screenLocked;

  /// Whether the main display is powered down.
  final bool displayAsleep;

  /// Whether the process that asked is trusted for Accessibility, or null if
  /// that could not be read.
  final bool? accessibilityTrusted;

  @override
  String toString() =>
      'GuiState(screenLocked: $screenLocked, displayAsleep: $displayAsleep, '
      'accessibilityTrusted: $accessibilityTrusted)';
}

/// What stands between a test and the windows it asks about.
enum GuiBlocker {
  /// The screen is locked. Only the user can unlock it.
  screenLocked,

  /// The display is off and stayed off after the harness asserted user
  /// activity.
  displayAsleep,

  /// Accessibility is not granted to the test runner.
  accessibilityDenied,

  /// Nothing the probe can see is wrong.
  unknown,
}

/// A held "the user is here" assertion on a macOS desktop, and the means to
/// diagnose a desktop that has none.
class GuiSession {
  GuiSession._(this._caffeinate);

  final Process? _caffeinate;

  /// Reads Core Graphics' own view of the session. `CGSSessionScreenIsLocked`
  /// is present in the session dictionary only while the screen is locked;
  /// `AXIsProcessTrusted` is asked of the interpreter, which macOS attributes
  /// to the terminal or IDE that started the test, the same client System
  /// Events judges.
  static const _probeScript = '''
ObjC.import('ApplicationServices');
ObjC.import('CoreGraphics');
var d = \$.CGSessionCopyCurrentDictionary();
var locked = false;
if (d) {
  locked = !!ObjC.deepUnwrap(ObjC.castRefToObject(d))['CGSSessionScreenIsLocked'];
}
JSON.stringify({
  locked: locked,
  asleep: \$.CGDisplayIsAsleep(\$.CGMainDisplayID()) !== 0,
  trusted: \$.AXIsProcessTrusted(),
});
''';

  /// Reads the state of the desktop session.
  static Future<GuiState> probe() async {
    final result =
        await Process.run('osascript', [
          '-l',
          'JavaScript',
          '-e',
          _probeScript,
        ]).timeout(
          const Duration(seconds: 20),
          onTimeout: () => ProcessResult(0, 1, '', 'osascript did not respond'),
        );
    if (result.exitCode != 0) {
      throw StateError(
        'could not read the desktop session state: ${result.stderr}'.trim(),
      );
    }
    return GuiState.fromJson(result.stdout.toString().trim());
  }

  /// Declares the user active and keeps the display from sleeping until
  /// [release], or until this process exits, and waits up to [wake] for a
  /// sleeping display to light.
  ///
  /// This is `caffeinate -d -u`: `-d` stops an awake display from idling out,
  /// which a terminal driving tests does not prevent because it is not user
  /// activity; `-u` is what wakes one that is already off, and `-d` alone does
  /// not. `-w` ties the assertion to this process, so a killed test does not
  /// leave the display held. A display that stays asleep is not an error
  /// here: [diagnose] reports it when it matters.
  static Future<GuiSession> hold({
    Duration wake = const Duration(seconds: 15),
  }) async {
    final caffeinate = await Process.start('caffeinate', [
      '-d',
      '-u',
      '-w',
      '$pid',
    ]);
    final session = GuiSession._(caffeinate);
    final deadline = DateTime.now().add(wake);
    while (DateTime.now().isBefore(deadline)) {
      final state = await probe();
      if (!state.displayAsleep) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return session;
  }

  /// Drops the assertion.
  Future<void> release() async {
    _caffeinate?.kill();
    await _caffeinate?.exitCode;
  }

  /// Which blocker [state] shows. Locked wins over asleep, because a locked
  /// screen is the one a wake cannot help; an untrusted runner is named only
  /// when the session itself is live.
  static GuiBlocker diagnose(GuiState state) {
    if (state.screenLocked) return GuiBlocker.screenLocked;
    if (state.displayAsleep) return GuiBlocker.displayAsleep;
    if (state.accessibilityTrusted == false) {
      return GuiBlocker.accessibilityDenied;
    }
    return GuiBlocker.unknown;
  }

  /// What to tell the person who ran the test about [blocker]: what it is,
  /// and what to do.
  static String explain(GuiBlocker blocker) => switch (blocker) {
    GuiBlocker.screenLocked =>
      'The screen is locked. System Events reports no windows for any '
          'process while it is, and the accessibility grant is not the '
          'problem. Unlock the Mac and re-run; a harness cannot unlock it.',
    GuiBlocker.displayAsleep =>
      'The display is asleep and stayed asleep after the harness asserted '
          'user activity (`caffeinate -d -u`). System Events reports no '
          'windows for any process while it is, and the accessibility grant '
          'is not the problem. Wake the Mac by hand and re-run; `pmset -g '
          'log | grep "Display is turned"` shows when it went off.',
    GuiBlocker.accessibilityDenied =>
      'The test runner is not trusted for Accessibility '
          '(AXIsProcessTrusted is false). Grant it to the terminal or IDE '
          'that launched the test in System Settings > Privacy & Security > '
          'Accessibility, `killall "System Events"`, and re-run. A Bazel '
          'server first started by another tool (`flutter_bazel run`) keeps '
          'that tool\'s trust: `bazel shutdown` and re-run from the terminal.',
    GuiBlocker.unknown =>
      'The screen is unlocked, the display is awake and the runner is '
          'trusted for Accessibility, yet System Events reports no windows. '
          'Restart it with `killall "System Events"` and re-run; if the test '
          'runs under a Bazel server started by another tool, `bazel '
          'shutdown` first. On a busy Mac (`uptime` shows the load) System '
          'Events can also fail while its process list changes under it '
          '(`-1719`, "Invalid index"): re-run when the builds have finished.',
  };

  /// Reads the session and returns the explanation for what is wrong with it,
  /// for a harness failure to print.
  static Future<String> diagnosis() async {
    final GuiState state;
    try {
      state = await probe();
    } on StateError catch (e) {
      return '${e.message} Check the session by hand: the screen must be '
          'unlocked, the display awake, and the terminal granted '
          'Accessibility.';
    }
    return '${explain(diagnose(state))} (Read: $state.)';
  }
}
