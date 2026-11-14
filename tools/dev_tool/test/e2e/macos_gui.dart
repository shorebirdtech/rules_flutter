/// What an e2e test that drives a macOS window needs from the desktop, and what
/// it says when the desktop cannot give it.
///
/// The probe and the hold are `GuiSession`'s, in `tools/e2e_testing`: the
/// e2e workspaces' tests use the same ones, so a locked screen or a sleeping
/// display is diagnosed the same way wherever it stops a test. A test that
/// needs a window fails when it cannot have one, and says why. It does not
/// skip: a skip reports the run as a pass.
library;

import 'package:rules_flutter_e2e_testing/macos_gui_session.dart';
import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

/// How long a System Events call gets to answer.
///
/// Setting one attribute on one window is sub-second work when the session is
/// live and the permissions are in place. This bounds the unanswerable case
/// (an undecided Automation consent blocks the send and never returns), not an
/// expected wait: a healthy call returns the moment it is done.
const systemEventsBound = Duration(seconds: 10);

/// Runs a command under a bound; [runBounded] unless a test replaces it.
typedef BoundedRunner = Future<BoundedRun> Function(
  String executable,
  List<String> arguments,
);

Future<BoundedRun> _runBounded(String executable, List<String> arguments) =>
    runBounded(executable, arguments, timeout: systemEventsBound);

/// Declares the user active for the tests of the enclosing group, and releases
/// the assertion after them.
///
/// A terminal driving a suite is not user activity, so the display idles out
/// mid-run, and a Mac whose display is already dark stays dark; windows are
/// invisible to System Events and to capture while it is. Call it at the top of
/// a group that needs windows.
void holdGuiSession() {
  GuiSession? session;
  setUpAll(() async {
    session = await GuiSession.hold();
  });
  tearDownAll(() async {
    await session?.release();
  });
}

/// The message for a System Events call, [doing] something, that failed as
/// [result].
///
/// [state] is the desktop session as read after the failure, or null if that
/// could not be read. System Events fails the same way for a locked screen, a
/// display that is off and a missing Accessibility grant, so the message
/// names the one the session is in. When the session is live and the call
/// still never answered, the cause is an undecided Automation consent, which
/// the session cannot show.
String systemEventsFailure(String doing, BoundedRun result, GuiState? state) {
  final String why;
  if (state == null) {
    why =
        'The desktop session could not be read, so whether the screen is '
        'locked, the display asleep or Accessibility not granted is unknown.';
  } else {
    final blocker = GuiSession.diagnose(state);
    final explanation = blocker == GuiBlocker.unknown && result.timedOut
        ? 'The screen is unlocked, the display is awake and the runner is '
              'trusted for Accessibility, yet System Events did not answer. '
              'An undecided Automation (AppleEvents) consent blocks the send '
              'without an error: allow the terminal or IDE that runs the tests '
              'to control System Events in System Settings > Privacy & '
              'Security > Automation, and re-run.'
        : GuiSession.explain(blocker);
    why = '$explanation (Read: $state.)';
  }
  return '$doing failed: $result.\n$why';
}

/// Fails the test with [systemEventsFailure], reading the session for it.
Future<Never> _failSystemEvents(
  String doing,
  BoundedRun result,
  Future<GuiState> Function() probe,
) async {
  GuiState? state;
  try {
    state = await probe();
  } on StateError {
    state = null;
  }
  fail(systemEventsFailure(doing, result, state));
}

/// Minimizes or restores the window of the app whose menu-bar name is
/// [process], through System Events.
///
/// Fails, with the diagnosis, when System Events cannot do it.
Future<void> setMinimized(
  bool value, {
  required String process,
  BoundedRunner run = _runBounded,
  Future<GuiState> Function() probe = GuiSession.probe,
}) async {
  final result = await run('osascript', [
    '-e',
    'tell application "System Events" to tell process "$process" '
        'to set value of attribute "AXMinimized" of window 1 to $value',
  ]);
  if (result.succeeded) return;
  await _failSystemEvents(
    'setting AXMinimized=$value on the "$process" window',
    result,
    probe,
  );
}
